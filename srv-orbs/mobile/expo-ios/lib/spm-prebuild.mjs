// Stage `modules`: Linux "et prebuild". Expo's own pipeline (expo/tools/src/prebuilds:
// SPMPackage.ts renders a Package.swift from spm.config.json, SPMBuild.ts runs
// xcodebuild) rebuilt on `swift build --build-system swiftbuild`. Output follows the
// layout Expo's SwiftPM plugin looks up first:
//   $EXPO_PRECOMPILED_MODULES_PATH/<package>/output/<flavor>/xcframeworks/<Product>.xcframework
import fs from 'node:fs';
import path from 'node:path';
import { generatedPaths, resolveExpoModules } from './graph.mjs';
import { HERE, requireSdk, swiftTargetArgs } from './context.mjs';
import { flavoredFrameworks, jsiFrameworkDir } from './shell.mjs';
import { findBuiltFramework } from './jsi.mjs';
import { localChangesDigest } from './patching.mjs';
import {
  copyTree, exists, fail, globToRegExp, info, mkdirp, readJSON, resolvePackageDir, rmrf, run, sha256, walk, warn, writeIfChanged,
} from './util.mjs';

const FLAVORS = ['debug', 'release'];

export function precompiledRoot(ctx) {
  // One tree per Expo SDK / React Native / toolchain: artifacts are bound to the
  // ExpoModulesCore and React they were compiled against.
  return path.join(ctx.cacheRoot, 'precompiled', `expo-${ctx.expoVersion}-rn-${ctx.rnVersion}`);
}

function bundledArtifact(dir, flavor, product) {
  const base = path.join(dir, 'prebuilds', 'output', flavor, 'xcframeworks');
  return exists(path.join(base, `${product}.xcframework`)) || exists(path.join(base, `${product}.tar.gz`));
}

function envArtifactDir(ctx, pkg, flavor) {
  return path.join(precompiledRoot(ctx), pkg, 'output', flavor, 'xcframeworks');
}

/**
 * Autolinked modules the SwiftPM plugin can only take precompiled: an spm.config.json
 * product with Objective-C/C++ targets, no artifact in npm and no checked-in Package.swift,
 * plus every spm.config.json module those depend on (a prebuilt framework can only link
 * frameworks). Pure-Swift products otherwise get a generated source package from the
 * plugin; ExpoModulesJSI is the `jsi` stage. Returns [{ packageName, dir, version, config,
 * products }] in dependency order.
 */
export function modulesNeedingPrebuild(ctx) {
  const candidates = new Map();
  for (const m of resolveExpoModules(ctx)) {
    if (m.packageName === 'expo-modules-jsi') continue;
    const dir = m.path ?? resolvePackageDir(ctx.projectRoot, m.packageName);
    const cfgFile = path.join(dir, 'spm.config.json');
    if (!exists(cfgFile) || exists(path.join(dir, 'Package.swift'))) continue;
    let config;
    try {
      config = readJSON(cfgFile);
    } catch (e) {
      fail(`${cfgFile}: ${e.message}`);
    }
    const products = (config.products ?? []).filter(
      (p) => !p.sourceOnly && !(p.autolinkWhen && !autolinkWhenMet(ctx, p.autolinkWhen)) && !FLAVORS.every((f) => bundledArtifact(dir, f, p.name))
    );
    if (products.length === 0) continue;
    candidates.set(m.packageName, { packageName: m.packageName, dir, version: readJSON(path.join(dir, 'package.json')).version, config, products });
  }
  const selected = new Map();
  const add = (mod) => {
    if (selected.has(mod.packageName)) return;
    selected.set(mod.packageName, mod);
    for (const p of mod.products) {
      for (const d of p.externalDependencies ?? []) {
        const ext = externalPackageOf(d);
        if (ext && candidates.has(ext.pkg)) add(candidates.get(ext.pkg));
      }
    }
  };
  // Expo's plugin classifies a module by the files on disk, not by its spm.config.json:
  // expo-updates-interface declares one Swift target but ships a .m file, so the plugin
  // refuses it as source and wants an artifact.
  const hasNativeSources = (dir) =>
    ['ios', 'apple'].some((sub) => walk(path.join(dir, sub)).some((f) => /\.(m|mm|c|cc|cpp)$/.test(f) && !/^Tests\//.test(f)));
  for (const mod of candidates.values()) {
    if (mod.products.some((p) => (p.targets ?? []).some((tg) => tg.type !== 'swift')) || hasNativeSources(mod.dir)) add(mod);
  }
  return orderByDependencies([...selected.values()]);
}

function autolinkWhenMet(ctx, cond) {
  if (cond.npmPackage) return !!resolvePackageDir(ctx.projectRoot, cond.npmPackage) && !ctx.exclude.includes(cond.npmPackage);
  // podName / podfileProperty conditions: treat as met only when the pod's package exists.
  return false;
}

function externalPackageOf(dep) {
  const i = dep.lastIndexOf('/');
  return i > 0 ? { pkg: dep.slice(0, i), product: dep.slice(i + 1) } : null;
}

function orderByDependencies(mods) {
  const byName = new Map(mods.map((m) => [m.packageName, m]));
  const order = [];
  const state = new Map();
  const visit = (m, trail) => {
    if (state.get(m.packageName) === 'done') return;
    if (state.get(m.packageName) === 'visiting') fail(`spm.config.json dependency cycle: ${[...trail, m.packageName].join(' → ')}`);
    state.set(m.packageName, 'visiting');
    for (const p of m.products) {
      for (const d of p.externalDependencies ?? []) {
        const ext = externalPackageOf(d);
        if (ext && byName.has(ext.pkg) && ext.pkg !== m.packageName) visit(byName.get(ext.pkg), [...trail, m.packageName]);
      }
    }
    state.set(m.packageName, 'done');
    order.push(m);
  };
  for (const m of mods) visit(m, []);
  return order;
}

function cacheStamp(ctx, mod) {
  return sha256(
    JSON.stringify([
      mod.version,
      mod.config,
      localChangesDigest(mod.packageName),
      ctx.sdkVersion,
      ctx.toolsVersion,
      fs.readFileSync(path.join(HERE, 'lib/spm-prebuild.mjs'), 'utf8'),
    ])
  );
}

/** Build every missing artifact for this configuration's flavor. Returns names built or reused. */
export function stageModules(ctx, app, mods) {
  if (mods.length === 0) return [];
  const t = requireSdk(ctx);
  ctx.toolsVersion ??= run(t.swift, ['--version'], { capture: true, env: ctx.env }).stdout.trim();
  const built = [];
  for (const mod of mods) {
    const stamp = cacheStamp(ctx, mod);
    const stampFile = path.join(precompiledRoot(ctx), mod.packageName, 'output', `.expo-ios-${ctx.flavor}`);
    const outDir = envArtifactDir(ctx, mod.packageName, ctx.flavor);
    const have = exists(stampFile) && fs.readFileSync(stampFile, 'utf8') === stamp && mod.products.every((p) => exists(path.join(outDir, `${p.name}.xcframework`)));
    if (have) {
      info(`${mod.packageName}@${mod.version}: cached ${ctx.flavor} prebuild`);
    } else {
      const start = Date.now();
      rmrf(outDir);
      mkdirp(outDir);
      for (const product of mod.products) buildProduct(ctx, app, t, mod, product, outDir);
      fs.writeFileSync(stampFile, stamp);
      info(`${mod.packageName}@${mod.version}: built ${ctx.flavor} (${((Date.now() - start) / 1000).toFixed(0)}s)`);
    }
    // Expo's plugin wants a Debug+Release pair. A one-configuration build fills the other
    // slot with the same framework until that configuration is built for real.
    const other = ctx.flavor === 'debug' ? 'release' : 'debug';
    const otherDir = envArtifactDir(ctx, mod.packageName, other);
    const otherStamp = path.join(precompiledRoot(ctx), mod.packageName, 'output', `.expo-ios-${other}`);
    if (!exists(otherStamp) || fs.readFileSync(otherStamp, 'utf8') !== stamp) {
      rmrf(otherDir);
      mkdirp(otherDir);
      for (const p of mod.products) copyTree(path.join(outDir, `${p.name}.xcframework`), path.join(otherDir, `${p.name}.xcframework`));
      fs.writeFileSync(otherStamp, `placeholder:${ctx.flavor}`);
    }
    built.push(mod.packageName);
  }
  return built;
}

function swiftStr(s) {
  return JSON.stringify(s);
}

function platformsOf(product) {
  return (product.platforms ?? ['iOS("16.4")']).filter((p) => /^iOS\(/.test(p)).map((p) => `.${p}`);
}

/** Files of one target, relative to the package dir. */
function targetFiles(mod, target) {
  const root = path.join(mod.dir, target.path ?? '.');
  const src = globToRegExp(target.pattern ?? '**/*');
  const hdr = target.headerPattern ? globToRegExp(target.headerPattern) : null;
  const excl = (target.exclude ?? []).map(globToRegExp);
  const sources = [];
  const headers = [];
  for (const rel of walk(root, { followSymlinks: true })) {
    if (excl.some((r) => r.test(rel))) continue;
    if (src.test(rel)) sources.push(rel);
    else if (hdr && hdr.test(rel)) headers.push(rel);
  }
  return { root, sources, headers };
}

function substitute(flag, mod) {
  return flag.replace(/\$\{PACKAGE_VERSION\}/g, mod.version);
}

/** Render a SwiftPM package for one spm.config.json product and build it into an xcframework. */
function buildProduct(ctx, app, t, mod, product, outDir) {
  const g = generatedPaths(ctx);
  const work = path.join(ctx.cacheRoot, 'prebuild-work', mod.packageName.replace('/', '+'), product.name);
  // The directory name is the package identity and Swift's -package-name: one shared name
  // ("pkg") makes every earlier prebuild look like a module of the same package, which
  // Swift refuses to load from a non-package interface (expo-dev-menu → EXDevMenuInterface).
  const pkg = path.join(work, `${product.name}Prebuild`);
  rmrf(path.join(pkg, 'Sources'));
  mkdirp(pkg);
  // The modules stage may be rebuilding a framework the graph already links (stale cache
  // stamp): its plugin symlink dangles meanwhile. Dependencies on it fail below by name.
  const frameworks = flavoredFrameworks(ctx, { skipMissing: true });
  const fwByName = new Map(frameworks.map((f) => [f.name, f]));
  const linkF = new Set();
  const linkFrameworks = new Set();
  const usesJsi = { value: false };
  const spmPackages = product.spmPackages ?? [];
  const spmProductPkg = new Map(spmPackages.map((p) => [p.productName, p.url.replace(/\.git$/, '').split('/').pop()]));
  const localTargets = new Set(product.targets.map((tg) => tg.name));
  const moduleOf = (tg) => tg.moduleName ?? tg.name;
  const swiftTarget = product.targets.find((tg) => tg.type === 'swift');
  const debug = ctx.flavor === 'debug';

  const depLines = (deps) => {
    const out = [];
    for (const d of deps ?? []) {
      if (localTargets.has(d)) out.push(swiftStr(d));
      else if (d === 'React') out.push(`.product(name: "ReactHeaders", package: "ReactNative")`, `.product(name: "ReactNativeHeaders", package: "ReactNative")`);
      else if (d === 'ReactNativeDependencies') out.push(`.product(name: "ReactNativeDependenciesHeaders", package: "ReactNative")`);
      else if (d === 'Hermes') out.push(`.product(name: "ReactNativeHeaders", package: "ReactNative")`);
      else if (spmProductPkg.has(d)) out.push(`.product(name: ${swiftStr(d)}, package: ${swiftStr(spmProductPkg.get(d))})`);
      else {
        const ext = externalPackageOf(d);
        const name = ext ? ext.product : d;
        if (name === 'ExpoModulesJSI') {
          usesJsi.value = true;
          out.push(`.product(name: "ExpoModulesJSIHeaders", package: "ExpoModulesJSIHeaders")`);
        } else if (fwByName.has(name)) {
          // Precompiled (npm or an earlier Linux prebuild): compile against the plugin's
          // interface tree, link the real slice.
          linkF.add(fwByName.get(name).dir);
          linkFrameworks.add(name);
        } else {
          const ours = ext && path.join(envArtifactDir(ctx, ext.pkg, ctx.flavor), `${name}.xcframework`, 'ios-arm64');
          if (ours && exists(ours)) {
            linkF.add(ours);
            linkFrameworks.add(name);
          } else fail(`${mod.packageName}: ${product.name} depends on ${d}, which is neither a precompiled framework nor built by expo-ios`);
        }
      }
    }
    // ExpoModulesCore's interface imports ExpoModulesJSI, so every target that sees an Expo
    // framework needs the JSI headers too (the plugin gives every Expo source package them).
    usesJsi.value = true;
    out.push(`.product(name: "ExpoModulesJSIHeaders", package: "ExpoModulesJSIHeaders")`);
    return [...new Set(out)];
  };
  // React, ReactNativeDependencies and hermes are always linked: they are the runtime.
  for (const n of ['React', 'ReactNativeDependencies', 'hermesvm']) {
    if (fwByName.has(n)) linkF.add(fwByName.get(n).dir), linkFrameworks.add(n);
  }

  // The plugin's interface tree minus this module's own frameworks: an earlier build of
  // them must not shadow the targets being compiled (`@import EXDevLauncher;` has to find
  // the in-build Swift target).
  const interfaces = path.join(work, 'compile-interfaces');
  rmrf(interfaces);
  mkdirp(interfaces);
  const own = new Set((mod.config.products ?? []).map((p) => `${p.name}.framework`));
  if (exists(g.compileInterfaces)) {
    for (const ent of fs.readdirSync(g.compileInterfaces)) {
      if (!own.has(ent)) fs.symlinkSync(path.join(g.compileInterfaces, ent), path.join(interfaces, ent));
    }
  }
  const targetDecls = [];
  const publicHeaders = [];
  for (const tg of product.targets) {
    const files = targetFiles(mod, tg);
    const tdir = path.join(pkg, 'Sources', tg.name);
    mkdirp(tdir);
    const place = (rel, destRel) => {
      const dest = path.join(tdir, destRel ?? rel);
      mkdirp(path.dirname(dest));
      if (!exists(dest)) fs.symlinkSync(path.join(files.root, rel), dest);
    };
    for (const rel of files.sources) place(rel);
    for (const m of tg.fileMapping ?? []) {
      const destRel = m.to.replace('{filename}', path.basename(m.from));
      if (exists(path.join(files.root, m.from))) place(m.from, destRel);
      else if (exists(path.join(mod.dir, m.from))) {
        const dest = path.join(tdir, destRel);
        mkdirp(path.dirname(dest));
        if (!exists(dest)) fs.symlinkSync(path.join(mod.dir, m.from), dest);
      }
    }
    const deps = depLines(tg.dependencies);
    const flags = [...(tg.compilerFlags?.common ?? []), ...((debug ? tg.compilerFlags?.debug : tg.compilerFlags?.release) ?? [])].map((f) => substitute(f, mod));
    const linked = (tg.linkedFrameworks ?? []).map((f) => `.linkedFramework(${swiftStr(f)})`);
    const fFlags = [...linkF].flatMap((d) => ['-F', d]);
    if (tg.type === 'swift') {
      // As Expo's SPMGenerator: the target re-exports its system frameworks and the sibling
      // targets it depends on, so Swift sees the Objective-C half of the module the way
      // CocoaPods' single module did.
      const exported = [...(tg.linkedFrameworks ?? []), ...(tg.dependencies ?? []).filter((d) => localTargets.has(d))];
      fs.writeFileSync(
        path.join(tdir, `${product.name}+Exports.swift`),
        `// AUTO-GENERATED by expo-ios\n${exported.map((m) => `@_exported import ${m}`).join('\n')}\n`
      );
      const swiftFlags = [
        '-enable-library-evolution', '-emit-module-interface', '-no-verify-emitted-module-interface',
        '-F', interfaces, ...fFlags,
        '-Xfrontend', '-load-plugin-executable', '-Xfrontend', `${path.join(resolvePackageDir(ctx.projectRoot, 'expo-modules-macros'), 'apple/ExpoModulesMacros')}#ExpoModulesMacros`,
        ...flags,
      ];
      targetDecls.push(`        .target(
            name: ${swiftStr(tg.name)},
            dependencies: [${deps.join(', ')}],
            path: ${swiftStr(`Sources/${tg.name}`)},
            swiftSettings: [${debug ? '.define("DEBUG"), ' : ''}.unsafeFlags([${swiftFlags.map(swiftStr).join(', ')}])],
            linkerSettings: [${linked.join(', ')}]
        )`);
    } else {
      // Public headers (headerPattern only), flattened to include/<moduleName>/ so both
      // <Module/Header.h> and "Header.h" resolve, as with CocoaPods.
      const flat = path.join(tdir, 'include', moduleOf(tg));
      mkdirp(flat);
      for (const h of files.headers) {
        const dest = path.join(flat, path.basename(h));
        if (!exists(dest)) fs.symlinkSync(path.join(files.root, h), dest);
        publicHeaders.push({ module: moduleOf(tg), file: path.join(files.root, h) });
      }
      const searchPaths = [...new Set([...(tg.includeDirectories ?? []), ...files.sources.map((s) => path.dirname(s))])].map((p) => `.headerSearchPath(${swiftStr(p)})`);
      const cflags = [...flags, '-F', interfaces, ...fFlags, '-I', flat];
      const cSettings = [...searchPaths, '.headerSearchPath("include")', `.unsafeFlags([${cflags.map(swiftStr).join(', ')}])`, debug ? '.define("DEBUG", to: "1")' : '.define("NDEBUG")'];
      targetDecls.push(`        .target(
            name: ${swiftStr(tg.name)},
            dependencies: [${deps.join(', ')}],
            path: ${swiftStr(`Sources/${tg.name}`)},
            publicHeadersPath: "include",
            cSettings: [${cSettings.join(', ')}],
            cxxSettings: [${cSettings.join(', ')}],
            linkerSettings: [${linked.join(', ')}]
        )`);
    }
  }
  const packages = [`.package(name: "ReactNative", path: ${swiftStr(g.xcframeworksPkg)})`];
  if (usesJsi.value) packages.push(`.package(name: "ExpoModulesJSIHeaders", path: ${swiftStr(g.jsiHeadersPkg)})`);
  for (const p of spmPackages) {
    const v = p.version ?? {};
    const req = v.exact ? `exact: ${swiftStr(v.exact)}` : v.from ? `from: ${swiftStr(v.from)}` : v.branch ? `branch: ${swiftStr(v.branch)}` : fail(`${mod.packageName}: unsupported spmPackages version ${JSON.stringify(v)}`);
    packages.push(`.package(url: ${swiftStr(p.url)}, ${req})`);
  }
  if (usesJsi.value) linkF.add(jsiFrameworkDir(ctx)), linkFrameworks.add('ExpoModulesJSI');
  const langModes = (product.swiftLanguageVersions ?? ['5']).map((v) => (String(v).startsWith('6') ? '.v6' : '.v5'));
  const manifest = `// swift-tools-version: 6.0
// AUTO-GENERATED by expo-ios (Linux et prebuild) from ${mod.packageName}@${mod.version} spm.config.json, product ${product.name}.
import PackageDescription

let package = Package(
    name: ${swiftStr(`${product.name}Prebuild`)},
    platforms: [${platformsOf(product).join(', ')}],
    products: [
        .library(name: ${swiftStr(product.name)}, type: .dynamic, targets: [${product.targets.map((tg) => swiftStr(tg.name)).join(', ')}]),
    ],
    dependencies: [
        ${packages.join(',\n        ')},
    ],
    targets: [
${targetDecls.join(',\n')}
    ],
    swiftLanguageModes: [${[...new Set(langModes)].join(', ')}],
    cxxLanguageStandard: .cxx20
)
`;
  writeIfChanged(path.join(pkg, 'Package.swift'), manifest);
  const config = debug ? 'debug' : 'release';
  const scratch = path.join(work, 'scratch');
  const linker = [
    ...[...linkF].flatMap((d) => ['-F', d]),
    ...[...linkFrameworks].flatMap((n) => ['-framework', n]),
    '-install_name', `@rpath/${product.name}.framework/${product.name}`,
    '-platform_version', 'ios', app.minIOS, ctx.sdkVersion,
  ];
  run(
    t.swift,
    [
      'build', '--package-path', pkg, '--scratch-path', scratch, '--configuration', config,
      ...swiftTargetArgs(ctx, app.minIOS),
      '--product', product.name,
      ...linker.flatMap((a) => ['-Xlinker', a]),
    ],
    { cwd: pkg, env: ctx.env, log: path.join(ctx.logDir, `prebuild-${mod.packageName.replace('/', '+')}-${ctx.flavor}.log`) }
  );
  assembleXcframework(ctx, app, { mod, product, scratch, configuration: debug ? 'Debug' : 'Release', publicHeaders, swiftTarget, outDir });
}

function assembleXcframework(ctx, app, { mod, product, scratch, configuration, publicHeaders, swiftTarget, outDir }) {
  const name = product.name;
  const built = findBuiltFramework(scratch, configuration, name);
  const xc = path.join(outDir, `${name}.xcframework`);
  const fw = path.join(xc, 'ios-arm64', `${name}.framework`);
  rmrf(xc);
  mkdirp(fw);
  if (built.framework) {
    for (const ent of fs.readdirSync(built.framework)) {
      if (ent === 'Headers' || ent === 'Modules') continue;
      copyTree(path.join(built.framework, ent), path.join(fw, ent));
    }
  } else if (built.dylib) {
    fs.copyFileSync(built.dylib, path.join(fw, name));
  } else fail(`${mod.packageName}: swift build produced no ${name} framework/dylib in ${built.products}`);
  const bin = path.join(fw, name);
  run('llvm-install-name-tool', ['-id', `@rpath/${name}.framework/${name}`, bin]);
  if (!exists(path.join(fw, 'Info.plist'))) {
    run('python3', [path.join(HERE, 'lib/plist_tool.py'), 'framework-info', path.join(fw, 'Info.plist'), name, `expo.modules.${name}`, app.minIOS]);
  }
  // Target `resources` → a resource bundle inside the framework (CocoaPods'
  // dynamic-framework layout; `resourceBundleName` names it, as `resource_bundles` does).
  // Compiled here rather than by SwiftBuild, which has no actool on Linux: asset catalogs
  // with omarchy's actool, everything else copied (`process` flattens directories).
  for (const tg of product.targets) {
    if (!tg.resources?.length) continue;
    const bundleName = tg.resourceBundleName ?? `${name}_${tg.name}`;
    const bundle = path.join(fw, `${bundleName}.bundle`);
    rmrf(bundle);
    mkdirp(bundle);
    const catalogs = [];
    for (const r of tg.resources) {
      const src = [path.join(mod.dir, r.path), path.join(mod.dir, tg.path ?? '.', r.path)].find((p) => exists(p));
      if (!src) fail(`${mod.packageName}: resource ${r.path} of target ${tg.name} not found`);
      if (src.endsWith('.xcassets') && r.rule !== 'copy') catalogs.push(src);
      else if (r.rule === 'copy' || !fs.statSync(src).isDirectory()) copyTree(src, path.join(bundle, path.basename(src)));
      else for (const rel of walk(src, { followSymlinks: true })) fs.copyFileSync(path.join(src, rel), path.join(bundle, path.basename(rel)));
    }
    if (catalogs.length) {
      if (!ctx.tools.actool) fail('actool not found (omarchy darwin-tools actool, installed with the Darwin SDK)');
      const partial = path.join(path.dirname(scratch), `${bundleName}-assetcatalog.plist`);
      run(ctx.tools.actool, [
        ...catalogs, '--compile', bundle, '--platform', 'iphoneos', '--minimum-deployment-target', app.minIOS,
        '--target-device', 'iphone', '--output-partial-info-plist', partial, '--output-format', 'human-readable-text',
      ], { env: ctx.env, log: path.join(ctx.logDir, `prebuild-${mod.packageName.replace('/', '+')}-${ctx.flavor}.log`) });
      if (!exists(path.join(bundle, 'Assets.car'))) fail(`${mod.packageName}: actool wrote no Assets.car for ${bundleName}.bundle`);
    }
    fs.writeFileSync(
      path.join(bundle, 'Info.plist'),
      `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key>
	<string>expo.modules.${name}.${bundleName}</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>${bundleName}</string>
	<key>CFBundlePackageType</key>
	<string>BNDL</string>
	<key>CFBundleSupportedPlatforms</key>
	<array>
		<string>iPhoneOS</string>
	</array>
</dict>
</plist>
`
    );
  }
  // Headers: public Objective-C headers, the generated -Swift.h, an umbrella.
  const headers = mkdirp(path.join(fw, 'Headers'));
  for (const h of publicHeaders) fs.copyFileSync(h.file, path.join(headers, path.basename(h.file)));
  const modules = mkdirp(path.join(fw, 'Modules'));
  let swiftHeader = null;
  if (swiftTarget) {
    const swiftmodule = walkFind(scratch, `${swiftTarget.name}.swiftmodule`, true);
    if (!swiftmodule) fail(`${name}: no ${swiftTarget.name}.swiftmodule in ${scratch}`);
    const dest = mkdirp(path.join(modules, `${name}.swiftmodule`));
    for (const f of fs.readdirSync(swiftmodule)) {
      if (/\.(swiftinterface|swiftdoc|abi\.json)$/.test(f) && !/\.(private|package)\.swiftinterface$/.test(f)) fs.copyFileSync(path.join(swiftmodule, f), path.join(dest, f.replace(/^[^.]+/, 'arm64-apple-ios')));
    }
    if (!fs.readdirSync(dest).some((f) => f.endsWith('.swiftinterface'))) {
      // Interfaces may be emitted beside the module rather than inside it.
      const iface = walkFind(scratch, `${swiftTarget.name}.swiftinterface`, false);
      if (!iface) fail(`${name}: no .swiftinterface was emitted (library evolution)`);
      fs.copyFileSync(iface, path.join(dest, 'arm64-apple-ios.swiftinterface'));
    }
    const gen = walkFind(scratch, `${swiftTarget.name}-Swift.h`, false);
    if (gen) {
      swiftHeader = `${name}-Swift.h`;
      fs.copyFileSync(gen, path.join(headers, swiftHeader));
    } else warn(`${name}: no ${swiftTarget.name}-Swift.h found; Objective-C consumers cannot see its Swift API`);
  }
  // The framework is one module: references to the product's internal SwiftPM targets in
  // the generated header and the interfaces become the product module (Expo's
  // rewriteInternalTargetModuleReferences / fixObjCSwiftHeaderModuleReferencesAsync).
  const internal = product.targets.map((tg) => tg.name).filter((n) => n !== name);
  const rewrite = (file, re, to) => {
    const text = fs.readFileSync(file, 'utf8');
    const out = text.replace(re, to);
    if (out !== text) fs.writeFileSync(file, out);
  };
  const esc = (n) => n.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  // The -Swift.h is a header of the framework module itself: an import of the module (or
  // of a target merged into it) is a self-import clang rejects ("import of module
  // 'EXDevLauncher' appears within same top-level module"), so drop those lines.
  if (swiftHeader) rewrite(path.join(headers, swiftHeader), new RegExp(`^@import (?:${[name, ...internal].map(esc).join('|')});\\n`, 'gm'), '');
  const alt = internal.map(esc).join('|');
  for (const f of walk(path.join(modules, `${name}.swiftmodule`))) {
    if (!f.endsWith('.swiftinterface')) continue;
    const file = path.join(modules, `${name}.swiftmodule`, f);
    if (internal.length) {
      rewrite(file, new RegExp(`^((?:@_exported )?import (?:[a-z]+ )?)(?:${alt})$`, 'gm'), `$1${name}`);
      // Module-qualified references (`EXDevLauncher_ios_objc_base::EXDevLauncherController`,
      // or `X.Y` without module selectors) name the product module too.
      rewrite(file, new RegExp(`\\b(?:${alt})(::|\\.)(?=[A-Za-z_])`, 'g'), `${name}$1`);
    }
    // `React::RCTJSStackFrame`: RCTJSStackFrame.h is outside the ReactHeaders umbrella, so
    // which Clang module owns the declaration differs between this build and the app
    // ("'RCTJSStackFrame' is not imported through module 'React'"; the
    // -module-interface-preserve-types-as-written frontend flag does not avoid the
    // selector). RCT-prefixed names do not collide; refer to them unqualified.
    rewrite(file, /\bReact::(?=RCT)/g, '');
  }
  const umbrella = `${name}_umbrella.h`;
  const umbrellaList = publicHeaders.map((h) => path.basename(h.file)).filter((h) => !(product.excludeFromUmbrella ?? []).includes(h));
  fs.writeFileSync(path.join(headers, umbrella), umbrellaList.map((h) => `#import "${h}"`).join('\n') + '\n');
  fs.writeFileSync(
    path.join(modules, 'module.modulemap'),
    `framework module ${name} {\n    use React\n    umbrella header "${umbrella}"\n${swiftHeader ? `    header "${swiftHeader}"\n` : ''}\n    export *\n    module * { export * }\n}\n`
  );
  fs.writeFileSync(
    path.join(xc, 'Info.plist'),
    `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>AvailableLibraries</key>
	<array>
		<dict>
			<key>BinaryPath</key>
			<string>${name}.framework/${name}</string>
			<key>LibraryIdentifier</key>
			<string>ios-arm64</string>
			<key>LibraryPath</key>
			<string>${name}.framework</string>
			<key>SupportedArchitectures</key>
			<array>
				<string>arm64</string>
			</array>
			<key>SupportedPlatform</key>
			<string>ios</string>
		</dict>
	</array>
	<key>CFBundlePackageType</key>
	<string>XFWK</string>
	<key>XCFrameworkFormatVersion</key>
	<string>1.0</string>
</dict>
</plist>
`
  );
}

function walkFind(root, name, isDir) {
  const stack = [root];
  while (stack.length) {
    const d = stack.pop();
    let ents;
    try {
      ents = fs.readdirSync(d, { withFileTypes: true });
    } catch {
      continue;
    }
    for (const e of ents) {
      const p = path.join(d, e.name);
      if (e.name === name && e.isDirectory() === isDir) return p;
      if (e.isDirectory()) stack.push(p);
    }
  }
  return null;
}
