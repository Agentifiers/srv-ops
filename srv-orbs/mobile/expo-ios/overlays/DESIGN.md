# Dev client under SwiftPM: target split

expo-dev-client (SDK 58) depends on `expo-dev-launcher` and `expo-dev-menu`. Both
mix Swift and Objective-C, and the two languages call each other. SwiftPM can't
compile a target that mixes languages, so each module is split into targets
that only depend on each other in one direction. Everything here is pinned to
the versions `create-expo-app@latest` + `npx expo install expo-dev-client`
resolved on 2026-10-26:

| package | version | how it builds |
|---|---|---|
| expo-dev-client | 58.0.15 | pure-Swift source package (overlay stub, see below) |
| expo-dev-launcher | 58.0.15 | `spm.config.json` overlay + patch → Linux prebuild |
| expo-dev-menu | 58.0.11 | `spm.config.json` overlay + patch → Linux prebuild |
| expo-dev-menu-interface | 58.0.1 | `spm.config.json` overlay → Linux prebuild |
| expo-manifests, expo-updates-interface | 58.0.1 | their own shipped `spm.config.json` → Linux prebuild |

All of these are Debug only (`.expo-ios.json`). In Release, expo-ios excludes the
dev-client packages from autolinking.

## Why the prebuild route, not a checked-in Package.swift

Expo's SwiftPM plugin (`expo/scripts/spm`) compiles source packages only against
*precompiled* frameworks: the injected `-F compile-interfaces` plus the React
header products. A mirrored `Package.swift` can't depend on another source
package: `.package(path:)` is refused as `local-path` (`manifests.js:118`), and
`direct` manifests get no React headers. expo-dev-launcher imports EXDevMenu
and EXDevMenuInterface, and expo-dev-menu imports EXDevMenuInterface, so all three
must be precompiled. expo-ios's `modules` stage builds every `spm.config.json`
product into `$EXPO_PRECOMPILED_MODULES_PATH`, in dependency order (EXManifests,
EXUpdatesInterface, EXDevMenuInterface, EXDevMenu, EXDevLauncher). The plugin then
links them like Expo's npm prebuilds. The configs use Expo's own format
(`tools/src/prebuilds/SPMConfig.types.ts`). They also rely on the
SPMGenerator.ts staging rules:

- Sources are symlinked with their relative paths kept.
- Headers are staged only when a target sets `headerPattern`. They are
  flattened into `include/<moduleName>/`, so `<EXDevLauncher/X.h>` resolves.
- Each Swift target gets a `<Product>+Exports.swift` that `@_exported import`s its
  sibling targets. That is how the Swift sources see the ObjC classes with no
  `import` edits.
- At framework composition, imports of internal target names in `-Swift.h` and
  `.swiftinterface` files are rewritten to the product module.

Two fields are expo-ios extensions: `resourceBundleName` (CocoaPods' bundle
name) and Swift `compilerFlags` as Swift `-D` conditions.

## The 3-target pattern

The model is Expo's own `expo` package (`Expo` ← `ExpoObjC`, plus `ExpoLoader`
importing both) and the ObjC/Swift split in expo-constants:

```
<P>_ios_objc_base   ObjC: every public header (moduleName <P>) + the .m files that never touch Swift
      ↑
<P>                 Swift, the original module name (ExpoModulesProvider imports it)
      ↑
<P>_ios_objc        ObjC: the .m files that use Swift classes, through the generated <P>-Swift.h
```

All three link into one dynamic `<P>.framework`. The ObjC headers module is
merged into the framework module, just as CocoaPods' mixed framework was.

### expo-dev-launcher → EXDevLauncher

| target | files |
|---|---|
| `EXDevLauncher_ios_objc_base` | headers: `EXDevLauncher.h`, `EXDevLauncherController.h`, `EXDevLauncherUpdatesHelper.h`, `Manifest/EXDevLauncherManifestParser.h`, `ReactNative/EXDevLauncherRCTDevSettings.h`, `Headers/EXDevLauncherReactImports.h`; sources: `EXDevLauncherUpdatesHelper.m`, `ReactNative/EXDevLauncherRCTDevSettings.m` (Foundation/React only) |
| `EXDevLauncher` | all 53 non-test `.swift` files. 7 of them use `EXDevLauncherController` / `EXDevLauncherControllerDelegate` from the base target. `RCTJSStackFrame` comes from React. |
| `EXDevLauncher_ios_objc` | `EXDevLauncher.m`, `EXDevLauncherController.m`, `Manifest/EXDevLauncherManifestParser.m`: they import `EXDevLauncher-Swift.h` for the error manager, the view controller, the registries, the URL helper and the network interceptor |

Cross-module edges:
- The base target's `EXDevLauncherController.h` uses `EXUpdatesInterface-Swift.h`
  and `EXManifests-Swift.h` from other, earlier packages, plus
  `<React_RCTAppDelegate/RCTAppDelegate.h>` from RN's `ReactNativeHeaders`.
- The impl target also imports EXDevMenu.

Flags follow the podspec:
- ObjC: `EX_DEV_LAUNCHER_VERSION=<version>`, `USE_HERMES=1`,
  `REACT_NATIVE_TARGET_VERSION=88`, `DEBUG=1`.
- Swift (Debug): `DEBUG`, `EX_DEV_CLIENT_NETWORK_INSPECTOR`, plus `-Xcc -DDEBUG=1`.
  The extra flag makes Swift's clang importer see React with `RCT_DEV=1`:
  `RCTDevSettings.packagerConnection` is declared only under `#if RCT_DEV`,
  which `RCTDefines.h` derives from `DEBUG`. CocoaPods passed
  `GCC_PREPROCESSOR_DEFINITIONS` to swiftc the same way.

Resources: `ios/Assets.xcassets` → `EXDevLauncher.bundle`.

### expo-dev-menu → EXDevMenu

| target | files |
|---|---|
| `EXDevMenu_ios_objc_base` | headers: `EXDevMenuAppInfo.h`, `Interceptors/RCTKeyCommands.h`; source: `Interceptors/RCTKeyCommands.m`. It is macOS-only (`#if TARGET_OS_OSX`) and compiles to nothing on iOS, as under CocoaPods. On iOS, Swift's `RCTKeyCommands` is React's. |
| `EXDevMenu` | all 42 non-test `.swift` files. `DevMenuManager.swift` uses `EXDevMenuAppInfo`. |
| `EXDevMenu_ios_objc` | `EXDevMenuAppInfo.m`: it uses `DevMenuManager` through `EXDevMenu-Swift.h`, and EXManifests |

`Headers/EXDevMenu.h` is left out on purpose: it only re-includes CocoaPods'
`EXDevMenu-umbrella.h`, and nothing imports it.

Flags: ObjC gets `EX_DEV_MENU_ENABLED=1`, `USE_HERMES=1` (`EXDevMenuAppInfo.m`
reports the engine from it) and `DEBUG=1`. Swift gets `EX_DEV_MENU_ENABLED`,
`DEBUG` and `-Xcc -DDEBUG=1`, for the same `RCT_DEV` reason.

Resources: `ios/Assets.xcassets` → `EXDevMenu.bundle`.

### expo-dev-menu-interface → EXDevMenuInterface

Pure Swift (5 files, Foundation/UIKit only), one target. It still needs an
`spm.config.json`: expo-dev-menu and expo-dev-launcher compile against it, and a
source package wouldn't be visible to their prebuilds. The module name is
`EXDevMenuInterface`, the podspec's `header_dir`, not the `expo_dev_menu_interface`
autolinking derives from the pod name.

### expo-dev-client

expo-dev-client has no native sources: `ios/` holds only a podspec. The plugin
classifies it as pure Swift and emits an empty target, which SwiftPM rejects
(*"target 'expo-dev-client' referenced in product 'expo-dev-client' is
empty"*). The overlay `ios/ExpoDevClientSPM.swift` is a comment-only source
file, so the Debug graph resolves.

## Patches (`../patches/`)

**expo-dev-launcher+58.0.15**
- **`-Swift.h` fallbacks.** In `EXDevLauncher.m`, `EXDevLauncherController.m` and
  `EXDevLauncherManifestParser.m`, the `#else #import <EXDevLauncher-Swift.h>`
  branch becomes an `#elif __has_include(...)` branch, followed by
  `#else @import EXDevLauncher;`. Expo's `ExpoLoader` does the same: the base
  target's `include/EXDevLauncher/` directory shadows the framework-style path,
  so the Swift half is imported as a module.
  `EXDevLauncherController.h` gets the same fallback for EXUpdatesInterface and
  EXManifests.
- **`RCTAppDependencyProvider`.** It is generated per app and linked into the
  app executable. Instead of importing `<ReactAppDependencyProvider/...>` and
  linking against it, `EXDevLauncherController.m` now calls
  `NSClassFromString(@"RCTAppDependencyProvider")`. The prebuilt framework
  therefore has no undefined app symbol and doesn't depend on the app's codegen
  headers, so it can be cached per package version. The app's AppDelegate
  already references the class, so it is linked in.
- **Resource bundle lookup.** `getDevLauncherBundle()` also looks for
  `EXDevLauncher.bundle` inside the framework, via `Bundle(for:)`. CocoaPods
  put the bundle in the app root. Under CocoaPods' static framework,
  `Bundle(for:)` is the main bundle, so behaviour there is unchanged.
- **Forward-declared Swift types in ObjC properties.**
  `EXDevLauncherController.h` types `delegate` and `recentlyOpenedAppsRegistry`
  with `@class` forward declarations of Swift classes. In a mixed CocoaPods
  module, Swift resolves those to its own classes. Across the split, the importer
  can't, so it drops both properties from the Swift view.
  `DevLauncherDevMenuDelegate.swift` and `DevLauncherViewModel.swift` therefore
  read them with KVC (`value(forKey:)`) cast to the Swift class. These are the
  only two Swift uses.

**expo-dev-menu+58.0.11**
- `EXDevMenuAppInfo.m` gets the same `@import EXDevMenu;` fallback.
- `getDevMenuBundle()` gets the same `Bundle(for:)` lookup.

## Debug registration (ExpoModulesProvider)

Autolinking lists `debugOnly: true` for dev-launcher and dev-menu. The generated
provider imports `EXDevLauncher` and `EXDevMenu` only under
`EXPO_CONFIGURATION_DEBUG`, and registers:
- `DevLauncherModule`, `DevMenuModule` and `DevMenuPreferences`
- the app delegate subscriber `ExpoDevLauncherAppDelegateSubscriber`
- the React delegate handler `ExpoDevLauncherReactDelegateHandler`

These are all public Swift classes in the Swift targets above. The ObjC bridge
module `EXDevLauncher` (`RCT_EXPORT_MODULE`) registers itself in `+load` from
the impl target.

## Validation

A scratch harness staged the five products by Expo's rules into one SwiftPM
package. Other products' `<P>-Swift.h` module maps were passed with
`-fmodule-map-file`, standing in for their frameworks. Results:
- Every non-test `.h/.m/.swift` is claimed by exactly one target, with the
  exception above.
- `swift package describe` (Swift 6.4.1, Linux) resolves the package.
- The target graph is acyclic: EXManifests → EXUpdatesInterface →
  EXDevMenuInterface → EXDevMenu_ios_objc_base → EXDevLauncher_ios_objc_base →
  EXDevMenu → EXDevMenu_ios_objc → EXDevLauncher → EXDevLauncher_ios_objc.
- No base-target file imports its own package's Swift half.
- Expo's plugin, run with the overlays, recognises dev-launcher and dev-menu as
  prebuildable products.

Compiling with the iOS 27.1 SDK from Xcode 27.1:
- Clean `swift build -c debug --build-system swiftbuild --triple
  arm64-apple-ios16.4 --toolset toolset-swb.json --target EXDevLauncher_ios_objc`
  builds all nine targets in 27 s. `-c release` also builds.
- Swift Build emits `GeneratedModuleMaps-iphoneos/EXDevLauncher-Swift.h` and
  `EXDevMenu-Swift.h`, plus `module EXDevLauncher { header
  "EXDevLauncher-Swift.h" }`.
- The impl targets reach those headers through the `@import` fallback:
  `EXDevLauncherController.d` lists `EXDevLauncher.modulemap`.
- The impl objects reference Swift classes, for example
  `_OBJC_CLASS_$__TtC13EXDevLauncher25EXDevLauncherErrorManager` and
  `_OBJC_CLASS_$__TtC9EXDevMenu14DevMenuManager`.
- The compiled launcher code has no `RCTAppDependencyProvider` symbol reference.
- The generated `-Swift.h` begins with `@import EXDevLauncher_ios_objc_base;`.
  Framework composition has to rewrite that import, as Expo's `Frameworks.ts`
  does.
