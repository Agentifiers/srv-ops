// Build context: project layout, configuration, toolchain discovery.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fail, readJSON, resolvePackageDir, run, exists } from './util.mjs';

export const HERE = path.resolve(path.dirname(new URL(import.meta.url).pathname), '..');

// Packages that only exist for the dev client. Release builds leave them out of
// autolinking, as CocoaPods does with `:configurations => ['Debug']`.
export const DEV_CLIENT_PACKAGES = [
  'expo-dev-client',
  'expo-dev-launcher',
  'expo-dev-menu',
  'expo-dev-menu-interface',
];

export function createContext({ projectRoot, configuration, out }) {
  projectRoot = path.resolve(projectRoot);
  if (!exists(path.join(projectRoot, 'package.json'))) fail(`${projectRoot} has no package.json; run expo-ios inside an Expo project`);
  if (!resolvePackageDir(projectRoot, 'expo')) fail(`expo is not installed in ${projectRoot}; run npm install first`);
  if (!['Debug', 'Release'].includes(configuration)) fail(`--configuration must be Debug or Release, not ${configuration}`);
  const flavor = configuration === 'Debug' ? 'debug' : 'release';
  const iosDir = path.join(projectRoot, 'ios');
  const workRoot = path.join(iosDir, 'build', 'expo-ios');
  const cacheRoot = process.env.EXPO_IOS_CACHE ?? path.join(process.env.XDG_CACHE_HOME ?? path.join(os.homedir(), '.cache'), 'expo-ios');
  const ctx = {
    projectRoot,
    configuration,
    flavor,
    iosDir,
    workRoot,
    outDir: out ? path.resolve(out) : path.join(workRoot, configuration),
    shellDir: path.join(workRoot, 'shell'),
    // SwiftPM scratch (build products) lives outside ios/ so `expo prebuild --clean`
    // does not throw away the incremental build.
    scratchDir: path.join(cacheRoot, 'scratch', hashPath(projectRoot)),
    cacheRoot,
    // Logs and the prebuild marker live outside ios/, which `expo prebuild --clean` deletes
    // while a stage is logging (.expo/ is gitignored by Expo's templates).
    stateDir: path.join(projectRoot, '.expo', 'expo-ios'),
    logDir: path.join(projectRoot, '.expo', 'expo-ios', 'logs'),
    timings: [],
    rn: resolvePackageDir(projectRoot, 'react-native'),
    expo: resolvePackageDir(projectRoot, 'expo'),
  };
  ctx.rnVersion = readJSON(path.join(ctx.rn, 'package.json')).version;
  ctx.expoVersion = readJSON(path.join(ctx.expo, 'package.json')).version;
  ctx.exclude = [
    ...(configuration === 'Release' ? DEV_CLIENT_PACKAGES : []),
    ...(process.env.EXPO_IOS_EXCLUDE ?? '').split(',').map((s) => s.trim()).filter(Boolean),
  ];
  ctx.tools = discoverTools(ctx);
  ctx.env = buildEnv(ctx);
  return ctx;
}

function hashPath(p) {
  let h = 0;
  for (const c of p) h = (h * 31 + c.charCodeAt(0)) >>> 0;
  return `${path.basename(p)}-${h.toString(16)}`;
}

function which(name, extraDirs = []) {
  for (const dir of [...extraDirs, ...(process.env.PATH ?? '').split(':')]) {
    const p = path.join(dir, name);
    try {
      fs.accessSync(p, fs.constants.X_OK);
      return p;
    } catch {}
  }
  return null;
}

function discoverTools(ctx) {
  const shims = process.env.MOBILE_SHIMS_BIN ?? '/opt/mobile-shims/bin';
  const omarchy = process.env.OMARCHY_APPLE_DEV ?? '/opt/omarchy-apple-dev';
  let sdkBundle = process.env.DARWIN_SDK_BUNDLE;
  if (!sdkBundle) {
    for (const c of [
      '/opt/swift-sdks/darwin.artifactbundle',
      path.join(os.homedir(), '.swiftpm/swift-sdks/darwin.artifactbundle'),
      path.join(os.homedir(), '.config/swiftpm/swift-sdks/darwin.artifactbundle'),
    ]) {
      if (exists(c)) {
        sdkBundle = c;
        break;
      }
    }
  }
  const platformDir = sdkBundle ? path.join(sdkBundle, 'Developer/Platforms/iPhoneOS.platform') : null;
  const hermesPkg = resolvePackageDir(ctx.rn, 'hermes-compiler') ?? resolvePackageDir(ctx.projectRoot, 'hermes-compiler');
  return {
    shims,
    omarchy,
    sdkBundle,
    iphoneosSdk: platformDir ? path.join(platformDir, 'Developer/SDKs/iPhoneOS.sdk') : null,
    platformBin: platformDir ? path.join(platformDir, 'Developer/usr/bin') : null,
    toolset: sdkBundle ? path.join(sdkBundle, 'toolset-swb.json') : null,
    // Swift SDK id of the bundle (`swift sdk list`); ios-sdk.sh validates with this one.
    swiftSdk: process.env.EXPO_IOS_SWIFT_SDK ?? 'arm64-apple-ios',
    // ios-sdk.sh keeps the Xcode version.plist beside the bundle (DTXcode/DTXcodeBuild).
    xcodeVersionPlist: sdkBundle ? path.join(path.dirname(sdkBundle), 'Xcode.version.plist') : null,
    swift: which('swift'),
    node: process.execPath,
    actool:
      [
        platformDir && path.join(platformDir, 'Developer/usr/bin/actool'),
        path.join(omarchy, 'tools/darwin-tools/bin/actool'),
        path.join(omarchy, 'tools/darwin-tools/.build/release/actool'),
      ].find((p) => p && exists(p)) ?? null,
    ibtool: [path.join(omarchy, 'tools/ibtool'), platformDir && path.join(platformDir, 'Developer/usr/bin/ibtool')].find((p) => p && exists(p)) ?? null,
    hermesc: hermesPkg ? path.join(hermesPkg, 'hermesc/linux64-bin/hermesc') : null,
    otool: which('llvm-otool'),
    python: which('python3'),
  };
}

/**
 * The cross-compile part of every `swift build`: the triple selects the Darwin SDK bundle
 * (`--swift-sdk` does not match a versioned triple), SwiftBuild with the bundle's toolset.
 * Clang targets get no runtime autolinking from SwiftBuild on Linux, so libobjc and
 * Foundation are linked explicitly.
 */
export function swiftTargetArgs(ctx, minIOS) {
  const t = ctx.tools;
  // <swift/bridging> (C++ interop annotations, ExpoModulesJSI) lives in the Swift
  // toolchain, which Xcode puts on the include path and SwiftBuild on Linux does not.
  const inc = path.join(path.dirname(path.dirname(fs.realpathSync(t.swift))), 'include');
  return [
    '--build-system', 'swiftbuild',
    '--triple', `arm64-apple-ios${minIOS}`,
    '--toolset', t.toolset,
    '-Xcc', `-I${inc}`, '-Xcxx', `-I${inc}`, '-Xswiftc', '-Xcc', '-Xswiftc', `-I${inc}`,
    '-Xlinker', '-lobjc', '-Xlinker', '-framework', '-Xlinker', 'Foundation',
  ];
}

function buildEnv(ctx) {
  const env = { ...process.env };
  const t = ctx.tools;
  // Shims for macOS-only tools (plutil, xcodebuild -version, xcrun clang, command, otool)
  // come first, only inside expo-ios; then the SDK bundle's toolset (ld64.lld, dsymutil),
  // as xtool and swift-build-ios run SwiftBuild.
  env.PATH = [t.shims, t.sdkBundle && path.join(t.sdkBundle, 'toolset/bin'), path.dirname(t.node), env.PATH].filter(Boolean).join(':');
  // precompiled_modules.rb and RN's artifact staging use bsdtar-style member globs.
  env.TAR_OPTIONS = '--wildcards';
  env.LANG = env.LANG && /UTF-?8/i.test(env.LANG) ? env.LANG : 'C.UTF-8';
  env.LC_ALL = env.LC_ALL && /UTF-?8/i.test(env.LC_ALL) ? env.LC_ALL : 'C.UTF-8';
  // Matches the Podfile prebuild writes (react-native-screens' new implementation).
  env.RNS_GAMMA_ENABLED = env.RNS_GAMMA_ENABLED ?? '1';
  env.RCT_SPM_AUTOLINKING_CONFIG_COMMAND = JSON.stringify([
    'node',
    '--no-warnings',
    '--eval',
    'require("expo/bin/autolinking")',
    'expo-modules-autolinking',
    'react-native-config',
    '--json',
    '--platform',
    'ios',
  ]);
  env.EXPO_IOS_AUTOLINKING_EXCLUDE = ctx.exclude.join(',');
  env.NODE_BINARY = t.node;
  // SwiftBuild resolves platforms from here (omarchy flutter/build.sh does the same).
  if (t.sdkBundle) env.XCODE_EXTRA_PLATFORM_FOLDERS = path.join(t.sdkBundle, 'Developer/Platforms');
  delete env.SDKROOT;
  return env;
}

/** Fail unless the Darwin SDK and Swift toolchain needed to compile are present. */
export function requireSdk(ctx) {
  const t = ctx.tools;
  const missing = [];
  if (!t.swift) missing.push('swift (Swift 6.4 toolchain)');
  if (!t.sdkBundle || !exists(t.iphoneosSdk)) missing.push(`Darwin SDK bundle (DARWIN_SDK_BUNDLE; looked for ${t.iphoneosSdk ?? '/opt/swift-sdks/darwin.artifactbundle'})`);
  if (!t.toolset || !exists(t.toolset)) missing.push(`SwiftBuild toolset ${t.toolset}`);
  if (missing.length) fail(`cannot compile: missing ${missing.join(', ')}. The image's ios-sdk module installs the SDK from Xcode's .xip.`);
  if (!ctx.sdkVersion) {
    ctx.sdkVersion = readJSON(path.join(t.iphoneosSdk, 'SDKSettings.json')).Version;
  }
  return t;
}

/**
 * App target build settings for this configuration from the generated pbxproj:
 * the first XCBuildConfiguration named `configuration` that sets PRODUCT_BUNDLE_IDENTIFIER.
 */
export function readAppSettings(ctx) {
  const projects = fs.readdirSync(ctx.iosDir).filter((f) => f.endsWith('.xcodeproj'));
  if (projects.length !== 1) fail(`expected one .xcodeproj in ${ctx.iosDir}, found ${projects.length}`);
  const pbx = fs.readFileSync(path.join(ctx.iosDir, projects[0], 'project.pbxproj'), 'utf8');
  const blocks = [...pbx.matchAll(/isa = XCBuildConfiguration;\s*buildSettings = \{([\s\S]*?)\n\t\t\t\};\s*name = ("?)([^";]+)\2;/g)];
  const block = blocks.find((m) => m[3] === ctx.configuration && /PRODUCT_BUNDLE_IDENTIFIER/.test(m[1]));
  if (!block) fail(`no ${ctx.configuration} app build configuration in ${projects[0]}`);
  const settings = {};
  for (const m of block[1].matchAll(/^\s*("?)([A-Za-z0-9_]+)\1 = ("?)((?:[^"\\;]|\\.)*)\3;/gm)) {
    settings[m[2]] = m[4].replace(/\\"/g, '"');
  }
  const target = projects[0].replace(/\.xcodeproj$/, '');
  const infoPlist = path.join(ctx.iosDir, settings.INFOPLIST_FILE ?? `${target}/Info.plist`);
  const productName = (settings.PRODUCT_NAME ?? target).replace('$(TARGET_NAME)', target);
  return {
    target,
    productName,
    executableName: productName,
    // Xcode's PRODUCT_MODULE_NAME: the Swift module of the app's own sources.
    moduleName: productName.replace(/[^A-Za-z0-9_]/g, '_').replace(/^(\d)/, '_$1'),
    bundleId: settings.PRODUCT_BUNDLE_IDENTIFIER,
    minIOS: settings.IPHONEOS_DEPLOYMENT_TARGET ?? '16.4',
    marketingVersion: settings.MARKETING_VERSION ?? '1.0',
    buildNumber: settings.CURRENT_PROJECT_VERSION ?? '1',
    deviceFamily: settings.TARGETED_DEVICE_FAMILY ?? '1',
    appIconName: settings.ASSETCATALOG_COMPILER_APPICON_NAME ?? 'AppIcon',
    entitlements: settings.CODE_SIGN_ENTITLEMENTS ? path.join(ctx.iosDir, settings.CODE_SIGN_ENTITLEMENTS) : null,
    bridgingHeader: settings.SWIFT_OBJC_BRIDGING_HEADER ? path.join(ctx.iosDir, settings.SWIFT_OBJC_BRIDGING_HEADER) : null,
    infoPlist,
    sourceDir: path.dirname(infoPlist),
    settings,
  };
}

export function toolVersion(cmd, args, env) {
  const r = run(cmd, args, { capture: true, allowFail: true, env });
  return r.status === 0 ? `${r.stdout}${r.stderr}`.trim().split('\n')[0] : null;
}
