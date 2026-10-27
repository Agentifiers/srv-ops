#!/usr/bin/env bash
# Builds agent-device's iOS XCUITest runner on Linux, without Xcode, from the
# sources the npm package ships (dist/apple/runner + dist/apple/snapshot-presentation):
#
#   OUT/Release-iphoneos/AgentDeviceRunner.app                the UI-test target app (ObjC host app)
#   OUT/Release-iphoneos/AgentDeviceRunnerUITests-Runner.app  XCTRunner.app from the SDK, renamed, with
#       PlugIns/AgentDeviceRunnerUITests.xctest               the runner tests (Swift + ObjC, MH_BUNDLE)
#       Frameworks/                                           XCTest, XCUIAutomation and their private deps
#   OUT/AgentDeviceRunner.xctestrun                           what agent-device's iosXctestrunFile points at
#
# Both apps are unsigned (the phone broker signs them at install). Bundle identifiers:
# RUNNER_APP_ID (default com.callstack.agentdevice.runner) for the target app, <app>.uitests
# for the test bundle and <app>.uitests.xctrunner for the runner app, which is what agent-device
# derives from AGENT_DEVICE_IOS_RUNNER_APP_BUNDLE_ID. CFBundleVersion of both apps is a build
# stamp (a hash of the binaries), so an installer can tell whether the phone has this build.
#
# This is what Xcode's build-for-testing produces for the AgentDeviceRunner scheme
# (iphoneos, Release, arm64), done with swiftc/clang from the Swift toolchain,
# ld64.lld and the Darwin SDK bundle (ios-sdk.sh).
#
# usage: build-runner.sh SRC_APPLE_DIR OUT_DIR
set -euo pipefail
umask 022

src=${1:?usage: build-runner.sh SRC_APPLE_DIR OUT_DIR}
out=${2:?usage: build-runner.sh SRC_APPLE_DIR OUT_DIR}
src=$(readlink -f "$src")
SDKB=${DARWIN_SDK_BUNDLE:-/opt/swift-sdks/darwin.artifactbundle}
PLAT=$SDKB/Developer/Platforms/iPhoneOS.platform
SDK=$PLAT/Developer/SDKs/iPhoneOS.sdk
DEV=$PLAT/Developer
# Apple's Swift resources (SwiftShims, the stdlib's .swiftinterface companions, compat libs).
XCTC=$SDKB/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift
# Xcode clang's builtins (__isPlatformVersionAtLeast for #available); the Linux clang has none for iOS.
CLANG_RT=$(ls "$SDKB"/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/clang/*/lib/darwin/libclang_rt.ios.a | head -n1)
MIN_IOS=${RUNNER_MIN_IOS:-17.0}
TARGET=arm64-apple-ios$MIN_IOS
APP_ID=${RUNNER_APP_ID:-com.callstack.agentdevice.runner}
TEST_ID=$APP_ID.uitests
JOBS=${JOBS:-$(nproc)}

log() { echo "[build-runner] $*"; }
# ld64.lld warns once per object that it "does not support linking for platform iOS" and about
# auto-linked private sub-frameworks (UIUtilities, CoreAudioTypes) the SDK has no stubs for.
link() {
	"$@" 2>&1 | grep -v -e 'does not support linking for platform iOS' -e 'auto-linked framework not found' >&2 || true
	return "${PIPESTATUS[0]}"
}
die() { echo "[build-runner] ERROR: $*" >&2; exit 1; }

[[ -d $SDK ]] || die "no iPhoneOS SDK at $SDK (ios-sdk.sh)"
[[ -d $DEV/Library/Xcode/Agents/XCTRunner.app ]] || die "no XCTRunner.app in the SDK bundle"
runner_src=$src/runner/AgentDeviceRunner
presentation_src=$src/snapshot-presentation/Sources/AgentDeviceSnapshotPresentation
[[ -d $runner_src/AgentDeviceRunnerUITests && -d $presentation_src ]] || die "runner sources missing under $src"

swift_bin=$(dirname "$(readlink -f "$(command -v swiftc)")")
LD=$SDKB/toolset/bin/ld64.lld
[[ -x $LD ]] || LD=$(command -v ld64.lld)

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
obj=$work/obj
mkdir -p "$obj"

# --- AgentDeviceSnapshotPresentation (SwiftPM library, linked into the test bundle) ---
log "AgentDeviceSnapshotPresentation"
"$swift_bin/swiftc" -target "$TARGET" -sdk "$SDK" -resource-dir "$XCTC" -O -wmo -suppress-warnings -parse-as-library \
	-module-name AgentDeviceSnapshotPresentation -swift-version 5 \
	-emit-module -emit-module-path "$work/mod/AgentDeviceSnapshotPresentation.swiftmodule" \
	-c -o "$obj/AgentDeviceSnapshotPresentation.o" \
	"$presentation_src"/*.swift

# --- UI test bundle: ObjC sources ---
uit=$runner_src/AgentDeviceRunnerUITests
cflags=(-target "$TARGET" -isysroot "$SDK" -F "$DEV/Library/Frameworks" -F "$DEV/Library/PrivateFrameworks"
	-fobjc-arc -fobjc-weak -fmodules -fmodules-cache-path="$work/clang-modules" -O2 -DNDEBUG=1 -w -I "$uit")
log "UI tests: Objective-C"
for m in "$uit"/*.m; do
	"$swift_bin/clang" "${cflags[@]}" -c "$m" -o "$obj/$(basename "${m%.m}").o" &
	while (($(jobs -rp | wc -l) >= JOBS)); do wait -n; done
done
wait

# --- UI test bundle: Swift sources (bridging header pulls in the ObjC headers) ---
log "UI tests: Swift"
swift_srcs=()
for f in "$uit"/*.swift; do swift_srcs+=("$f"); done
"$swift_bin/swiftc" -target "$TARGET" -sdk "$SDK" -resource-dir "$XCTC" -O -wmo -suppress-warnings -num-threads "$JOBS" -swift-version 5 \
	-module-name AgentDeviceRunnerUITests -parse-as-library \
	-F "$DEV/Library/Frameworks" -I "$DEV/usr/lib" -I "$work/mod" \
	-import-objc-header "$uit/AgentDeviceRunnerUITests-Bridging-Header.h" \
	-Xcc -I"$uit" -Xcc -F"$DEV/Library/Frameworks" \
	-module-cache-path "$work/swift-modules" \
	-c "${swift_srcs[@]}" -output-file-map <(
		printf '{'
		sep=
		for f in "${swift_srcs[@]}"; do
			printf '%s"%s":{"object":"%s"}' "$sep" "$f" "$obj/$(basename "${f%.swift}").swift.o"
			sep=,
		done
		printf '}'
	)

# --- UI test bundle: link (MH_BUNDLE loaded by XCTRunner) ---
log "UI tests: link"
xctest=$work/AgentDeviceRunnerUITests.xctest
mkdir -p "$xctest"
link "$swift_bin/clang" -target "$TARGET" -isysroot "$SDK" -fuse-ld="$LD" -mlinker-version=1200 -bundle \
	-F "$DEV/Library/Frameworks" -F "$DEV/Library/PrivateFrameworks" -L "$DEV/usr/lib" \
	-L "$SDK/usr/lib/swift" -L "$XCTC/iphoneos" \
	"$obj"/*.o "$CLANG_RT" \
	-framework XCTest -framework XCUIAutomation -lXCTestSwiftSupport \
	-framework Foundation -framework UIKit -framework CoreGraphics -framework Network \
	-framework AVFoundation -framework CoreVideo -framework UserNotifications -framework CoreMedia \
	-Xlinker -rpath -Xlinker /usr/lib/swift \
	-Xlinker -rpath -Xlinker @loader_path/Frameworks \
	-Xlinker -rpath -Xlinker @executable_path/Frameworks \
	-Xlinker -rpath -Xlinker @loader_path/../../Frameworks \
	-o "$xctest/AgentDeviceRunnerUITests"

plist() { python3 - "$@"; }
plist "$xctest/Info.plist" "$TEST_ID" "$MIN_IOS" <<'PY'
import plistlib, sys
path, bundle_id, min_ios = sys.argv[1:4]
plistlib.dump({
    "CFBundleDevelopmentRegion": "en",
    "CFBundleExecutable": "AgentDeviceRunnerUITests",
    "CFBundleIdentifier": bundle_id,
    "CFBundleInfoDictionaryVersion": "6.0",
    "CFBundleName": "AgentDeviceRunnerUITests",
    "CFBundlePackageType": "BNDL",
    "CFBundleShortVersionString": "1.0",
    "CFBundleSupportedPlatforms": ["iPhoneOS"],
    "CFBundleVersion": "1",
    "MinimumOSVersion": min_ios,
    "UIDeviceFamily": [1, 2],
    "XCTContainsUITests": True,
    "DTPlatformName": "iphoneos",
}, open(path, "wb"))
PY

# --- AgentDeviceUITests-Runner.app: XCTRunner.app renamed, xctest + frameworks inside ---
log "AgentDeviceRunnerUITests-Runner.app"
runner_app=$work/AgentDeviceRunnerUITests-Runner.app
cp -a "$DEV/Library/Xcode/Agents/XCTRunner.app" "$runner_app"
# XCTRunner is arm64 + arm64e; an arm64e host process cannot load our arm64 test bundle
# ("incompatible architecture (have 'arm64', need 'arm64e')"), so keep only the arm64 slice, as
# Xcode does for ARCHS=arm64.
llvm-lipo "$runner_app/XCTRunner" -thin arm64 -output "$runner_app/AgentDeviceRunnerUITests-Runner"
rm "$runner_app/XCTRunner"
rm -f "$runner_app/RunnerEntitlements.plist" "$runner_app/version.plist"
mkdir -p "$runner_app/PlugIns" "$runner_app/Frameworks"
cp -a "$xctest" "$runner_app/PlugIns/"
# What Xcode embeds for an iOS UI-test runner (Copy Files to Frameworks).
for fw in XCTest XCUIAutomation; do
	cp -a "$DEV/Library/Frameworks/$fw.framework" "$runner_app/Frameworks/"
done
for fw in XCTestCore XCUnit XCTAutomationSupport XCTestSupport; do
	cp -a "$DEV/Library/PrivateFrameworks/$fw.framework" "$runner_app/Frameworks/"
done
cp -a "$DEV/usr/lib/libXCTestSwiftSupport.dylib" "$runner_app/Frameworks/"
# Headers and module maps are build inputs only.
find "$runner_app/Frameworks" \( -name Headers -o -name Modules -o -name _CodeSignature \) -prune -exec rm -rf {} +
plist "$runner_app/Info.plist" "$TEST_ID.xctrunner" <<'PY'
import plistlib, sys
path, bundle_id = sys.argv[1:3]
d = plistlib.load(open(path, "rb"))
d["CFBundleIdentifier"] = bundle_id
d["CFBundleName"] = "AgentDeviceRunnerUITests-Runner"
d["CFBundleExecutable"] = "AgentDeviceRunnerUITests-Runner"
plistlib.dump(d, open(path, "wb"))
PY

# --- AgentDeviceRunner.app: the target app the UI tests attach to ---
log "AgentDeviceRunner.app"
host_app=$work/AgentDeviceRunner.app
mkdir -p "$host_app"
link "$swift_bin/clang" -target "$TARGET" -isysroot "$SDK" -fuse-ld="$LD" -mlinker-version=1200 \
	-fobjc-arc -fobjc-weak -fmodules -fmodules-cache-path="$work/clang-modules" -O2 \
	"$runner_src/AgentDeviceRunner/AgentDeviceRunnerApp.m" \
	-framework Foundation -framework UIKit -framework UserNotifications "$CLANG_RT" \
	-o "$host_app/AgentDeviceRunner"
plist "$host_app/Info.plist" "$APP_ID" "$MIN_IOS" "$runner_src/AgentDeviceRunner/Info.plist" <<'PY'
import plistlib, sys
path, bundle_id, min_ios, base = sys.argv[1:5]
d = plistlib.load(open(base, "rb"))
d.update({
    "CFBundleDevelopmentRegion": "en",
    "CFBundleDisplayName": "AgentDeviceRunner",
    "CFBundleExecutable": "AgentDeviceRunner",
    "CFBundleIdentifier": bundle_id,
    "CFBundleInfoDictionaryVersion": "6.0",
    "CFBundleName": "AgentDeviceRunner",
    "CFBundlePackageType": "APPL",
    "CFBundleShortVersionString": "1.0",
    "CFBundleSupportedPlatforms": ["iPhoneOS"],
    "CFBundleVersion": "1",
    "LSRequiresIPhoneOS": True,
    "MinimumOSVersion": min_ios,
    "UIDeviceFamily": [1, 2],
    "UIRequiredDeviceCapabilities": ["arm64"],
    "UILaunchScreen": {},
    "UIApplicationSupportsIndirectInputEvents": True,
    "UISupportedInterfaceOrientations": [
        "UIInterfaceOrientationPortrait",
        "UIInterfaceOrientationLandscapeLeft",
        "UIInterfaceOrientationLandscapeRight",
    ],
    "DTPlatformName": "iphoneos",
})
plistlib.dump(d, open(path, "wb"))
PY
printf 'APPL????' > "$host_app/PkgInfo"

# --- build stamp + .xctestrun ---
stamp=$(cd "$work" && find AgentDeviceRunner.app AgentDeviceRunnerUITests-Runner.app -type f -print0 | sort -z \
	| xargs -0 sha256sum | sha256sum | cut -c1-12)
stamp=$((16#$stamp))
python3 - "$host_app" "$runner_app" "$stamp" "$work/AgentDeviceRunner.xctestrun" "$TEST_ID" <<'PY'
import os, plistlib, sys
host_app, runner_app, stamp, xctestrun, test_id = sys.argv[1:6]
for app in (host_app, runner_app, os.path.join(runner_app, "PlugIns/AgentDeviceRunnerUITests.xctest")):
    p = os.path.join(app, "Info.plist")
    d = plistlib.load(open(p, "rb"))
    d["CFBundleVersion"] = stamp
    plistlib.dump(d, open(p, "wb"))
host_id = plistlib.load(open(os.path.join(host_app, "Info.plist"), "rb"))["CFBundleIdentifier"]
products = "__TESTROOT__/Release-iphoneos"
plistlib.dump({
    "__xctestrun_metadata__": {"FormatVersion": 2},
    "CodeCoverageBuildableInfos": [],
    "TestConfigurations": [{
        "Name": "Test Scheme Action",
        "TestTargets": [{
            "BlueprintName": "AgentDeviceRunnerUITests",
            "BlueprintProviderName": "AgentDeviceRunner",
            "BlueprintProviderRelativePath": "AgentDeviceRunner.xcodeproj",
            "BundleIdentifiersForCrashReportEmphasis": [host_id, test_id],
            "DependentProductPaths": [
                f"{products}/AgentDeviceRunner.app",
                f"{products}/AgentDeviceRunnerUITests-Runner.app",
                f"{products}/AgentDeviceRunnerUITests-Runner.app/PlugIns/AgentDeviceRunnerUITests.xctest",
            ],
            "EnvironmentVariables": {},
            "IsUITestBundle": True,
            "IsXCTRunnerHostedTestBundle": True,
            "ProductModuleName": "AgentDeviceRunnerUITests",
            "SystemAttachmentLifetime": "keepNever",
            "TestBundlePath": "__TESTHOST__/PlugIns/AgentDeviceRunnerUITests.xctest",
            "TestHostBundleIdentifier": f"{test_id}.xctrunner",
            "TestHostPath": f"{products}/AgentDeviceRunnerUITests-Runner.app",
            "TestLanguage": "",
            "TestRegion": "",
            "TestingEnvironmentVariables": {},
            "ToolchainsSettingValue": [],
            "UITargetAppCommandLineArguments": [],
            "UITargetAppEnvironmentVariables": {},
            "UITargetAppPath": f"{products}/AgentDeviceRunner.app",
            "UserAttachmentLifetime": "keepNever",
        }],
    }],
    "TestPlan": {"IsDefault": True, "Name": "AgentDeviceRunnerUITests"},
}, open(xctestrun, "wb"))
PY

rm -rf "$out/Release-iphoneos" "$out/AgentDeviceRunner.xctestrun"
mkdir -p "$out/Release-iphoneos"
mv "$host_app" "$runner_app" "$out/Release-iphoneos/"
mv "$work/AgentDeviceRunner.xctestrun" "$out/"
log "done: $out (build $stamp)"
