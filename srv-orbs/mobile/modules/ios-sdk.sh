#!/usr/bin/env bash
# ios-sdk: the Darwin Swift SDK (iPhoneOS/MacOSX/iPhoneSimulator SDKs from Xcode)
# for swift build / xtool, at /opt/swift-sdks/darwin.artifactbundle.
#
# Input: $CACHE/Xcode_27.1.xip (override: XCODE_XIP). Without it the module
# skips (exit 0) and says so. Needs ios-toolchain.sh first (Swift, xtool,
# omarchy-apple-dev).
#
#   1. `xtool sdk build` (our xtool build, see ios-toolchain.sh) turns the .xip
#      into darwin.xtoolsdk, cached in $CACHE/ios-sdk keyed by the .xip's sha256
#      and the xtool binary, so image rebuilds skip the extraction (~1 min on 56 threads, 3.3G).
#      The toolset (ld64.lld, ...) and OpenAppleMacros tarballs xtool would fetch
#      are passed in pinned. Our xtool also keeps
#      Developer/Platforms/*/Developer/Library/Xcode/Agents (XCTRunner.app, the
#      UI-test runner host app for WDA/agent-device runners).
#   2. Install as /opt/swift-sdks/darwin.artifactbundle plus the host clang
#      headers (what `xtool sdk install` adds), Xcode's version.plist next to it.
#   3. omarchy-apple-dev's SwiftBuild additions (install-toolchain.sh
#      install_darwin_tools + install_oam at the pinned commit): Linux actool,
#      ibtool, xcstringstool, momc in the platforms' Developer/usr/bin,
#      toolset-swb.json flags, strings encodings, and its OpenAppleMacros fork.
#   4. Register for `user`: ~/.swiftpm/swift-sdks and ~/.config/swiftpm/swift-sdks
#      (when XDG_CONFIG_HOME is set) link to the bundle; `swift sdk list` = darwin.
set -euo pipefail
umask 022
: "${MNT:?}" "${CACHE:?}" "${HERE:?}"

C="$CACHE/ios-sdk"
XIP=${XCODE_XIP:-$CACHE/Xcode_27.1.xip}
BUNDLE=/opt/swift-sdks/darwin.artifactbundle
O=/opt/omarchy-apple-dev

TOOLSET_VERSION=1.1.0   # = SDKBuilder.darwinToolsVersion of our xtool
TOOLSET_SHA256=a5166f2d56ac45707e5ef2f3c20a41a94af8ef0c0456354224dd08656e874188
OAM_VERSION=1.4.1       # = SDKBuilder.oamVersion
OAM_SHA256=2d80c922d0873dd8b0a85e19d10bd7f42a1aea3db3a85f7b6edf56fe9b687a21
# omarchy-apple-dev's OpenAppleMacros fork (SwiftData macros, widget #Preview,
# #Predicate), the commit its install-toolchain.sh pins.
OAM_FORK_SHA=cb003a1763b08947dd37376ed8240cbfb4745c32
OAM_FORK_SHA256=52f2d01a3e0438ff12184c20635dee229b11c755e0a52623639ffd6b5720c230

log() { echo "[ios-sdk] $*"; }
die() { echo "[ios-sdk] ERROR: $*" >&2; exit 1; }
# Own PID namespace + /proc inside the chroot: under plain arch-chroot, Swift
# programs read another process's /proc entry and crash (see ios-toolchain.sh).
chroot_run() { arch-chroot "$MNT" unshare --fork --pid --mount-proc "$@"; }
# A clean login shell, as an orb shell gets it: /etc/profile.d applies, host env does not leak.
as_user() {
	chroot_run runuser -u user -- env -i HOME=/home/user USER=user LOGNAME=user SHELL=/bin/bash \
		PATH=/usr/local/sbin:/usr/local/bin:/usr/bin bash -lc 'cd ~ && "$@"' as_user "$@"
}
manifest() {
	touch "$MNT/etc/amp-orb-mobile.manifest"
	sed -i -E '/^(darwin_sdk|xcode)=/d' "$MNT/etc/amp-orb-mobile.manifest"
	printf '%s\n' "$@" >> "$MNT/etc/amp-orb-mobile.manifest"
}
fetch() { # URL FILE SHA256
	local url=$1 file=$C/$2 sha=$3
	if [[ -f $file ]] && echo "$sha  $file" | sha256sum -c --quiet - 2>/dev/null; then return 0; fi
	log "downloading $url"
	curl -fsSL --retry 3 -o "$file.part" "$url"
	echo "$sha  $file.part" | sha256sum -c --quiet - || die "sha256 mismatch for $url"
	mv "$file.part" "$file"
}

if [[ ! -f $XIP ]]; then
	log "SKIPPED: $XIP is not there yet. Put Xcode 27.1's .xip there (or set XCODE_XIP) and rerun with --only ios-sdk."
	manifest "darwin_sdk=skipped (no $(basename "$XIP"))"
	exit 0
fi
for p in /opt/swift/usr/bin/swift /opt/xtool/xtool "$O/tools/darwin-tools/bin/actool"; do
	[[ -x $MNT$p ]] || die "$p missing: run ios-toolchain first"
done

install -d -m 0755 "$C"
# One run at a time per cache (orb and test images may build concurrently).
exec 9>"$C/.lock"
flock 9
# The cache (with the .xip and a scratch dir on the host disk, not in the image)
# is visible inside the chroot while the module runs.
GUEST_CACHE=/var/tmp/ios-sdk-cache
WORK=
cleanup() {
	local status=$?
	if mountpoint -q "$MNT$GUEST_CACHE"; then umount "$MNT$GUEST_CACHE"; fi
	rmdir "$MNT$GUEST_CACHE" 2>/dev/null || true
	[[ -z $WORK ]] || rm -rf "$WORK"
	exit "$status"
}
trap cleanup EXIT
install -d "$MNT$GUEST_CACHE"
mountpoint -q "$MNT$GUEST_CACHE" || mount --bind "$CACHE" "$MNT$GUEST_CACHE"
guest_path() { echo "$GUEST_CACHE/${1#"$CACHE"/}"; }
[[ $XIP == "$CACHE"/* ]] || die "XCODE_XIP must be inside $CACHE"

# sha256 of the .xip, remembered per size+mtime (hashing ~5 GB takes a while).
xip_stat=$(stat -c '%s-%Y' "$XIP")
xip_sum_file=$C/$(basename "$XIP").$xip_stat.sha256
[[ -s $xip_sum_file ]] || sha256sum "$XIP" | cut -d' ' -f1 > "$xip_sum_file"
xip_sha=$(cat "$xip_sum_file")
xtool_sha=$(sha256sum < "$MNT/opt/xtool/xtool" | cut -c1-12)
sdk_cache=$C/darwin-xip${xip_sha:0:16}-xtool$xtool_sha.xtoolsdk.tar.zst

fetch "https://github.com/xtool-org/darwin-tools-linux-llvm/releases/download/v$TOOLSET_VERSION/toolset-x86_64.tar.gz" \
	"darwin-tools-linux-llvm-$TOOLSET_VERSION-toolset-x86_64.tar.gz" "$TOOLSET_SHA256"
fetch "https://github.com/xtool-org/OpenAppleMacros/releases/download/v$OAM_VERSION/OpenAppleMacrosServer-x86_64.tar.gz" \
	"OpenAppleMacrosServer-$OAM_VERSION-x86_64.tar.gz" "$OAM_SHA256"

# ---------------------------------------------------------------- 1. build (cached)
if [[ ! -f $sdk_cache ]]; then
	log "xtool sdk build $(basename "$XIP")"
	WORK=$(mktemp -d "$C/work.XXXXXX")
	chroot_run env HOME="$(guest_path "$WORK")" \
		XTL_TOOLSET_TARBALL="$(guest_path "$C")/darwin-tools-linux-llvm-$TOOLSET_VERSION-toolset-x86_64.tar.gz" \
		XTL_OAM_TARBALL="$(guest_path "$C")/OpenAppleMacrosServer-$OAM_VERSION-x86_64.tar.gz" \
		bash -c 'cd "$1" && /opt/xtool/xtool sdk build "$0" "$1/out"' "$(guest_path "$XIP")" "$(guest_path "$WORK")" \
		> "$C/sdk-build.log" 2>&1 || { tail -30 "$C/sdk-build.log" >&2; die "xtool sdk build failed (log: $C/sdk-build.log)"; }
	[[ -f $WORK/out/darwin.xtoolsdk/darwin-sdk-version.txt ]] || die "xtool sdk build produced no darwin.xtoolsdk"
	# Xcode's version.plist (xcodebuild -version; omarchy ship.sh's DTXcode), streamed from the .xip.
	chroot_run python3 -I "$O/tools/xip_version.py" "$(guest_path "$XIP")" "$(guest_path "$WORK")/out/darwin.xtoolsdk/Xcode.version.plist" \
		|| die "could not read Xcode's version.plist from the .xip"
	tar --zstd -cf "$sdk_cache.part" -C "$WORK/out" darwin.xtoolsdk
	mv "$sdk_cache.part" "$sdk_cache"
	[[ -z $WORK ]] || rm -rf "$WORK"
fi

# ---------------------------------------------------------------- 2. install
log "installing $BUNDLE"
rm -rf "$MNT/opt/swift-sdks"
install -d "$MNT/opt/swift-sdks"
tar --zstd -xf "$sdk_cache" -C "$MNT/opt/swift-sdks" --no-same-owner
mv "$MNT/opt/swift-sdks/darwin.xtoolsdk/Xcode.version.plist" "$MNT/opt/swift-sdks/Xcode.version.plist"
mv "$MNT/opt/swift-sdks/darwin.xtoolsdk" "$MNT$BUNDLE"
# What `xtool sdk install` adds: the host compiler's clang headers (intrinsics differ by LLVM version).
clang_include=$(chroot_run bash -c 'echo "$(swiftc -print-target-info | python3 -c "import json,sys; print(json.load(sys.stdin)[\"paths\"][\"runtimeResourcePath\"])")/clang/include"')
cp -rL "$MNT$clang_include" "$MNT$BUNDLE/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/clang/include"

# ---------------------------------------------------------------- 3. omarchy SwiftBuild additions
log "omarchy darwin tools + OpenAppleMacros fork"
for platform in iPhoneOS MacOSX; do
	bin=$MNT$BUNDLE/Developer/Platforms/$platform.platform/Developer/usr/bin
	install -d "$bin"
	install -m755 "$MNT$O/tools/darwin-tools/bin/actool" "$MNT$O/tools/xcstringstool" "$MNT$O/tools/ibtool" "$MNT$O/tools/momc" "$bin/"
	install -m644 "$MNT$O/tools/nibarchive.py" "$MNT$O/tools/keyorder.py" "$MNT$O/tools/xcstrings_symbols.py" "$bin/"
done
install -m644 "$MNT$O/tools/ibmac.py" "$MNT$BUNDLE/Developer/Platforms/MacOSX.platform/Developer/usr/bin/"
# The settings half of install_darwin_tools, taken verbatim from the pinned
# install-toolchain.sh: platform/SDK DefaultProperties, toolset-swb.json flags
# (cross-import overlays; -lswiftCore -L/usr/lib/swift -all_load for dynamic
# products) and the SwiftBuild xcspec string-encoding defaults in /opt/swift.
awk '/^install_darwin_tools\(\) \{/{f=1} f&&/<<.PY.$/{p=1;next} p&&/^PY$/{exit} p' "$MNT$O/install-toolchain.sh" > "$MNT/var/tmp/ios-sdk-settings.py"
grep -q 'toolset-swb.json' "$MNT/var/tmp/ios-sdk-settings.py" || die "could not extract install_darwin_tools settings from $O/install-toolchain.sh"
chroot_run python3 /var/tmp/ios-sdk-settings.py "$BUNDLE"
rm -f "$MNT/var/tmp/ios-sdk-settings.py"
# Link the ObjC runtime the way Xcode's link step does (-fobjc-link-runtime):
# without it a target of only .mm files (no clang-module autolinking for
# ObjC++) leaves objc_msgSend & co. undefined.
chroot_run python3 - "$BUNDLE/toolset-swb.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
opts = d.setdefault("linker", {}).setdefault("extraCLIOptions", [])
if "-lobjc" not in opts:
    opts.append("-lobjc")
json.dump(d, open(p, "w"), indent=4)
PY

fetch "https://codeload.github.com/joshuaswarren/OpenAppleMacros/tar.gz/$OAM_FORK_SHA" "OpenAppleMacros-$OAM_FORK_SHA.tar.gz" "$OAM_FORK_SHA256"
swift_version=$(cat "$MNT/opt/swift/.srv-mobile-version" | cut -d' ' -f1)
oam_build=$C/OpenAppleMacrosServer-$OAM_FORK_SHA-${swift_version%.tar.gz}.gz
if [[ ! -f $oam_build ]]; then
	src=$MNT/var/tmp/ios-sdk-oam
	rm -rf "$src"
	install -d "$src"
	tar -xzf "$C/OpenAppleMacros-$OAM_FORK_SHA.tar.gz" -C "$src" --strip-components=1 --no-same-owner
	chroot_run bash -c 'cd /var/tmp/ios-sdk-oam && swift build -c release --build-system native --static-swift-stdlib --product OpenAppleMacrosServer' \
		> "$C/oam-build.log" 2>&1 || { tail -20 "$C/oam-build.log" >&2; die "OpenAppleMacros build failed"; }
	gzip -c "$src/.build/release/OpenAppleMacrosServer" > "$oam_build.part"
	mv "$oam_build.part" "$oam_build"
	rm -rf "$src"
fi
gzip -dc "$oam_build" > "$MNT$BUNDLE/OpenAppleMacrosServer"
chmod 0755 "$MNT$BUNDLE/OpenAppleMacrosServer"
# Empty plugin stubs make swiftc route these modules to the server (install_oam).
plugins=$MNT$BUNDLE/Developer/Platforms/iPhoneOS.platform/Developer/usr/lib/swift/host/plugins
: > "$plugins/libSwiftDataMacros.so"
: > "$plugins/libFoundationMacros.so"

# ---------------------------------------------------------------- 4. register for user
user_uid=$(chroot_run id -u user)
user_gid=$(chroot_run id -g user)
for dir in /home/user/.swiftpm /home/user/.swiftpm/swift-sdks /home/user/.config /home/user/.config/swiftpm /home/user/.config/swiftpm/swift-sdks; do
	install -d -m 0755 -o "$user_uid" -g "$user_gid" "$MNT$dir"
done
for dir in /home/user/.swiftpm/swift-sdks /home/user/.config/swiftpm/swift-sdks; do
	rm -rf "$MNT$dir/darwin.artifactbundle"
	ln -sfn "$BUNDLE" "$MNT$dir/darwin.artifactbundle"
	chown -h "$user_uid:$user_gid" "$MNT$dir/darwin.artifactbundle"
done

# `swift-build-ios`: swift build for iOS set up as xtool runs SwiftBuild.
install -m 0755 "$HERE/modules/ios-sdk.d/swift-build-ios" "$MNT/usr/local/bin/swift-build-ios"
# SwiftBuild resolves the iphoneos platform only through this (xtool and
# omarchy's Flutter lane set it too); harmless for everything else.
install -d "$MNT/etc/systemd/system.conf.d"
printf '[Manager]\nDefaultEnvironment=XCODE_EXTRA_PLATFORM_FOLDERS=%s\n' "$BUNDLE/Developer/Platforms" \
	> "$MNT/etc/systemd/system.conf.d/mobile-ios-sdk.conf"
printf '# ios-sdk (srv-orbs/mobile)\nexport XCODE_EXTRA_PLATFORM_FOLDERS=%s\n' "$BUNDLE/Developer/Platforms" \
	> "$MNT/etc/profile.d/mobile-ios-sdk.sh"

# ---------------------------------------------------------------- verify (as user)
log "verifying"
# The checks run as user in ~; afterwards drop whatever they left in it (caches).
home_before=$(mktemp)
chroot_run find /home/user -xdev -mindepth 1 | sort > "$home_before"
xtool_current=$(as_user xtool sdk status | sed -n 's/^ *Version: //p')
[[ $xtool_current == "$(cat "$MNT$BUNDLE/darwin-sdk-version.txt")" ]] || die "xtool sdk status: '$xtool_current'"
as_user swift sdk list | grep -qx darwin || die "swift sdk list does not show darwin"
# Not every Xcode is known to ship it; report rather than fail.
xctrunner=$(cd "$MNT$BUNDLE" && find Developer/Platforms/iPhoneOS.platform/Developer/Library -maxdepth 4 -name XCTRunner.app | head -1)
log "XCTRunner.app: ${xctrunner:-not in this Xcode}"
ios_sdk_version=$(chroot_run python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["Version"])' \
	"$BUNDLE/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk/SDKSettings.json")
# One ObjC++ SwiftPM library target, compiled and linked for iOS with SwiftBuild
# (the path React Native/Expo native code takes), a Swift target in Debug, and
# xtool's own app template.
as_user bash -euo pipefail -c '
	t=$(mktemp -d /var/tmp/ios-sdk-check.XXXXXX)
	trap "rm -rf $t" EXIT
	mkdir -p "$t/Sources/Probe/include" "$t/Sources/SwiftProbe"
	cat > "$t/Package.swift" <<EOF
// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "Probe", platforms: [.iOS("16.4")],
    products: [.library(name: "Probe", type: .dynamic, targets: ["Probe"])],
    targets: [
        .target(name: "Probe", linkerSettings: [.linkedFramework("Foundation"), .linkedFramework("UIKit")]),
        .target(name: "SwiftProbe"),
    ])
EOF
	echo "#import <Foundation/Foundation.h>
@interface Probe : NSObject
+ (NSString *)hello;
@end" > "$t/Sources/Probe/include/Probe.h"
	echo "#import \"Probe.h\"
#import <UIKit/UIKit.h>
#include <string>
@implementation Probe
+ (NSString *)hello { std::string s = \"hi \"; s += UIDevice.currentDevice.systemName.UTF8String ?: \"\"; return @(s.c_str()); }
@end" > "$t/Sources/Probe/Probe.mm"
	echo "public func hello() -> String { \"hi\" }" > "$t/Sources/SwiftProbe/SwiftProbe.swift"
	cd "$t"
	swift-build-ios --product Probe > build.log 2>&1 || { tail -30 build.log; exit 1; }
	bin=.build/out/Products/Debug-iphoneos/libProbe.dylib
	file "$bin" | grep -q "Mach-O 64-bit arm64 dynamically linked shared library" || { file "$bin"; exit 1; }
	llvm-otool -l "$bin" | grep -A4 LC_BUILD_VERSION | grep -q "platform 2"
	swift-build-ios --target SwiftProbe > build-swift.log 2>&1 || { tail -30 build-swift.log; exit 1; }
	cd "$t" && xtool new Hello --skip-setup < /dev/null > new.log 2>&1 || { tail -20 new.log; exit 1; }
	cd Hello && xtool dev build < /dev/null > ../xtool-build.log 2>&1 || { tail -30 ../xtool-build.log; exit 1; }
	file xtool/Hello.app/Hello | grep -q "Mach-O 64-bit arm64 executable" || { file xtool/Hello.app/Hello; exit 1; }
' || die "iOS build checks failed"
chroot_run find /home/user -xdev -mindepth 1 | sort | comm -13 "$home_before" - | while read -r p; do
	[[ ! -e $MNT$p && ! -L $MNT$p ]] || rm -rf "$MNT$p"
done
rm -f "$home_before"

manifest "darwin_sdk=iPhoneOS $ios_sdk_version, xtool stamp $xtool_current, $(du -sh "$MNT$BUNDLE" | cut -f1), xctrunner=${xctrunner:-none}, xip sha256 $xip_sha" \
	"xcode=$(chroot_run python3 -c 'import plistlib,sys; p=plistlib.load(open(sys.argv[1],"rb")); print(p["CFBundleShortVersionString"], p["ProductBuildVersion"])' /opt/swift-sdks/Xcode.version.plist)"
log "done"
