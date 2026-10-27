---
name: expo-ios
description: Build Expo / React Native iOS apps (.app/.ipa) inside this Linux orb with no Mac, no Xcode and no EAS, then sign and install them on the team iPhone over the tailnet. Use for any iOS build of an Expo SDK 58 project.
---

# expo-ios

`expo-ios` builds an Expo SDK 58 (React Native 0.88) app for a real iPhone (arm64) from
Linux. It uses Expo's and React Native's SwiftPM path and Apple's SDK extracted from
Xcode. There is no iOS Simulator here: test on the iPhone, or use Android (redroid).

## Build

Run inside the Expo project (it must have `node_modules`):

```bash
expo-ios build --configuration Release   # embedded Hermes bundle, no dev tools
expo-ios build --configuration Debug     # dev client (needs expo-dev-client); JS from Metro
```

Output: `ios/build/expo-ios/<Configuration>/App.app`, `App-unsigned.ipa`, `App.app.dSYM`,
`build.json` (stage timings, Info.plist summary, linked/embedded frameworks, checks) and
`closure.json`. `--out DIR` puts them elsewhere. Logs per stage: `.expo/expo-ios/logs/`
(`tail -f .expo/expo-ios/logs/compile-release.log` during the compile).

- Timings on this orb (8 vCPU): fresh `create-expo-app` Release ≈ 7 min (compile ≈ 4 min),
  Debug with expo-dev-client ≈ 4 min; reruns are incremental (`--only assemble,package`
  ≈ 15 s). Linux prebuilds of `@expo/ui` and the dev-client modules are cached per SDK in
  `~/.cache/expo-ios` (the image ships them warm).
- Every build checks the result: arm64 iOS executable with `minos` = deployment target,
  all `@rpath` frameworks embedded, Hermes bytecode bundle (Release), and a dyld-style
  symbol closure over every image against the iOS SDK `.tbd`s. A failing check fails the
  build and names the image and symbols; don't hand-patch `App.app` around it.
- `ios/` is regenerated with `expo prebuild` only when app config, `package.json` or the
  lockfile change (`--clean` forces it). Don't hand-edit `ios/`: use config plugins.
- Missing `ios.bundleIdentifier`: expo-ios writes `com.anonymous.<slug>` (or
  `EXPO_IOS_BUNDLE_ID`) into app.json, as `expo prebuild` would. For signing, set a bundle id
  under the team.
- Stop early / rerun parts: `--until graph`, `--only js,resources,plist,assemble,package`,
  `expo-ios stages`. `expo-ios doctor` lists the toolchain and missing credentials.
- Leave a native module out: `EXPO_IOS_EXCLUDE=pkg-a,pkg-b`.
- A build that stops with `command failed (exit null)` from `swift build` hit an
  intermittent SwiftPM crash on Linux: just rerun it.

Not supported: Objective-C/C++ files in the app target itself (put native code in a local
Expo module), CocoaPods-only third-party pods that mix Swift and Objective-C (they need a
`Package.swift` or `spm.config.json`: see `/opt/expo-ios/README.md`), Simulator and App
Store builds. Builds have passed every static check but have not yet been launched on a
device: if the first launch crashes, collect the evidence (`iphone launch <id> --console 30`,
`iphone crashes <executable>`, `iphone syslog <executable>`) before changing anything.

## Sign and install on the iPhone

```bash
expo-ios sign    --configuration Release   # → App.ipa (iOS Development profile)
expo-ios install --configuration Release --launch 30
```

The shared iPhone is wired to the srv host and lent to one orb at a time. Before using
it, read the `iphone` skill: it covers the lease, screenshots, taps and logs.

- Without `ASC_*` variables in the orb (the normal case), `expo-ios sign` runs
  `iphone sign`, and the host signs the app. The bundle id must start with
  `$IPHONE_BUNDLE_PREFIX` (run `echo $IPHONE_BUNDLE_PREFIX`), so set `ios.bundleIdentifier`
  in app.json to match.
- `expo-ios install` runs `iphone install` and then `iphone launch --console N`. It takes
  the lease if it is free. If another thread holds the lease, it exits with code 3.
- Release the phone afterwards with `iphone lease release`.

## Debug builds and Metro

The Debug app is the Expo dev client. The phone runs Tailscale, so it reaches Metro in
this orb by the orb's tailnet name. Open the deep link with `iphone`:

```bash
REACT_NATIVE_PACKAGER_HOSTNAME=$(hostname) npx expo start --dev-client &
iphone launch <bundle id> --url "exp+<scheme>://expo-development-client/?url=http%3A%2F%2F$(hostname)%3A8081"
```

Bonjour discovery does not cross the tailnet, so use the deep link.
