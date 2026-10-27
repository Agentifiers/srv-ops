#!/usr/bin/env bash
# Device tooling for Android in the orb (needs android.sh first):
#   - redroid: a prefetched image tarball (/opt/redroid/redroid.tar) plus the
#     redroid-up / redroid-down helpers;
#   - expo-device-hub (streams devices to a browser) under /opt/expo-device-hub,
#     installed from a lockfile, with node-datachannel's prebuilt addon and the
#     scrcpy-server serve-emu would otherwise download at first use;
#   - agent-device (drives devices for agents) under /opt/agent-device;
#   - skills for user: agent-device's (agent-device, android-emulator, dogfood)
#     and our mobile-android.
#
# Env: MNT (mounted rootfs), CACHE (download cache), HERE (mobile dir).
set -euo pipefail
umask 022
: "${MNT:?}" "${CACHE:?}" "${HERE:?}"

SRC="$HERE/modules/device-tools"

REDROID_REPO=redroid/redroid
# Android 16. Its surfaceflinger needs /dev/ashmem, which the mobile kernel
# provides built in (kernel/patches/0001); without it, it crash-loops with
# "output buffer not gpu writeable" (redroid-doc#934). Fallback without
# ashmem: 15.0.0_64only-250627@sha256:b51bde9cef80f7bd7581148192f2b2f4d41f23c6344cfe88eceeb8ddd67490ee.
REDROID_TAG=16.0.0_64only-250627
# Multi-arch index digest of the tag (the amd64 manifest is picked from it).
REDROID_DIGEST=sha256:7b1e389bd15f37af3bcd06138f5b2ffa7cfba4332bd5ef54c53e99c2f160a15b

EXPO_DEVICE_HUB_VERSION=0.18.0 # pinned with all deps in device-tools/expo-device-hub/package-lock.json
NODE_DATACHANNEL_VERSION=0.32.3 # must match the lockfile
NODE_DATACHANNEL_SHA256=4092afc9cd594a3326eb1bd823da452b227b742ea8222689b2cea6f7344cf67a
SCRCPY_SERVER_VERSION=4.0 # must match vendor/serve-emu SCRCPY_VERSION
SCRCPY_SERVER_SHA256=84924bd564a1eb6089c872c7521f968058977f91f5ff02514a8c74aff3210f3a

AGENT_DEVICE_VERSION=0.21.31
AGENT_DEVICE_INTEGRITY=sha512-541X/tXHqQS3Xg5PutPSek1nQFLgEJEXFdLPiZ9jTvSb+SMHr/Z4kzVCnBkGza59R+EHO1atLWx0ZAW5vK84IQ==
AGENT_DEVICE_SRC_SHA256=c0abe6068e5dd99788d24f1fb8fe14c5c9b324e25c195b23b1285b3e3e83d985
AGENT_DEVICE_SKILLS=(agent-device android-emulator dogfood) # ios-simulator: no simulator in the orb

die() { echo "device-tools.sh: $*" >&2; exit 1; }

fetch() { # <file> <url> <sha256>
	local dest="$CACHE/$1"
	if [[ ! -f $dest ]] || ! echo "$3  $dest" | sha256sum -c --quiet - 2>/dev/null; then
		curl -fL --retry 3 -o "$dest.part" "$2"
		mv "$dest.part" "$dest"
	fi
	echo "$3  $dest" | sha256sum -c --quiet - || die "sha256 mismatch for $1"
}

[[ -x $MNT/opt/android-sdk/platform-tools/adb ]] || die "run android.sh first"
install -d "$CACHE"
arch-chroot "$MNT" pacman -Sy --needed --noconfirm nodejs npm docker
systemctl --root="$MNT" enable docker.service >/dev/null

uid="$(arch-chroot "$MNT" id -u user)"
gid="$(arch-chroot "$MNT" id -g user)"
arch-chroot "$MNT" usermod -aG docker user

# --- redroid -------------------------------------------------------------
redroid_ref="$REDROID_REPO:$REDROID_TAG@$REDROID_DIGEST"
install -d -m 0755 "$MNT/opt/redroid"
if [[ ! -f $MNT/opt/redroid/redroid.tar || "$(cat "$MNT/opt/redroid/IMAGE" 2>/dev/null)" != "$redroid_ref" ]]; then
	python3 "$SRC/pull-docker-image.py" "$REDROID_REPO" "$REDROID_DIGEST" "$REDROID_TAG" \
		"$CACHE/docker-blobs" "$MNT/opt/redroid/redroid.tar"
	echo "$redroid_ref" > "$MNT/opt/redroid/IMAGE"
fi
for f in redroid-up redroid-down; do
	sed "s|@REDROID_IMAGE@|$REDROID_REPO:$REDROID_TAG|" "$SRC/$f" > "$MNT/usr/local/bin/$f"
	chmod 0755 "$MNT/usr/local/bin/$f"
done

# --- expo-device-hub -----------------------------------------------------
hub=/opt/expo-device-hub
rm -rf "$MNT$hub"
install -d -m 0755 "$MNT$hub"
install -m 0644 "$SRC/expo-device-hub/package.json" "$SRC/expo-device-hub/package-lock.json" "$MNT$hub/"
# npm ci verifies every tarball against the lockfile's integrity; the cache
# lives in $CACHE. node-datachannel's install script would fetch its prebuilt
# addon from GitHub unpinned, so scripts are skipped and the pinned prebuild is
# unpacked below.
npm_cache="$MNT/var/tmp/device-tools-npm-cache"
cleanup_npm_cache() { mountpoint -q "$npm_cache" && umount "$npm_cache"; rmdir "$npm_cache" 2>/dev/null || true; }
trap cleanup_npm_cache EXIT
install -d "$CACHE/npm" "$npm_cache"
mount --bind "$CACHE/npm" "$npm_cache"
arch-chroot "$MNT" npm ci --prefix "$hub" --omit=dev --ignore-scripts --no-audit --no-fund \
	--cache /var/tmp/device-tools-npm-cache
cleanup_npm_cache
trap - EXIT
[[ "$(arch-chroot "$MNT" node -p "require('$hub/node_modules/expo-device-hub/package.json').version")" == "$EXPO_DEVICE_HUB_VERSION" ]] \
	|| die "expo-device-hub version mismatch"
[[ "$(arch-chroot "$MNT" node -p "require('$hub/node_modules/node-datachannel/package.json').version")" == "$NODE_DATACHANNEL_VERSION" ]] \
	|| die "node-datachannel version mismatch with lockfile"

ndc_tar="node-datachannel-v$NODE_DATACHANNEL_VERSION-napi-v8-linux-x64.tar.gz"
fetch "$ndc_tar" "https://github.com/murat-dogan/node-datachannel/releases/download/v$NODE_DATACHANNEL_VERSION/$ndc_tar" "$NODE_DATACHANNEL_SHA256"
tar -xzf "$CACHE/$ndc_tar" -C "$MNT$hub/node_modules/node-datachannel" --no-same-owner

scrcpy_server="scrcpy-server-v$SCRCPY_SERVER_VERSION"
fetch "$scrcpy_server" "https://github.com/Genymobile/scrcpy/releases/download/v$SCRCPY_SERVER_VERSION/$scrcpy_server" "$SCRCPY_SERVER_SHA256"
serve_emu="$MNT$hub/node_modules/expo-device-hub/vendor/serve-emu"
grep -q "SCRCPY_VERSION = \"$SCRCPY_SERVER_VERSION\"" "$serve_emu/dist/scrcpy-server.js" \
	|| die "serve-emu no longer pins scrcpy-server $SCRCPY_SERVER_VERSION"
install -D -m 0644 "$CACHE/$scrcpy_server" "$serve_emu/vendor/$scrcpy_server"
ln -sfn "$hub/node_modules/expo-device-hub/dist/server/cli.mjs" "$MNT/usr/local/bin/expo-device-hub"

# --- agent-device --------------------------------------------------------
ad_tgz="agent-device-$AGENT_DEVICE_VERSION.tgz"
if [[ ! -f $CACHE/$ad_tgz || "sha512-$(openssl dgst -sha512 -binary "$CACHE/$ad_tgz" | base64 -w0)" != "$AGENT_DEVICE_INTEGRITY" ]]; then
	curl -fL --retry 3 -o "$CACHE/$ad_tgz.part" "https://registry.npmjs.org/agent-device/-/$ad_tgz"
	mv "$CACHE/$ad_tgz.part" "$CACHE/$ad_tgz"
fi
[[ "sha512-$(openssl dgst -sha512 -binary "$CACHE/$ad_tgz" | base64 -w0)" == "$AGENT_DEVICE_INTEGRITY" ]] \
	|| die "sha512 mismatch for $ad_tgz"
ad_src="agent-device-src-v$AGENT_DEVICE_VERSION.tar.gz"
fetch "$ad_src" "https://github.com/callstack/agent-device/archive/refs/tags/v$AGENT_DEVICE_VERSION.tar.gz" "$AGENT_DEVICE_SRC_SHA256"
rm -rf "$MNT/opt/agent-device"
install -d -m 0755 "$MNT/opt/agent-device"
tar -xzf "$CACHE/$ad_tgz" -C "$MNT/opt/agent-device" --strip-components=1 --no-same-owner
# Skills ship in the GitHub repo, not in the npm package.
tar -xzf "$CACHE/$ad_src" -C "$MNT/opt/agent-device" --strip-components=1 --no-same-owner \
	"agent-device-$AGENT_DEVICE_VERSION/skills"
ln -sfn /opt/agent-device/bin/agent-device.mjs "$MNT/usr/local/bin/agent-device"

# --- environment ---------------------------------------------------------
install -d "$MNT/etc/systemd/system.conf.d" "$MNT/etc/profile.d"
printf '[Manager]\nDefaultEnvironment=AGENT_DEVICE_NO_UPDATE_NOTIFIER=1\n' > "$MNT/etc/systemd/system.conf.d/mobile-device-tools.conf"
printf 'export AGENT_DEVICE_NO_UPDATE_NOTIFIER=1\n' > "$MNT/etc/profile.d/mobile-device-tools.sh"

# --- skills --------------------------------------------------------------
skills=/home/user/.config/agents/skills
for dir in /home/user/.config /home/user/.config/agents "$skills"; do
	[[ -d $MNT$dir ]] || install -d -m 0755 -o "$uid" -g "$gid" "$MNT$dir"
done
for s in "${AGENT_DEVICE_SKILLS[@]}"; do
	[[ -f $MNT/opt/agent-device/skills/$s/SKILL.md ]] || die "agent-device skill $s missing"
	rm -rf "${MNT:?}$skills/$s"
	cp -r --no-preserve=ownership "$MNT/opt/agent-device/skills/$s" "$MNT$skills/$s"
	chown -R "$uid:$gid" "$MNT$skills/$s"
done
rm -rf "${MNT:?}$skills/mobile-android"
install -d -m 0755 -o "$uid" -g "$gid" "$MNT$skills/mobile-android"
install -m 0644 -o "$uid" -g "$gid" "$SRC/skills/mobile-android/SKILL.md" "$MNT$skills/mobile-android/SKILL.md"

# --- verification (as user, login environment) ---------------------------
arch-chroot "$MNT" runuser -u user -- bash -lc '
	set -e
	cd /var/tmp
	node -e "require(\"/opt/expo-device-hub/node_modules/node-datachannel\")"
	expo-device-hub --help >/dev/null
	agent-device --version
	agent-device help workflow >/dev/null
	bash -n /usr/local/bin/redroid-up
	bash -n /usr/local/bin/redroid-down
' >/dev/null || die "smoke test failed"
[[ -f $MNT/opt/redroid/redroid.tar ]] || die "redroid tarball missing"

manifest="$MNT/etc/amp-orb-mobile.manifest"
touch "$manifest"
sed -i -E '/^(redroid|expo_device_hub|agent_device)=/d' "$manifest"
{
	echo "redroid=$redroid_ref"
	echo "expo_device_hub=$EXPO_DEVICE_HUB_VERSION (node-datachannel $NODE_DATACHANNEL_VERSION, scrcpy-server $SCRCPY_SERVER_VERSION)"
	echo "agent_device=$AGENT_DEVICE_VERSION (skills: ${AGENT_DEVICE_SKILLS[*]})"
} >> "$manifest"
echo "device-tools.sh: done"
