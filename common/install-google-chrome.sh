#!/usr/bin/env bash
# Installs Google Chrome stable into a mounted Arch rootfs. Arch only packages
# Chromium, and Amp's orb Desktop and many CI setups look for `google-chrome`.
#
#   install-google-chrome.sh ROOTFS
#
# Takes the current .deb from Google's Debian repository, checks it against the
# SHA256 in that repository's package index, and unpacks /opt/google/chrome
# plus its launchers into ROOTFS. Runtime libraries must already be installed
# in ROOTFS (see CHROME_DEPENDENCIES in the image builds); the script fails if
# any are missing. Prints the installed version.
set -euo pipefail

root=${1:?usage: install-google-chrome.sh ROOTFS}
repo=https://dl.google.com/linux/chrome/deb
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

curl -fsSL --retry 3 "$repo/dists/stable/main/binary-amd64/Packages" -o "$work/Packages"
read -r filename sha256 version < <(awk -v RS= -F '\n' '
	$1 == "Package: google-chrome-stable" {
		for (i = 1; i <= NF; i++) {
			split($i, kv, ": ")
			f[kv[1]] = kv[2]
		}
		print f["Filename"], f["SHA256"], f["Version"]
		exit
	}' "$work/Packages")
[[ -n ${filename:-} && ${sha256:-} =~ ^[0-9a-f]{64}$ ]] || { echo "google-chrome-stable missing from $repo index" >&2; exit 1; }

curl -fsSL --retry 3 "$repo/$filename" -o "$work/chrome.deb"
printf '%s  %s\n' "$sha256" "$work/chrome.deb" | sha256sum -c --quiet -

mkdir "$work/data"
bsdtar -xOf "$work/chrome.deb" 'data.tar.*' | bsdtar -xpf - -C "$work/data"
rm -rf "$root/opt/google/chrome"
install -d "$root/opt/google"
cp -a "$work/data/opt/google/chrome" "$root/opt/google/chrome"
# The SUID sandbox helper is how Chrome sandboxes renderers without user namespaces.
chown root:root "$root/opt/google/chrome/chrome-sandbox"
chmod 4755 "$root/opt/google/chrome/chrome-sandbox"
ln -sfn /opt/google/chrome/google-chrome "$root/usr/bin/google-chrome-stable"
ln -sfn /opt/google/chrome/google-chrome "$root/usr/bin/google-chrome"
install -Dm0644 "$work/data/usr/share/applications/google-chrome.desktop" \
	"$root/usr/share/applications/google-chrome.desktop"
for size in 16 24 32 48 64 128 256; do
	icon="$root/opt/google/chrome/product_logo_$size.png"
	[[ -f $icon ]] && install -Dm0644 "$icon" "$root/usr/share/icons/hicolor/${size}x${size}/apps/google-chrome.png"
done

missing=$(arch-chroot "$root" ldd /opt/google/chrome/chrome | grep 'not found' || true)
[[ -z $missing ]] || { printf 'Google Chrome is missing libraries:\n%s\n' "$missing" >&2; exit 1; }
installed=$(arch-chroot "$root" google-chrome --version)
[[ $installed == *"${version%-*}"* ]] || { echo "unexpected Chrome version: $installed (index: $version)" >&2; exit 1; }
echo "$installed"
