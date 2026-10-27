// Stage `jsi`: ExpoModulesJSI.framework, which npm ships headers-only. Mirrors
// expo-modules-jsi/apple/scripts/build-swiftpm-app-phase.sh + build-xcframework.sh,
// with `swift build --build-system swiftbuild` in place of xcodebuild.
import fs from 'node:fs';
import path from 'node:path';
import { generatedPaths } from './graph.mjs';
import { requireSdk, swiftTargetArgs, HERE } from './context.mjs';
import { jsiFrameworkDir } from './shell.mjs';
import { copyTree, exists, fail, info, mkdirp, readJSON, resolvePackageDir, rmrf, run, sha256, walk } from './util.mjs';

export function findBuiltFramework(scratch, configuration, name) {
  const products = path.join(scratch, 'out', 'Products', `${configuration}-iphoneos`);
  for (const c of [path.join(products, 'PackageFrameworks', `${name}.framework`), path.join(products, `${name}.framework`)]) {
    if (exists(path.join(c, name))) return { framework: c, products };
  }
  const dylib = path.join(products, `lib${name}.dylib`);
  if (exists(dylib)) return { dylib, products };
  return { products };
}

export function stageJsi(ctx, app) {
  const t = requireSdk(ctx);
  const jsiPkg = resolvePackageDir(resolvePackageDir(ctx.projectRoot, 'expo-modules-core') ?? ctx.projectRoot, 'expo-modules-jsi') ?? resolvePackageDir(ctx.projectRoot, 'expo-modules-jsi');
  if (!jsiPkg) fail('expo-modules-jsi is not installed');
  const version = readJSON(path.join(jsiPkg, 'package.json')).version;
  const key = sha256(JSON.stringify([version, ctx.rnVersion, ctx.sdkVersion, app.minIOS, fs.readFileSync(path.join(HERE, 'lib/jsi.mjs'), 'utf8')])).slice(0, 16);
  const cacheDir = path.join(ctx.cacheRoot, 'jsi', `${version}-${key}`);
  const cached = path.join(cacheDir, 'ExpoModulesJSI.framework');
  const dest = jsiFrameworkDir(ctx);
  if (!exists(path.join(cached, 'ExpoModulesJSI'))) buildJsi(ctx, t, jsiPkg, app, cacheDir);
  rmrf(dest);
  mkdirp(dest);
  copyTree(cached, path.join(dest, 'ExpoModulesJSI.framework'));
  info(`ExpoModulesJSI.framework ${version} (${cacheDir})`);
  return path.join(dest, 'ExpoModulesJSI.framework');
}

function buildJsi(ctx, t, jsiPkg, app, cacheDir) {
  const g = generatedPaths(ctx);
  const work = path.join(ctx.cacheRoot, 'jsi-work', path.basename(cacheDir));
  const stage = path.join(work, 'pods-stage');
  const pub = path.join(stage, 'Headers/Public');
  const slice = 'ios-arm64';
  const reactHeaders = path.join(g.xcframeworksPkg, 'ReactNativeHeaders.xcframework', slice, 'Headers');
  const depHeaders = path.join(g.xcframeworksPkg, 'ReactNativeDependenciesHeaders.xcframework', slice, 'Headers');
  for (const req of [path.join(reactHeaders, 'hermes/hermes.h'), path.join(depHeaders, 'folly')]) {
    if (!exists(req)) fail(`ExpoModulesJSI: ${req} missing (React Native SwiftPM artifacts; run the graph stage)`);
  }
  rmrf(stage);
  const link = (target, rel) => {
    mkdirp(path.dirname(path.join(pub, rel)));
    fs.symlinkSync(target, path.join(pub, rel));
  };
  const rn = ctx.rn;
  link(`${rn}/ReactCommon/jsi/jsi`, 'React-jsi/jsi');
  link(`${rn}/ReactCommon/react/renderer/runtimescheduler`, 'React-runtimescheduler/react/renderer/runtimescheduler');
  link(`${rn}/ReactCommon/react/renderer/consistency`, 'React-rendererconsistency/react/renderer/consistency');
  link(`${rn}/ReactCommon/react/performance/timeline`, 'React-performancetimeline/react/performance/timeline');
  link(`${rn}/ReactCommon/react/timing`, 'React-timing/react/timing');
  link(`${rn}/ReactCommon/react/debug`, 'React-debug/react/debug');
  link(`${rn}/ReactCommon/callinvoker/ReactCommon`, 'React-callinvoker/ReactCommon');
  link(`${rn}/ReactCommon/runtimeexecutor/ReactCommon`, 'React-runtimeexecutor/ReactCommon');
  link(path.join(reactHeaders, 'hermes'), 'hermes-engine/hermes');
  link(depHeaders, 'ReactNativeDependencies');

  const buildRoot = path.join(work, 'custom-build');
  mkdirp(buildRoot);
  // A copy of the package, so SwiftPM state and generated files stay out of node_modules.
  const pkg = path.join(work, 'pkg');
  rmrf(pkg);
  mkdirp(pkg);
  for (const ent of fs.readdirSync(path.join(jsiPkg, 'apple'))) copyTree(path.join(jsiPkg, 'apple', ent), path.join(pkg, ent));
  const env = { ...ctx.env, PODS_ROOT: stage, RN_ROOT: rn, REACT_NATIVE_PATH: rn, EXPO_CUSTOM_BUILD_ROOT: buildRoot };
  run('bash', [path.join(pkg, 'scripts/generate-modulemap.sh')], { env, log: path.join(ctx.logDir, 'jsi.log') });

  const scratch = path.join(work, 'scratch');
  const unexported = path.join(pkg, 'scripts/unexported-swift-runtime-symbols.txt');
  run(
    t.swift,
    [
      'build',
      '--package-path', pkg,
      '--scratch-path', scratch,
      '--configuration', 'release',
      ...swiftTargetArgs(ctx, app.minIOS),
      '--product', 'ExpoModulesJSI',
      '-Xswiftc', '-wmo',
      // swift.org 6.4 rejects C++ types in library-evolution extensions (JavaScriptError.swift:
      // `extension expo.CppError: Error`); Xcode's Swift builds it. This feature lifts the check.
      '-Xswiftc', '-enable-experimental-feature', '-Xswiftc', 'AssumeResilientCxxTypes',
      '-Xlinker', '-unexported_symbols_list', '-Xlinker', unexported,
      '-Xlinker', '-platform_version', '-Xlinker', 'ios', '-Xlinker', app.minIOS, '-Xlinker', ctx.sdkVersion,
    ],
    { cwd: pkg, env, log: path.join(ctx.logDir, 'jsi.log') }
  );
  const built = findBuiltFramework(scratch, 'Release', 'ExpoModulesJSI');
  rmrf(cacheDir);
  mkdirp(cacheDir);
  const fw = path.join(cacheDir, 'ExpoModulesJSI.framework');
  if (built.framework) {
    copyTree(built.framework, fw);
  } else if (built.dylib) {
    // A plain dylib product: wrap it the way Xcode lays out an iOS framework.
    mkdirp(fw);
    fs.copyFileSync(built.dylib, path.join(fw, 'ExpoModulesJSI'));
    run('llvm-install-name-tool', ['-id', '@rpath/ExpoModulesJSI.framework/ExpoModulesJSI', path.join(fw, 'ExpoModulesJSI')]);
    run('python3', [path.join(HERE, 'lib/plist_tool.py'), 'framework-info', path.join(fw, 'Info.plist'), 'ExpoModulesJSI', 'expo.modules.ExpoModulesJSI', app.minIOS]);
  } else {
    fail(`swift build produced no ExpoModulesJSI framework or dylib under ${built.products}: ${walk(built.products).slice(0, 30).join(', ')}`);
  }
  const id = run('llvm-otool', ['-D', path.join(fw, 'ExpoModulesJSI')], { capture: true }).stdout;
  if (!id.includes('@rpath/ExpoModulesJSI.framework/ExpoModulesJSI')) fail(`ExpoModulesJSI install name is not @rpath/ExpoModulesJSI.framework/ExpoModulesJSI:\n${id}`);
}
