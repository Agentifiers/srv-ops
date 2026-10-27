// Stages js, constants, assets, storyboard, plist: everything in the .app that is
// not compiled code. Output goes to <out>/stage/res (copied into the bundle root).
import fs from 'node:fs';
import path from 'node:path';
import { createRequire } from 'node:module';
import { HERE } from './context.mjs';
import { copyTree, exists, fail, info, mkdirp, resolvePackageDir, rmrf, run, writeJSON } from './util.mjs';

export function stagePaths(ctx) {
  const stage = path.join(ctx.outDir, 'stage');
  return {
    stage,
    res: path.join(stage, 'res'), // copied verbatim into the .app root
    partials: path.join(stage, 'partials'),
    js: path.join(stage, 'js'),
    sbc: path.join(stage, 'sbc'),
    infoPlist: path.join(stage, 'Info.plist'),
  };
}

export function hermesMagic(file) {
  const fd = fs.openSync(file, 'r');
  const buf = Buffer.alloc(8);
  fs.readSync(fd, buf, 0, 8, 0);
  fs.closeSync(fd);
  // Hermes bytecode magic, little endian 0x1F1903C103BC1FC6.
  return buf.equals(Buffer.from([0xc6, 0x1f, 0xbc, 0x03, 0xc1, 0x03, 0x19, 0x1f]));
}

/** Release: Metro bundle via `expo export:embed`, compiled by Linux hermesc. Debug loads from Metro. */
export function stageJs(ctx) {
  const p = stagePaths(ctx);
  rmrf(p.js);
  mkdirp(p.js);
  if (ctx.configuration === 'Debug') {
    info('Debug: no embedded bundle (the dev client loads JS from Metro)');
    return null;
  }
  const hermesc = ctx.tools.hermesc;
  if (!hermesc || !exists(hermesc)) fail(`Linux hermesc not found (${hermesc}); is hermes-compiler installed?`);
  const entry = run(ctx.tools.node, ['-e', "require('expo/scripts/resolveAppEntry')", ctx.projectRoot, 'ios', 'absolute'], {
    cwd: ctx.projectRoot,
    env: ctx.env,
    capture: true,
  })
    .stdout.trim()
    .split('\n')
    .pop();
  const jsOut = path.join(p.js, 'main.jsbundle.js');
  const packagerMap = path.join(p.js, 'main.jsbundle.packager.map');
  const assetsDest = path.join(p.js, 'assets-root');
  mkdirp(assetsDest);
  run(
    ctx.tools.node,
    [
      path.join(ctx.expo, 'bin', 'cli'),
      'export:embed',
      '--entry-file', entry,
      '--platform', 'ios',
      '--dev', 'false',
      '--reset-cache',
      '--bundle-output', jsOut,
      '--assets-dest', assetsDest,
      '--minify', 'false',
      '--sourcemap-output', packagerMap,
    ],
    { cwd: ctx.projectRoot, env: { ...ctx.env, NODE_ENV: 'production' }, log: path.join(ctx.logDir, 'js.log') }
  );
  const hbc = path.join(p.js, 'main.jsbundle');
  run(hermesc, ['-emit-binary', '-max-diagnostic-width=80', '-O', '-output-source-map', '-out', hbc, jsOut], {
    log: path.join(ctx.logDir, 'js.log'),
  });
  if (!hermesMagic(hbc)) fail(`${hbc} is not Hermes bytecode`);
  run(ctx.tools.node, [path.join(ctx.rn, 'scripts/compose-source-maps.js'), packagerMap, `${hbc}.map`, '-o', path.join(ctx.outDir, 'main.jsbundle.map')], {
    log: path.join(ctx.logDir, 'js.log'),
  });
  fs.rmSync(`${hbc}.map`);
  // The bundle and the assets Metro wrote both go to the bundle root (Xcode's DEST).
  mkdirp(p.res);
  fs.copyFileSync(hbc, path.join(p.res, 'main.jsbundle'));
  for (const ent of fs.readdirSync(assetsDest)) {
    rmrf(path.join(p.res, ent));
    copyTree(path.join(assetsDest, ent), path.join(p.res, ent));
  }
  const size = fs.statSync(hbc).size;
  info(`main.jsbundle: Hermes bytecode, ${(size / 1e6).toFixed(2)} MB (hermesc ${path.basename(path.dirname(path.dirname(path.dirname(hermesc))))})`);
  return hbc;
}

/** EXConstants.bundle/app.config (expo-constants' SwiftPM script phase). */
export function stageConstants(ctx) {
  const dir = resolvePackageDir(ctx.projectRoot, 'expo-constants');
  if (!dir) return null;
  const p = stagePaths(ctx);
  mkdirp(p.res);
  rmrf(path.join(p.res, 'EXConstants.bundle'));
  run('bash', [path.join(dir, 'scripts/get-app-config-ios.sh')], {
    cwd: ctx.projectRoot,
    env: {
      ...ctx.env,
      EXPO_CONSTANTS_APP_CONFIG_DEST: p.res,
      EXPO_CONSTANTS_ALLOW_NON_PODS: '1',
      BUNDLE_FORMAT: 'shallow',
      PROJECT_ROOT: ctx.projectRoot,
      PROJECT_DIR: ctx.iosDir,
      CONFIGURATION: ctx.configuration,
    },
    log: path.join(ctx.logDir, 'constants.log'),
  });
  const config = path.join(p.res, 'EXConstants.bundle/app.config');
  if (!exists(config)) fail(`expo-constants did not write ${config}`);
  JSON.parse(fs.readFileSync(config, 'utf8'));
  return config;
}

/** The app target's Copy Bundle Resources phase, resolved to absolute paths. */
export function resourceFiles(ctx, app) {
  const xcode = createRequire(require_from(ctx))('xcode');
  const projects = fs.readdirSync(ctx.iosDir).filter((f) => f.endsWith('.xcodeproj'));
  const proj = xcode.project(path.join(ctx.iosDir, projects[0], 'project.pbxproj'));
  proj.parseSync();
  const objects = proj.hash.project.objects;
  const parentOf = new Map();
  for (const section of ['PBXGroup', 'PBXVariantGroup']) {
    for (const [id, g] of Object.entries(objects[section] ?? {})) {
      if (typeof g !== 'object' || !g.children) continue;
      for (const c of g.children) parentOf.set(c.value, id);
    }
  }
  const lookup = (id) => {
    for (const section of ['PBXFileReference', 'PBXGroup', 'PBXVariantGroup']) {
      if (objects[section]?.[id] && typeof objects[section][id] === 'object') return { section, obj: objects[section][id] };
    }
    return null;
  };
  const unquote = (s) => (typeof s === 'string' ? s.replace(/^"(.*)"$/, '$1') : s);
  const fullPath = (id) => {
    const parts = [];
    let cur = id;
    while (cur) {
      const ref = lookup(cur);
      if (!ref) break;
      const { obj } = ref;
      const tree = unquote(obj.sourceTree);
      if (obj.path) parts.unshift(unquote(obj.path));
      if (tree === 'SOURCE_ROOT' || tree === '<absolute>') break;
      cur = parentOf.get(cur);
    }
    return path.resolve(ctx.iosDir, ...parts);
  };
  const target = Object.values(objects.PBXNativeTarget).find((t) => typeof t === 'object' && unquote(t.name) === app.target);
  if (!target) fail(`no target ${app.target} in the pbxproj`);
  const phases = target.buildPhases.map((p) => p.value);
  const resPhase = phases.map((id) => objects.PBXResourcesBuildPhase?.[id]).find(Boolean);
  if (!resPhase) return [];
  const out = [];
  for (const f of resPhase.files) {
    const bf = objects.PBXBuildFile[f.value];
    const ref = lookup(bf.fileRef);
    if (!ref) continue;
    if (ref.section === 'PBXVariantGroup') {
      for (const c of ref.obj.children) out.push({ path: fullPath(c.value), variant: unquote(ref.obj.name) });
    } else out.push({ path: fullPath(bf.fileRef) });
  }
  return out;
}

function require_from(ctx) {
  const plugins = resolvePackageDir(ctx.expo, '@expo/config-plugins') ?? resolvePackageDir(ctx.projectRoot, '@expo/config-plugins');
  if (!plugins) fail('@expo/config-plugins not found (it ships with expo)');
  return path.join(plugins, 'package.json');
}

/** Asset catalogs (+ Icon Composer .icon) → Assets.car with omarchy's Linux actool. */
export function stageAssets(ctx, app, resources) {
  const p = stagePaths(ctx);
  const inputs = resources.filter((r) => /\.(xcassets|icon)$/.test(r.path)).map((r) => r.path);
  rmrf(path.join(p.partials, 'assetcatalog.plist'));
  if (inputs.length === 0) return null;
  const actool = ctx.tools.actool;
  if (!actool) fail('actool not found (omarchy darwin-tools actool, installed with the Darwin SDK)');
  mkdirp(p.res);
  mkdirp(p.partials);
  const devices = app.deviceFamily.split(',').map((f) => (f.trim() === '2' ? 'ipad' : 'iphone'));
  const args = [
    ...inputs,
    '--compile', p.res,
    '--platform', 'iphoneos',
    '--minimum-deployment-target', app.minIOS,
    ...devices.flatMap((d) => ['--target-device', d]),
    '--output-partial-info-plist', path.join(p.partials, 'assetcatalog.plist'),
    '--output-format', 'human-readable-text',
  ];
  if (app.appIconName && inputs.some((i) => i.endsWith(`${app.appIconName}.icon`) || hasAppIconSet(i, app.appIconName))) {
    args.push('--app-icon', app.appIconName);
  }
  run(actool, args, { env: ctx.env, log: path.join(ctx.logDir, 'actool.log') });
  const car = path.join(p.res, 'Assets.car');
  if (!exists(car)) fail(`actool did not write ${car}`);
  info(`Assets.car: ${(fs.statSync(car).size / 1024).toFixed(0)} KB from ${inputs.map((i) => path.basename(i)).join(', ')}`);
  return car;
}

function hasAppIconSet(input, name) {
  return input.endsWith('.xcassets') && exists(path.join(input, `${name}.appiconset`));
}

/** Storyboards → .storyboardc with omarchy's Linux ibtool (compile, then link). */
export function stageStoryboards(ctx, app, resources) {
  const p = stagePaths(ctx);
  const boards = resources.filter((r) => /\.(storyboard|xib)$/.test(r.path));
  rmrf(p.sbc);
  if (boards.length === 0) return [];
  const ibtool = ctx.tools.ibtool;
  if (!ibtool) fail('ibtool not found (omarchy tools/ibtool)');
  mkdirp(p.sbc);
  mkdirp(p.partials);
  const devices = app.deviceFamily.split(',').map((f) => (f.trim() === '2' ? 'ipad' : 'iphone'));
  const dev = devices.flatMap((d) => ['--target-device', d]);
  const outputs = [];
  for (const b of boards) {
    const base = path.basename(b.path);
    const destDir = b.variant ? path.join(p.res, path.basename(path.dirname(b.path))) : p.res;
    if (base.endsWith('.xib')) {
      mkdirp(destDir);
      run(ibtool, ['--module', app.moduleName, '--minimum-deployment-target', app.minIOS, ...dev, '--compile', path.join(destDir, base.replace(/\.xib$/, '.nib')), b.path], {
        env: ctx.env,
        log: path.join(ctx.logDir, 'ibtool.log'),
      });
      continue;
    }
    run(
      ibtool,
      [
        '--module', app.moduleName,
        '--minimum-deployment-target', app.minIOS,
        ...dev,
        '--output-partial-info-plist', path.join(p.partials, `${base}.plist`),
        b.path,
        '--compilation-directory', p.sbc,
      ],
      { env: ctx.env, log: path.join(ctx.logDir, 'ibtool.log') }
    );
    mkdirp(destDir);
    const compiled = path.join(p.sbc, base.replace(/\.storyboard$/, '.storyboardc'));
    run(ibtool, ['--module', app.moduleName, ...dev, '--link', destDir, compiled], { env: ctx.env, log: path.join(ctx.logDir, 'ibtool.log') });
    outputs.push(path.join(destDir, path.basename(compiled)));
  }
  for (const o of outputs) if (!exists(o)) fail(`ibtool did not produce ${o}`);
  info(`storyboards: ${outputs.map((o) => path.basename(o)).join(', ')}`);
  return outputs;
}

/** Plain resources (Expo.plist, fonts, GoogleService-Info.plist, ...) are copied as is. */
export function stagePlainResources(ctx, resources) {
  const p = stagePaths(ctx);
  mkdirp(p.res);
  const copied = [];
  for (const r of resources) {
    if (/\.(xcassets|icon|storyboard|xib)$/.test(r.path)) continue;
    if (!exists(r.path)) fail(`resource ${r.path} (Copy Bundle Resources) does not exist`);
    const destDir = r.variant ? path.join(p.res, path.basename(path.dirname(r.path))) : p.res;
    mkdirp(destDir);
    const dest = path.join(destDir, path.basename(r.path));
    rmrf(dest);
    copyTree(r.path, dest);
    copied.push(path.relative(p.res, dest));
  }
  return copied;
}

export function stagePlist(ctx, app) {
  const p = stagePaths(ctx);
  const settings = {
    ...app.settings,
    DEVELOPMENT_LANGUAGE: 'en',
    EXECUTABLE_NAME: app.executableName,
    PRODUCT_NAME: app.productName,
    PRODUCT_MODULE_NAME: app.moduleName,
    PRODUCT_BUNDLE_IDENTIFIER: app.bundleId,
    PRODUCT_BUNDLE_PACKAGE_TYPE: 'APPL',
    MARKETING_VERSION: app.marketingVersion,
    CURRENT_PROJECT_VERSION: app.buildNumber,
    IPHONEOS_DEPLOYMENT_TARGET: app.minIOS,
    TARGET_NAME: app.target,
    CONFIGURATION: ctx.configuration,
  };
  const partials = fs.existsSync(p.partials) ? fs.readdirSync(p.partials).filter((f) => f.endsWith('.plist')).map((f) => path.join(p.partials, f)) : [];
  const cfgFile = path.join(p.stage, 'plist-settings.json');
  const sdk = ctx.tools.iphoneosSdk && exists(ctx.tools.iphoneosSdk) ? ctx.tools.iphoneosSdk : null;
  writeJSON(cfgFile, {
    src: app.infoPlist,
    settings,
    sdk,
    release: ctx.configuration === 'Release',
    device_family: app.deviceFamily,
    xcode_version_plist: ctx.tools.xcodeVersionPlist,
  });
  run('python3', [path.join(HERE, 'lib/plist_tool.py'), 'info-plist', cfgFile, p.infoPlist, ...partials], { log: path.join(ctx.logDir, 'plist.log') });
  return p.infoPlist;
}
