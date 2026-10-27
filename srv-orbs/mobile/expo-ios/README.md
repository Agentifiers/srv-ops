# expo-ios

Builds an Expo (SDK 58 / React Native 0.88) iOS app inside a Linux orb: no
macOS, no Xcode, no EAS. It drives Expo's and React Native's own SwiftPM path
and compiles with `swift build --build-system swiftbuild` against the Darwin
SDK that `ios-sdk.sh` extracts from Xcode.

```
cd <expo project>                                 # needs node_modules (npm install done)
expo-ios build --configuration Release            # → ios/build/expo-ios/Release/App.app + App-unsigned.ipa
expo-ios build --configuration Debug              # dev client build (needs expo-dev-client)
expo-ios build --configuration Release --out /tmp/out
expo-ios build ... --until graph                  # stop after a stage (see `expo-ios stages`)
expo-ios build ... --only assemble,package        # rerun some stages; --skip js,… leaves some out
expo-ios build ... --clean                        # regenerate ios/ with expo prebuild --clean
expo-ios sign    [--configuration C]              # App.app → App.ipa (development profile)
expo-ios install [--configuration C] [--launch]   # App.ipa → iPhone over the tailnet
expo-ios doctor                                   # check toolchain/SDK/credentials
```

Output in `ios/build/expo-ios/<Configuration>/` (or `--out`): `App.app`,
`App-unsigned.ipa`, `App.app.dSYM`, `build.json` (stage timings, Info.plist
summary, `LC_BUILD_VERSION`, linked and embedded frameworks, macho-lint and
closure summaries) and `closure.json`. Logs: `.expo/expo-ios/logs/`.
Environment knobs: `EXPO_IOS_EXCLUDE=pkg,…` (leave native modules out),
`EXPO_IOS_JOBS` (SwiftBuild `-j`, default nproc), `EXPO_IOS_BUNDLE_ID`,
`EXPO_IOS_CACHE` (default `~/.cache/expo-ios`).

Installed by `mobile/modules/expo-ios.sh` to `/opt/expo-ios`, with
`/usr/local/bin/expo-ios`. Runs as `user`. It never edits `package.json` or
your sources (only when `ios.bundleIdentifier` is unset does it write
`com.anonymous.<slug>`, or `EXPO_IOS_BUNDLE_ID`, into `app.json`, as
`expo prebuild`'s prompt would); it regenerates `ios/` with
`expo prebuild --no-install`, patches `node_modules` (below) and writes
everything else under `ios/build/`, `.expo/expo-ios/` and the per-user cache
`~/.cache/expo-ios/`.

## Pipeline (stages)

| stage | what |
|---|---|
| `patch` | `patches/`, then `overlays/`, then the built-in Linux fixups (below) on `node_modules` |
| `prebuild` | `expo prebuild --platform ios --no-install`, only when `ios/` is missing or app config / `package.json` / lockfile changed since expo-ios generated it (`--clean` forces it); an `ios/` expo-ios did not generate is used as is |
| `graph` | `setup-apple-spm.js scaffold` + `add --deintegrate --yes` (later `update`) with Expo's autolinking as `RCT_SPM_AUTOLINKING_CONFIG_COMMAND`; then the scaffolded-manifest fixes (below) |
| `jsi` | ExpoModulesJSI.framework from `expo-modules-jsi/apple/Package.swift`, cached per version in `~/.cache/expo-ios/jsi` |
| `modules` | Linux "et prebuild" of every autolinked module with an `spm.config.json` and no artifact (`@expo/ui`; Debug: `expo-dev-launcher`, `expo-dev-menu`, `expo-dev-menu-interface`, `expo-manifests`, `expo-updates-interface`, `expo-json-utils`) into `~/.cache/expo-ios/precompiled/expo-<v>-rn-<v>/<pkg>/output/{debug,release}/xcframeworks`, cached per package version, SDK, Swift version and expo-ios prebuild code; then `setup-apple-spm.js update` |
| `shell` | app shell package `ios/build/expo-ios/shell` (AppDelegate, SceneDelegate, ExpoModulesProvider; depends on the generated graph) |
| `compile` | `swift build --build-system swiftbuild --triple arm64-apple-ios<min> --toolset <bundle>/toolset-swb.json` (no `--swift-sdk`: it does not match a versioned triple), linked by the toolset's `ld64.lld` with `-ObjC`, `-lc++`, the flavored frameworks, `-rpath @executable_path/Frameworks`, `-platform_version ios <min> <sdk>` and, in Release, `-dead_strip`. Scratch: `~/.cache/expo-ios/scratch/<project hash>`; log `.expo/expo-ios/logs/compile-<flavor>.log` (streamed, `tail -f` works) |
| `js` | Release: `expo export:embed` + Linux `hermesc` → `main.jsbundle` (Hermes bytecode) + assets. Debug: skipped (dev client loads from Metro) |
| `constants` | `EXConstants.bundle/app.config` (`expo-constants/scripts/get-app-config-ios.sh`) |
| `resources` | `Images.xcassets` + `expo.icon` → `Assets.car` (omarchy actool), `SplashScreen.storyboard` → `SplashScreen.storyboardc` (omarchy ibtool), plain resources (`Expo.plist`) |
| `plist` | `Info.plist` expansion + partial plists; Release strips the dev client's Bonjour/local-network keys |
| `assemble` | `App.app`: executable (Release: `llvm-strip -x`, dSYM first), `Frameworks/` (React, ReactNativeDependencies, hermesvm, flavored Expo frameworks, ExpoModulesJSI, dynamic SwiftPM products, closed over `@rpath` deps), resource bundles, `PkgInfo`; build-host `LC_RPATH`s removed. Then the checks below |
| `package` | `App-unsigned.ipa` + omarchy `macho-lint` (unsigned: only missing signatures allowed) |

`assemble` fails the build unless: the executable is arm64 `MH_EXECUTE` with
`LC_BUILD_VERSION` platform iOS and `minos` = the deployment target; it links
`@rpath/{React,ReactNativeDependencies,hermesvm,ExpoModulesJSI,ExpoModulesCore}.framework`;
every `@rpath` dependency of every image is embedded; Release has a Hermes-bytecode
`main.jsbundle`; Info.plist passes `plist_tool.py check-app`; and the **link closure**
holds (`lib/closure.py`, report in `<out>/closure.json`): a dyld-style resolution over
every Mach-O image of the bundle — each `LC_LOAD_*`/`LC_REEXPORT_DYLIB` resolves (via
the image's and the executable's `LC_RPATH`s) to an embedded image or an iOS SDK `.tbd`;
each embedded image's install name is `@rpath/<path under Frameworks>`; each undefined
symbol is exported (export trie, or `.tbd` exports/re-exports followed transitively) by
the library its two-level-namespace ordinal names (any loaded image for flat lookups).
Symbols Apple moved between libraries are honoured the way ld64 links them: a
`$ld$previous$<old install name>$…$<start>$<end>$<symbol>$` entry in any SDK
`.tbd` makes `<symbol>` resolve against the old install name for images whose
`minos` is in `[start, end)` (Swift overlays merged into their frameworks, e.g.
`/usr/lib/swift/libswiftNetwork.dylib` → `Network.framework` for iOS < 17).
Unresolved weak imports are warnings (dyld binds them to NULL). Run it by hand with
`python3 /opt/expo-ios/lib/closure.py App.app --sdk $IPHONEOS_SDK [--json out.json]`.

Configuration → flavor: `Debug` uses the debug flavor of every prebuilt
framework, `-DDEBUG -DEXPO_CONFIGURATION_DEBUG`; `Release` uses release
flavors, `-DNDEBUG -DEXPO_CONFIGURATION_RELEASE`, and **excludes the dev-client
packages** from autolinking: `expo-dev-client`, `expo-dev-launcher`,
`expo-dev-menu`, `expo-dev-menu-interface` (plus anything in
`EXPO_IOS_EXCLUDE`, comma separated).

## Timings (8 vCPU / 16 GB orb VM)

Fresh `npx create-expo-app@latest` (expo 58.0.19, react-native 0.88.0), npm and
React Native artifact caches warm, as in the image:

| build | total | graph | modules | compile | js | assemble+package |
|---|---|---|---|---|---|---|
| Release, first build of the app (incl. `@expo/ui` Linux prebuild, 62 s) | 6 m 45 s | 56 s | 77 s | 227 s | 30 s | 9 s |
| Debug (`npx expo install expo-dev-client`), dev-client prebuilds cached | 3 m 45 s | 22 s | 22 s | 155 s | — | 21 s |
| `--only assemble,package` rerun | 16 s | | | | | |

Cold Linux prebuilds of the 7 Debug modules take 3–18 s each (`@expo/ui` up to
60 s); ExpoModulesJSI ~20 s once per version. The image's warm-up leaves all of
them in `~/.cache/expo-ios`. `App.app`: Release 48 MB (ipa 14 MB), Debug
144 MB (ipa 32 MB).

## Known limits

- arm64 iPhone only: no Simulator slice, no App Store/TestFlight builds.
- Nothing built this way has been launched on a device yet; only the static
  checks above (closure, macho-lint, Info.plist, Hermes bytecode) are proven.
- Expo's npm-shipped XCFrameworks (ExpoModulesCore & co., built by Xcode with
  Swift 6.3) are consumed through their `.swiftinterface` by swift.org Swift
  6.4.1; the Linux prebuilds (ExpoModulesJSI with `AssumeResilientCxxTypes`,
  `@expo/ui`, dev-client modules) are built with 6.4.1. Expo's plugin warns
  that mixing them "can crash the app at launch on a missing symbol"; the
  closure check rules out missing symbols, not layout differences.
- `ExpoModulesWorkletsAdapter` is left out (ExpoModulesCore is precompiled), as
  Expo's plugin warns.
- App-target Objective-C/C++ sources are not compiled (use a local Expo
  module); CocoaPods-only pods that mix Swift and Objective-C need a
  `Package.swift` or `spm.config.json` overlay.
- SwiftPM on Linux occasionally segfaults (`swift-package`, in libdispatch);
  the build stops with `exit null`: rerun, the work done is kept.

## Contract: overlays, patches, hooks

Everything here lives in this directory and is installed with the tool. Local
only: these are never upstreamed.

### `patches/`

- File name: `<npm name with "/" replaced by "+">+<exact version>.patch`,
  e.g. `patches/expo-dev-launcher+58.0.15.patch`,
  `patches/@expo+ui+58.0.23.patch`.
- Format: unified diff with paths relative to the **package root**, `a/` and
  `b/` prefixes (`diff -ru a b` or `git diff --relative` inside the package).
  Not patch-package's `a/node_modules/<pkg>/…` form.
- Applied as `patch -p1 -d <package dir>` where the package dir is resolved
  from the project root (`require.resolve('<pkg>/package.json')`, so hoisting
  and nested installs work).
- Idempotent: skipped when `patch -p1 --dry-run -R` applies cleanly; fails the
  build when neither the reverse nor the forward dry run applies.
- Only the patch whose version equals the installed version is applied. If a
  package that takes part in the build has patches but none for the installed
  version, the build fails naming the available versions. Packages excluded
  from the configuration (dev-client packages in Release) are skipped.
- Applied before overlays, against the pristine package.

### `overlays/`

- `overlays/<npm name>/…` (scoped: `overlays/@scope/name/…`) is copied file by
  file over the resolved package dir. Use it for new files: `Package.swift`,
  `spm.config.json`, module maps, header shims, extra sources.
- Optional `overlays/<npm name>/.expo-ios.json` (never copied):
  ```json
  { "versions": "~58.0.15", "configurations": ["Debug"] }
  ```
  `versions` is a semver range checked with the project's `semver`
  (mismatch → the build fails, so a stale overlay is never silently dropped);
  `configurations` defaults to both.
- Applied after patches. A package that is not installed is skipped.
- How a module overlay is built is decided by Expo's SwiftPM plugin rules:
  1. module has an `spm.config.json` → `expo-ios` prebuilds it on Linux (stage
     `modules`) and the plugin links it as a precompiled framework. All targets
     of a product are compiled and linked into one dynamic framework, so a
     Swift↔ObjC split across targets is fine. Resources: a target's `resources`
     (paths relative to the package root) become
     `<resourceBundleName | Product_Target>.bundle` inside the framework, asset
     catalogs compiled by omarchy's actool (SwiftBuild has no actool on Linux),
     other files copied (`process` flattens directories, `copy` keeps them).
     The generated `-Swift.h` loses self-imports of the product (and of its
     merged targets); the `.swiftinterface` names merged targets as the product
     and refers to `React::RCT…` types unqualified.
  2. else a checked-in `Package.swift` that depends on the
     `ExpoModulesCoreHeaders` product is built as it stands (link dir
     `direct/<pkg>`; `../ExpoModulesCoreHeaders`, or `../../` for scoped).
  3. else a checked-in `Package.swift` is mirrored into a generated package
     (expo-constants style: dependencies are injected, don't declare them).
  Don't ship both an `spm.config.json` and a `Package.swift` for one module:
  rule 1 wins.

### `hooks/`

Executable files `hooks/<stage>.d/<NN-name>` run (sorted) after that stage
(`graph`, `modules`, `compile`, `assemble`). Hooks must be idempotent and exit
non-zero on failure. Environment:

| variable | value |
|---|---|
| `EXPO_IOS_CONFIGURATION` | `Debug` or `Release` |
| `EXPO_IOS_FLAVOR` | `debug` or `release` |
| `PROJECT_ROOT` | Expo project root |
| `IOS_DIR` | `$PROJECT_ROOT/ios` |
| `BUILD_DIR` | `$PROJECT_ROOT/ios/build/expo-ios/<Configuration>` |
| `SHELL_PACKAGE` | the app shell SwiftPM package |
| `PRODUCTS_DIR` | SwiftBuild products dir of the shell build (after `compile`) |
| `APP_BUNDLE` | the `.app` being assembled (after `assemble`, before `package`) |
| `DARWIN_SDK_BUNDLE`, `IPHONEOS_SDK`, `MIN_IOS` | toolchain |
| `EXPO_PRECOMPILED_MODULES_PATH` | Linux prebuild output root |

A hook that only applies to one configuration checks
`EXPO_IOS_CONFIGURATION` itself.

## Built-in Linux fixups

Applied in stage `patch` to the installed `node_modules`, version tolerant:
each one locates its anchor text and fails the build if neither the original
nor the already-fixed text is found (so an Expo upgrade that moves the code is
noticed, not silently skipped).

1. `expo-modules-autolinking` `build/platforms/apple/apple.js`: the Swift
   module scanner runs on Linux too (`@expo/modules-macros-linux-x64` ships
   the scanner); upstream returns early unless `darwin`.
2. Expo's Swift macro plugin: `expo-modules-macros/apple/ExpoModulesMacros`
   is a macOS binary; it is replaced by a symlink to
   `@expo/modules-macros-linux-x64/ExpoModulesMacros` (the original is kept as
   `ExpoModulesMacros.macos`).
3. `react-native-reanimated` / `react-native-worklets` `Package.swift`:
   `CFGetTypeID`/`CFBooleanGetTypeID` (absent from Linux Foundation) →
   `String(cString: n.objCType) == "c"`.
4. Scaffolded `Package.swift` of `react-native-gesture-handler` and
   `@react-native-masked-view/masked-view` (and any scaffolded package hitting
   *invalid header layout*): a `module.modulemap` in the public headers dir.
5. `expo-modules-autolinking` options: `EXPO_IOS_AUTOLINKING_EXCLUDE`
   (comma separated) is appended to `expo.autolinking.exclude`, so the Release
   graph drops dev-client packages without editing `package.json`.

Scaffolded-manifest fixes (stage `graph`, `lib/graph.mjs`; React Native's
`spm scaffold` turns a podspec into `Package.swift` but drops parts of it):

6. `header_dir` subspecs (RNScreens `common` → `<rnscreens/…>`): headers staged
   under `<pkg>/.expo-ios-headers/<header_dir>/` on the target's search path.
7. `pod_target_xcconfig` `GCC_PREPROCESSOR_DEFINITIONS` / `OTHER_CFLAGS` /
   `OTHER_CPLUSPLUSFLAGS` (read with RN's `pod ipc spec` reader, so env
   conditions like `RNS_GAMMA_ENABLED` apply) → `unsafeFlags`.
8. CocoaPods-style public headers: when the umbrella-directory module of
   `publicHeadersPath` would differ from CocoaPods' (headers the podspec's
   `exclude_files` drop, e.g. RNScreens' `ios/stubs/RNSGammaStubs.h` with
   `RNS_GAMMA_ENABLED=1`; or public headers that `#import "X.h"` from a sibling
   directory), the target publishes `<pkg>/.expo-ios-public/`: symlinks to the
   headers the scaffolded `sources` keep, flattened, plus the `header_dir` trees
   (excluded from the module) and a `module.modulemap`. Generic: driven by the
   scaffolded `sources` list, which already honours `exclude_files`.
9. Podspec dependencies of generated Expo packages on autolinked libraries
   (`expo-router` → `RNScreens`): package + product added, with the library's
   podspec defines.

## Environment it relies on (set by the image)

`MOBILE_SHIMS_BIN` (plutil/xcodebuild/xcrun/otool/command shims, prepended to
`PATH` only inside `expo-ios`), `DARWIN_SDK_BUNDLE`, `OMARCHY_APPLE_DEV`,
`swift`, `pod`, `llvm-otool`, `rcodesign`, `pymobiledevice3`. `expo-ios` sets
`TAR_OPTIONS=--wildcards`, `LANG=C.UTF-8`, `RNS_GAMMA_ENABLED=1` itself.

## Signing and install

`expo-ios sign` signs `App.app` into `App.ipa` with an iOS Development profile:

- When `ASC_KEY_ID`, `ASC_ISSUER_ID` and `ASC_KEY_PATH` are set in the orb, it signs
  locally with omarchy's `tools/provision-dev.py` (App Store Connect API; device
  `EXPO_IOS_DEVICE_UDID`, else every enabled device of the team), which runs when the
  profile for the bundle id is missing, and then `tools/sign-dev.sh`.
- Otherwise it runs `iphone sign`. The srv host's iphone-broker signs with the team key,
  which stays on the host, for the shared iPhone. Bundle ids must use the broker's prefix
  (`APPLE_BUNDLE_PREFIX` in site.env, exported in the orb as `$IPHONE_BUNDLE_PREFIX`).

`expo-ios install [--launch N]` runs `iphone install App.ipa`, then
`iphone launch <bundle id> --console N`. Both go through the broker, which holds the
leased iPhone on the host's USB. See the `iphone` skill and `srv-mobile-host/README.md`.
Without what they need, both commands stop and say exactly what is missing.
