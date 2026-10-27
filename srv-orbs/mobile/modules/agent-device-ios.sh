#!/usr/bin/env bash
# agent-device-ios: `agent-device ... --platform ios` drives the host's USB iPhone through the
# phone broker (srv-mobile-host; client env IPHONE_BROKER_URL). Needs device-tools.sh (agent-device),
# ios-toolchain.sh (Swift, mobile shims) and ios-sdk.sh (Darwin SDK with XCTest and XCTRunner.app).
#
#   /opt/agent-device-ios/runner     agent-device's XCUITest runner (AgentDeviceRunner.app,
#                                    AgentDeviceRunnerUITests-Runner.app, .xctestrun), built here
#                                    from the npm package's sources with swiftc/clang + the SDK
#                                    (agent-device-ios.d/build-runner.sh), unsigned; the broker
#                                    signs it when it is first installed on the phone.
#   /opt/agent-device-ios/libexec/agent-device-ios
#                                    xcrun devicectl/xctrace/simctl, xcodebuild test-without-building
#                                    and a usbmuxd look-alike, all backed by the broker
#   /opt/agent-device-ios/bin        xcrun, xcodebuild, DevToolsSecurity (-> the above), plutil (-> mobile shims);
#                                    on PATH only inside agent-device (the wrapper below)
#   /usr/local/bin/agent-device      wrapper: that PATH plus the runner settings, then agent-device
#   /usr/local/bin/agent-device-ios  install-runner | status | release | usbmuxd
#   agent-device-ios-usbmuxd.socket  /run/usbmuxd, where agent-device reaches the runner
#   dist patch                       agent-device-ios.d/patch-dist.mjs (Linux device discovery)
#   skill agent-device-ios
#
# device-tools.sh re-extracts /opt/agent-device and resets /usr/local/bin/agent-device, so rerun
# this module after it (--only device-tools,agent-device-ios).
#
# Runs on the host as root with MNT, CACHE and HERE set, plus APPLE_BUNDLE_PREFIX from
# site.env, which build-mobile-image.sh exports (see ../README contract).
set -euo pipefail
umask 022
: "${MNT:?}" "${CACHE:?}" "${HERE:?}"
: "${APPLE_BUNDLE_PREFIX:?set APPLE_BUNDLE_PREFIX in site.env}"

D="$HERE/modules/agent-device-ios.d"
C="$CACHE/agent-device-ios"
P=/opt/agent-device-ios
SDKB=/opt/swift-sdks/darwin.artifactbundle
# The broker signs only identifiers under APPLE_BUNDLE_PREFIX (srv-mobile-host signing config).
RUNNER_APP_ID="${APPLE_BUNDLE_PREFIX}agentdevice.runner"

log() { echo "[agent-device-ios] $*"; }
die() { echo "[agent-device-ios] ERROR: $*" >&2; exit 1; }
# Own PID namespace + /proc inside the chroot: under plain arch-chroot, Swift programs read
# another process's /proc entry and crash (see ios-toolchain.sh).
chroot_run() { arch-chroot "$MNT" unshare --fork --pid --mount-proc "$@"; }

[[ -x $MNT/opt/agent-device/bin/agent-device.mjs ]] || die "run device-tools.sh first"
[[ -x $MNT/opt/mobile-shims/bin/plutil && -x $MNT/opt/swift/usr/bin/swiftc ]] || die "run ios-toolchain.sh first"
if [[ ! -d $MNT$SDKB/Developer/Platforms/iPhoneOS.platform/Developer/Library/Xcode/Agents/XCTRunner.app ]]; then
	log "no Darwin SDK with XCTRunner.app in the image (ios-sdk.sh skipped?); skipping"
	exit 0
fi
uid="$(arch-chroot "$MNT" id -u user)"
gid="$(arch-chroot "$MNT" id -g user)"

# --- tools ---------------------------------------------------------------------------------------
install -d -m 0755 "$MNT$P" "$MNT$P/bin" "$MNT$P/libexec"
install -m 0755 "$D/agent-device-ios" "$MNT$P/libexec/agent-device-ios"
ln -sfn ../libexec/agent-device-ios "$MNT$P/bin/xcrun"
ln -sfn ../libexec/agent-device-ios "$MNT$P/bin/xcodebuild"
ln -sfn ../libexec/agent-device-ios "$MNT$P/bin/DevToolsSecurity"
ln -sfn /opt/mobile-shims/bin/plutil "$MNT$P/bin/plutil"
ln -sfn "$P/libexec/agent-device-ios" "$MNT/usr/local/bin/agent-device-ios"

# --- agent-device: dist patch + wrapper --------------------------------------------------------------
install -m 0644 "$D/patch-dist.mjs" "$MNT$P/libexec/patch-dist.mjs"
arch-chroot "$MNT" node "$P/libexec/patch-dist.mjs" /opt/agent-device
rm -f "$MNT/usr/local/bin/agent-device"
sed "s|@RUNNER_APP_ID@|$RUNNER_APP_ID|" "$D/agent-device" > "$MNT/usr/local/bin/agent-device"
chmod 0755 "$MNT/usr/local/bin/agent-device"

# --- runner ----------------------------------------------------------------------------------------
# Cached by everything that goes into it, so image rebuilds keep the same build stamp and the
# phone keeps its installed (signed) copy.
ad_version=$(arch-chroot "$MNT" node -p 'require("/opt/agent-device/package.json").version')
key=$( {
	echo "$RUNNER_APP_ID $ad_version"
	sha256sum "$D/build-runner.sh"
	(cd "$MNT/opt/agent-device/dist/apple" && find . -type f -print0 | sort -z | xargs -0 sha256sum)
	grep -E '^(swift|darwin_sdk|xcode)=' "$MNT/etc/amp-orb-mobile.manifest" || true
} | sha256sum | cut -c1-16)
cached="$C/runner-$key.tar"
install -d "$C"
if [[ ! -f $cached ]]; then
	log "building the XCUITest runner (agent-device $ad_version)"
	work=/var/tmp/agent-device-ios-runner
	rm -rf "$MNT$work"
	install -d "$MNT$work"
	install -m 0755 "$D/build-runner.sh" "$MNT$work/build-runner.sh"
	chroot_run env -i HOME=/root PATH=/usr/local/sbin:/usr/local/bin:/usr/bin RUNNER_APP_ID="$RUNNER_APP_ID" \
		JOBS="$(nproc)" "$work/build-runner.sh" /opt/agent-device/dist/apple "$work/out"
	tar -C "$MNT$work/out" -cf "$cached.tmp" .
	mv "$cached.tmp" "$cached"
	rm -rf "$MNT$work"
fi
rm -rf "$MNT$P/runner"
install -d -m 0755 "$MNT$P/runner"
tar -C "$MNT$P/runner" -xf "$cached" --no-same-owner
chmod -R u+rwX,go+rX,go-w "$MNT$P/runner"

# --- usbmuxd look-alike ----------------------------------------------------------------------------
install -m 0644 "$D/agent-device-ios-usbmuxd.socket" "$D/agent-device-ios-usbmuxd.service" "$MNT/etc/systemd/system/"
systemctl --root="$MNT" enable agent-device-ios-usbmuxd.socket >/dev/null

# --- skill -----------------------------------------------------------------------------------------
skills=/home/user/.config/agents/skills
for dir in /home/user/.config /home/user/.config/agents "$skills"; do
	[[ -d $MNT$dir ]] || install -d -m 0755 -o "$uid" -g "$gid" "$MNT$dir"
done
rm -rf "${MNT:?}$skills/agent-device-ios"
install -d -m 0755 -o "$uid" -g "$gid" "$MNT$skills/agent-device-ios"
install -m 0644 -o "$uid" -g "$gid" "$D/SKILL.md" "$MNT$skills/agent-device-ios/SKILL.md"

# --- verification (as user, login environment) -------------------------------------------------------
stamp=$(python3 -c 'import plistlib,sys; print(plistlib.load(open(sys.argv[1],"rb"))["CFBundleVersion"])' \
	"$MNT$P/runner/Release-iphoneos/AgentDeviceRunnerUITests-Runner.app/Info.plist")
for f in Release-iphoneos/AgentDeviceRunner.app/AgentDeviceRunner \
	Release-iphoneos/AgentDeviceRunnerUITests-Runner.app/AgentDeviceRunnerUITests-Runner \
	Release-iphoneos/AgentDeviceRunnerUITests-Runner.app/PlugIns/AgentDeviceRunnerUITests.xctest/AgentDeviceRunnerUITests \
	Release-iphoneos/AgentDeviceRunnerUITests-Runner.app/Frameworks/XCTest.framework/XCTest \
	AgentDeviceRunner.xctestrun; do
	[[ -s $MNT$P/runner/$f ]] || die "runner incomplete: $f"
done
arch-chroot "$MNT" runuser -u user -- env -i HOME=/home/user PATH=/usr/local/sbin:/usr/local/bin:/usr/bin bash -lc '
	set -e
	cd /var/tmp
	agent-device-ios --help >/dev/null
	PATH=/opt/agent-device-ios/bin:$PATH
	xcrun simctl list devices -j | python3 -c "import json,sys; json.load(sys.stdin)"
	xcrun --sdk iphoneos --show-sdk-path >/dev/null
	plutil -convert json -o - /opt/agent-device-ios/runner/AgentDeviceRunner.xctestrun | grep -q AgentDeviceRunnerUITests
	grep -q agent-device-ios /opt/agent-device/dist/src/inventory2.js
	agent-device --version
' >/dev/null || die "smoke test failed"

manifest="$MNT/etc/amp-orb-mobile.manifest"
touch "$manifest"
sed -i -E '/^agent_device_ios=/d' "$manifest"
echo "agent_device_ios=runner $stamp ($RUNNER_APP_ID, agent-device $ad_version, key $key)" >> "$manifest"
log "done (runner build $stamp)"
