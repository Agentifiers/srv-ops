#!/usr/bin/env bash
# Builds the GHA_RUNNER_IMAGE (default gha-runner) srv image as a layer on srv's arch-base image: a
# reflink copy of its rootfs with GitHub Actions runner tooling added. The
# kernel is shared with arch-base. GARM's srv provider boots one VM per job
# from this image.
#
#   sudo ./build-image.sh
#
# Rebuild after rebuilding arch-base. Existing VMs keep their own rootfs.
# Set ROOTFS_SIZE (e.g. 16G) to grow the image beyond the base size.
set -euo pipefail
# srv (user srv) must be able to read and reflink the image.
umask 022

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../common/site-env.sh"
site_env_load SITE_HOST_TAILNET_IP BAZEL_REMOTE_GRPC_PORT SRV_IMAGES_DIR GHA_RUNNER_IMAGE
BASE_DIR="${BASE_DIR:-$SRV_IMAGES_DIR/arch-base}"
OUTPUT_DIR="${OUTPUT_DIR:-$SRV_IMAGES_DIR/$GHA_RUNNER_IMAGE}"
ROOTFS_SIZE="${ROOTFS_SIZE:-}"

RUNNER_VERSION=2.338.1
# From the release body ("BEGIN SHA linux-x64") and the asset digest of
# github.com/actions/runner v2.338.1; both agree.
RUNNER_SHA256=08e9ccb3604d2462c24b5e33604dc30810296ca15cc65f23cffd4317eb144c37
RUNNER_URL="https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz"
RUNNER_UID=1001
BAZEL_PREWARM_VERSION=9.3.1
BAZEL_REMOTE_GRPC="grpc://$SITE_HOST_TAILNET_IP:$BAZEL_REMOTE_GRPC_PORT"

# arch-base already ships docker, git, go, jq, curl and gcc. icu, krb5,
# openssl and zlib cover what the runner's Debian-only installdependencies.sh
# would install.
PACKAGES=(
	base-devel sudo github-cli unzip zip wget openssh inetutils
	bazelisk aws-cli-v2 nodejs npm python
	python-pipx python-pyflakes shellcheck
	icu krb5 openssl zlib
	# Google Chrome's runtime libraries (installed by ../common/install-google-chrome.sh)
	# and Xvfb for headed browser tests (xvfb-run).
	alsa-lib gtk3 libcups libxss libxtst nss ttf-liberation xdg-utils
	xorg-server-xvfb
)

[[ $(id -u) == 0 ]] || { echo "run as root" >&2; exit 1; }

mkdir -p "$OUTPUT_DIR"
img="$OUTPUT_DIR/rootfs-base.img.new"
tarball="$OUTPUT_DIR/actions-runner.tar.gz.new"
mnt="$(mktemp -d)"
udev_rule=/run/udev/rules.d/99-srv-image-no-automount.rules

cleanup() {
	local status=$?
	trap - EXIT
	# pacman-key can leave a gpg-agent running inside the rootfs, which keeps
	# the mount busy and leaves the image's journal unflushed.
	pkill -f "gpg-agent --homedir $mnt/" 2>/dev/null || true
	if mountpoint -q "$mnt"; then
		umount -R "$mnt" || { echo "failed to unmount $mnt; leaving it in place" >&2; exit 1; }
	fi
	rmdir "$mnt"
	rm -f "$udev_rule" "$tarball"
	udevadm control --reload
	[[ $status == 0 ]] || rm -f "$img" "$OUTPUT_DIR/manifest.txt.new"
	exit "$status"
}
trap cleanup EXIT

# Fetch and verify the runner before touching the image.
curl -fsSL "$RUNNER_URL" -o "$tarball"
echo "$RUNNER_SHA256  $tarball" | sha256sum -c --quiet - \
	|| { echo "sha256 mismatch for $RUNNER_URL" >&2; exit 1; }

# Keep desktop automounters (udisks) off the loop device while we write to it.
mkdir -p "$(dirname "$udev_rule")"
echo 'KERNEL=="loop*", ENV{UDISKS_IGNORE}="1", ENV{UDISKS_AUTO}="0"' > "$udev_rule"
udevadm control --reload

cp --reflink=always "$BASE_DIR/rootfs-base.img" "$img"
if [[ -n $ROOTFS_SIZE ]]; then
	truncate -s "$ROOTFS_SIZE" "$img"
	e2fsck -fp "$img"
	resize2fs "$img"
fi
mount -o loop "$img" "$mnt"

# srv's arch-base build rsyncs its overlay with -a, so / and the overlay files
# (including the root-run bootstrap) inherit the checkout owner's UID. No guest
# account has that UID, so hand everything it owns back to root.
chown 0:0 "$mnt"
if ! awk -F: '$3 == 1000 { found = 1 } END { exit !found }' "$mnt/etc/passwd"; then
	find "$mnt" -xdev \( -uid 1000 -o -gid 1000 \) -exec chown -h 0:0 {} +
fi

arch-chroot "$mnt" pacman -Sy --needed --noconfirm "${PACKAGES[@]}"
if [[ $(arch-chroot "$mnt" bash -c 'readlink -f "$(command -v bazel)"') != /usr/bin/bazelisk ]]; then
	ln -sf /usr/bin/bazelisk "$mnt/usr/local/bin/bazel"
fi
# Workflows and actions such as browser-actions/setup-chrome expect
# `google-chrome`; Arch only packages Chromium.
chrome_version="$("$HERE/../common/install-google-chrome.sh" "$mnt")"

# The runner account GARM's install script configures and runs as.
arch-chroot "$mnt" useradd -m -u "$RUNNER_UID" -U -G docker,wheel -s /bin/bash runner
install -m 0440 /dev/stdin "$mnt/etc/sudoers.d/runner" <<<'runner ALL=(ALL) NOPASSWD:ALL'
arch-chroot "$mnt" visudo -cf /etc/sudoers.d/runner

# Runner disks are discarded after each job, so durability buys nothing. Without
# barriers a guest fsync no longer becomes a host flush through btrfs, LUKS
# and RAID0 (~17 ms each, measured); fsync-heavy steps (containerd pulls,
# package managers) ran ~100x faster. systemd-remount-fs applies this at boot.
echo '/dev/vda / ext4 rw,noatime,barrier=0 0 0' >> "$mnt/etc/fstab"

# Pre-extracted so GARM's install script skips the download.
install -d -o "$RUNNER_UID" -g "$RUNNER_UID" "$mnt/home/runner/actions-runner"
tar -xzf "$tarball" -C "$mnt/home/runner/actions-runner"
chown -R "$RUNNER_UID:$RUNNER_UID" "$mnt/home/runner/actions-runner"

# Read-only remote cache by default; workflows opt into uploads with
# credentials (--remote_upload_local_results plus a credentialed URL).
cat > "$mnt/etc/bazel.bazelrc" <<EOF
common --remote_cache=$BAZEL_REMOTE_GRPC
common --remote_local_fallback
common --noremote_upload_local_results
common --remote_timeout=60
EOF

# Prewarm bazelisk's download cache for the runner user. `bazel --version`
# is client-only, so no server or output base is left behind.
bazelisk_version="not prewarmed"
prewarm() {
	arch-chroot "$mnt" runuser -u runner -- env HOME=/home/runner \
		USE_BAZEL_VERSION="$BAZEL_PREWARM_VERSION" "$@"
}
if prewarm_out="$(prewarm bazelisk --version 2>&1)"; then
	bazelisk_version="$(arch-chroot "$mnt" pacman -Q bazelisk | cut -d' ' -f2), $(tail -1 <<<"$prewarm_out") cached"
else
	echo "bazelisk prewarm failed; image ships without a cached bazel:" >&2
	echo "$prewarm_out" >&2
fi

{
	echo "image=$GHA_RUNNER_IMAGE"
	echo "base=$BASE_DIR"
	echo "built_at=$(date --iso-8601=seconds)"
	echo "runner=$RUNNER_VERSION"
	echo "runner_sha256=$RUNNER_SHA256"
	echo "bazelisk=$bazelisk_version"
	echo "gh=$(arch-chroot "$mnt" gh --version | head -1)"
	echo "node=$(arch-chroot "$mnt" node --version)"
	echo "aws=$(arch-chroot "$mnt" aws --version)"
	echo "chrome=$chrome_version"
	echo "packages=$(IFS=,; echo "${PACKAGES[*]}")"
} > "$OUTPUT_DIR/manifest.txt.new"

rm -rf "$mnt/var/cache/pacman/pkg/"* "$mnt/root/.cache"
pkill -f "gpg-agent --homedir $mnt/" 2>/dev/null || true
umount "$mnt"
e2fsck -fn "$img" >/dev/null || { echo "filesystem check failed on $img" >&2; exit 1; }

mv "$img" "$OUTPUT_DIR/rootfs-base.img"
mv "$OUTPUT_DIR/manifest.txt.new" "$OUTPUT_DIR/manifest.txt"
echo "built $OUTPUT_DIR/rootfs-base.img"
cat "$OUTPUT_DIR/manifest.txt"
