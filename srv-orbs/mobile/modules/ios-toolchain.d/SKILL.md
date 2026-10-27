---
name: ios-toolchain
description: Build, sign, install and run iOS apps from this Linux orb (no Mac, no Xcode, no EAS) with Swift + xtool + the Darwin SDK, omarchy-apple-dev tools and pymobiledevice3 over the tailnet. Use for native iOS builds, signing, and talking to the iPhone.
---

# iOS toolchain in the orb

Everything is preinstalled; nothing here needs macOS.

| What | Where |
|---|---|
| Swift 6.4 (swift.org) | `swift`, `swiftc` → `/opt/swift/usr/bin` |
| Darwin SDK (from Xcode 27.1) | `swift sdk list` → `darwin`; bundle `$DARWIN_SDK_BUNDLE` (`/opt/swift-sdks/darwin.artifactbundle`) |
| xtool (omarchy fork build) | `xtool` |
| pymobiledevice3 | `pymobiledevice3` (venv `/opt/pymobiledevice3`) |
| omarchy-apple-dev | `$OMARCHY_APPLE_DEV` (`/opt/omarchy-apple-dev`); wrappers `tailnet-tunnel`, `device-run`, `provision-dev`, `sign-dev`, `asc`, `macho-lint` |
| Signing | `rcodesign`, `sign-dev`, or `xtool` (Apple ID: `xtool auth`) |
| CocoaPods (metadata only: `pod ipc spec`) | `pod` |
| macOS tool stand-ins | `$MOBILE_SHIMS_BIN` (`xcrun`, `xcodebuild -version`, `plutil`, `otool`, `lipo`, `install_name_tool`, `actool`, `ibtool`, ...) — not on PATH; run `with-mobile-shims <cmd>` |

## Build

- SwiftPM iOS app: `xtool new Hello --skip-setup && cd Hello && xtool dev build` (→ `xtool/Hello.app`, arm64).
- Any SwiftPM package for iOS, including C/ObjC/ObjC++ targets: `swift-build-ios [-c debug|release] [--product X]`
  (= `swift build --build-system swiftbuild --triple arm64-apple-ios16.4 --toolset $DARWIN_SDK_BUNDLE/toolset-swb.json`
  with `$DARWIN_SDK_BUNDLE/toolset/bin` on PATH; `IPHONEOS_DEPLOYMENT_TARGET` changes 16.4). Do not pass `--swift-sdk`.
  Outputs land in `.build/out/Products/<Debug|Release>-iphoneos/`.
- ObjC++-only targets: declare the frameworks they use (`linkerSettings: [.linkedFramework("Foundation")]`); no clang-module autolinking for `.mm`.

## Device (iPhone over the tailnet)

Pairing record `~/.local/share/pymobiledevice3/remote_<udid>.plist` comes from project secrets, never the image. The phone must be awake, on Wi-Fi, with Tailscale on.

- Tunnel: `tailnet-tunnel <phone-100.x-ip> --hold 600` → prints `RSD <addr> <port>` (needs sudo for the TUN device).
- Then `pymobiledevice3 ... --rsd <addr> <port>`: `apps install X.ipa`, `developer dvt launch <bundle id>`, `developer dvt screenshot out.png`, `syslog live`.
- All in one: `device-run --over-tailnet <ip> App.ipa`.
- Signing for a paid team: `provision-dev --bundle-id <id> --udid <udid>` (ASC API key env vars), then `sign-dev App.app App.ipa`.

No iOS Simulator exists here.
