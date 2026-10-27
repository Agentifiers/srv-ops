#!/usr/bin/env bash
# Android build toolchain for Expo SDK 58 / React Native 0.88 apps:
# JDK 17, the Android SDK under /opt/android-sdk (owned by `user`, so Gradle
# can add packages on demand), and scrcpy.
#
# SDK package versions are what RN 0.88 (gradle/libs.versions.toml) and
# expo-modules-autolinking 58 (ExpoRootProjectPlugin) default to:
# compileSdk 37, buildTools 37.0.0, ndkVersion 27.1.12297006; CMake 3.22.1 is
# AGP 9.2's default for externalNativeBuild. build-tools 36.0.0 is what AGP 9.2
# itself installs during a default Expo 58 assembleDebug (seen in a cold build).
#
# The install is offline from $CACHE: every zip is sha256-pinned here, and the
# legacy sdkmanager (SdkManagerCli in cmdline-tools' sdklib; the `sdkmanager`
# script in cmdline-tools >= 20 forwards to the new `android` CLI, which always
# downloads from Google) installs from android/sdk-repository.xml, a pinned
# subset of Google's repository, via SDK_TEST_BASE_URL. That writes the
# package.xml files Gradle needs to see the packages as installed.
#
# Env: MNT (mounted rootfs), CACHE (download cache), HERE (mobile dir).
set -euo pipefail
umask 022
: "${MNT:?}" "${CACHE:?}" "${HERE:?}"

SDK=/opt/android-sdk
JAVA_HOME=/usr/lib/jvm/java-17-openjdk
REPO_BASE=https://dl.google.com/android/repository
CMDLINE_TOOLS_VERSION=23.0
CMDLINE_TOOLS_ZIP=commandlinetools-linux-16111833_latest.zip

# <zip> <sha256>; the sha1 in sdk-repository.xml is checked again by sdkmanager.
SDK_ZIPS=(
	"$CMDLINE_TOOLS_ZIP 0877a1d048fe4a24efe2eff536ca4223f7adeb58648bb81909d33c446918cfa8"
	"platform-tools_r37.0.1-linux.zip d230f13842f60f782a8645f9c813f8f845bf36089ea7289f28c48f17979313f1"
	"build-tools_r37_linux.zip 01af179347cbcd9c208b7f8171f7b21f6dd1d2f85bcd15e88caa51d5d7b86060"
	"build-tools_r36_linux.zip 5d9ac77fb6ff43d9da518a337b4fcf8f9097113df531d99ccefe80ef7ce8250b"
	"platform-37.0_r02.zip 840b23e827f96e64aea4c89a1194aac3dc5f6bad37edb231c5c795d890330e8d"
	"android-ndk-r27b-linux.zip 33e16af1a6bbabe12cad54b2117085c07eab7e4fa67cdd831805f0e94fd826c1"
	"cmake-3.22.1-linux.zip 9196644852a978012caf7a4067ba1898debf6cc204c3341562771e31080d6869"
)
# sdkmanager path -> expected installed version (verified after install).
SDK_PACKAGES=(
	"cmdline-tools;latest=$CMDLINE_TOOLS_VERSION"
	"platform-tools=37.0.1"
	"build-tools;37.0.0=37.0.0"
	"build-tools;36.0.0=36.0.0"
	"platforms;android-37.0=2"
	"ndk;27.1.12297006=27.1.12297006"
	"cmake;3.22.1=3.22.1"
)

die() { echo "android.sh: $*" >&2; exit 1; }

fetch() { # <file> <sha256>
	local file=$1 sum=$2 dest="$CACHE/$1"
	if [[ ! -f $dest ]] || ! echo "$sum  $dest" | sha256sum -c --quiet - 2>/dev/null; then
		curl -fL --retry 3 -o "$dest.part" "$REPO_BASE/$file"
		mv "$dest.part" "$dest"
	fi
	echo "$sum  $dest" | sha256sum -c --quiet - || die "sha256 mismatch for $file"
}

install -d "$CACHE"
for entry in "${SDK_ZIPS[@]}"; do fetch $entry; done

arch-chroot "$MNT" pacman -Sy --needed --noconfirm jdk17-openjdk unzip scrcpy
# Gradle and sdkmanager pick up `java` from PATH when JAVA_HOME is unset.
arch-chroot "$MNT" archlinux-java set java-17-openjdk

uid="$(arch-chroot "$MNT" id -u user)"
gid="$(arch-chroot "$MNT" id -g user)"

# Stage the pinned repository and the cache inside the rootfs (arch-chroot
# mounts tmpfs on /tmp and /run, so use /var/tmp).
stage="$MNT/var/tmp/android-sdk-install"
cleanup_stage() {
	mountpoint -q "$stage/cache" && umount "$stage/cache"
	rm -rf "$stage"
}
trap cleanup_stage EXIT
cleanup_stage
install -d -m 0755 "$stage/cache" "$stage/repo"
mount --bind -o ro "$CACHE" "$stage/cache"
sed 's#<url>#<url>file:///var/tmp/android-sdk-install/cache/#' \
	"$HERE/modules/android/sdk-repository.xml" > "$stage/repo/repository2-3.xml"
unzip -q "$CACHE/$CMDLINE_TOOLS_ZIP" -d "$stage/bootstrap"

install -d -m 0755 -o "$uid" -g "$gid" "$MNT$SDK"
chown -R "$uid:$gid" "$MNT$SDK"

packages=()
for p in "${SDK_PACKAGES[@]}"; do packages+=("${p%=*}"); done
# Installs, then prints the installed packages as path=version lines.
installed="$(arch-chroot "$MNT" runuser -u user -- env -C /var/tmp \
	SDK_TEST_BASE_URL=file:///var/tmp/android-sdk-install/repo/ \
	bash -euo pipefail -c '
		ct=/var/tmp/android-sdk-install/bootstrap/cmdline-tools
		sm() {
			"'"$JAVA_HOME"'/bin/java" -Dcom.android.sdkmanager.toolsdir="$ct" \
				-cp "$ct/lib/avdmanager-classpath.jar:$ct/lib/sdklib/tools.sdklib.jar" \
				com.android.sdklib.tool.sdkmanager.SdkManagerCli --sdk_root='"$SDK"' "$@"
		}
		yes | sm --licenses >/dev/null 2>&1 || true
		sm --install "$@" >&2
		sm --list_installed 2>/dev/null | awk -F"|" "NF == 4 && \$1 !~ /Path|---/ {
			gsub(/ /, \"\", \$1); gsub(/ /, \"\", \$2); print \$1 \"=\" \$2 }"
	' sdkmanager "${packages[@]}")"
for p in "${SDK_PACKAGES[@]}"; do
	grep -qxF "$p" <<<"$installed" || die "SDK package $p not installed (have: $(tr '\n' ' ' <<<"$installed"))"
done
[[ -f $MNT$SDK/licenses/android-sdk-license ]] || die "SDK licenses not accepted"

chown -R "$uid:$gid" "$MNT$SDK"

install -d "$MNT/usr/local/bin"
ln -sfn "$SDK/platform-tools/adb" "$MNT/usr/local/bin/adb"
ln -sfn "$SDK/cmdline-tools/latest/bin/sdkmanager" "$MNT/usr/local/bin/sdkmanager"
ln -sfn "$SDK/cmdline-tools/latest/bin/avdmanager" "$MNT/usr/local/bin/avdmanager"

# ADB: scrcpy depends on Arch's android-tools; point it (and anything else
# honouring $ADB) at the SDK's adb so two adb versions never fight over the
# server on :5037.
# ADB_LOCAL_TRANSPORT_MAX_PORT: the adb server probes 127.0.0.1:5555-5585 for
# emulators, so redroid on 127.0.0.1:5555 would also show up as a second
# device, emulator-5554, which the hub and agent-device treat as an AVD. There
# is no emulator in the orb (no KVM); a max below 5555 turns the probe off.
env_vars=(
	"ANDROID_HOME=$SDK"
	"ANDROID_SDK_ROOT=$SDK"
	"JAVA_HOME=$JAVA_HOME"
	"ADB=$SDK/platform-tools/adb"
	"ADB_LOCAL_TRANSPORT_MAX_PORT=5554"
)
install -d "$MNT/etc/systemd/system.conf.d" "$MNT/etc/profile.d"
printf '[Manager]\nDefaultEnvironment=%s\n' "${env_vars[*]}" > "$MNT/etc/systemd/system.conf.d/mobile-android.conf"
printf 'export %s\n' "${env_vars[@]}" > "$MNT/etc/profile.d/mobile-android.sh"

# Smoke tests as user with the login environment; then drop the Java prefs and
# ~/.android state they and sdkmanager leave in user's home.
arch-chroot "$MNT" runuser -u user -- bash -lc 'adb version && avdmanager list avd && java -version 2>&1 && scrcpy --version' >/dev/null \
	|| die "smoke test failed"
rm -rf "$MNT/home/user/.java" "$MNT/home/user/.android"

java_version="$(arch-chroot "$MNT" pacman -Q jdk17-openjdk | cut -d' ' -f2)"
scrcpy_version="$(arch-chroot "$MNT" pacman -Q scrcpy | cut -d' ' -f2)"
manifest="$MNT/etc/amp-orb-mobile.manifest"
touch "$manifest"
sed -i -E '/^(android_sdk|jdk|scrcpy)=/d' "$manifest"
{
	echo "android_sdk=$(IFS=,; echo "${SDK_PACKAGES[*]}")"
	echo "jdk=jdk17-openjdk $java_version"
	echo "scrcpy=$scrcpy_version"
} >> "$manifest"
echo "android.sh: done"
