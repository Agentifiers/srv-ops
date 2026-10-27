// Stages `assemble` and `package`: App.app (what Xcode's link, embed and copy-resources
// steps produce) and App-unsigned.ipa, then verification of the result.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { HERE } from './context.mjs';
import { flavoredFrameworks, jsiFrameworkDir, productsDir } from './shell.mjs';
import { stagePaths, hermesMagic } from './resources.mjs';
import { copyTree, exists, fail, info, mkdirp, rmrf, run, warn, writeJSON } from './util.mjs';

export function appPath(ctx) {
  return path.join(ctx.outDir, 'App.app');
}

/** Copy a framework the way Xcode's "Embed Frameworks" does: no headers, modules or old signature. */
function embedFramework(src, framesDir) {
  const dest = path.join(framesDir, path.basename(src));
  rmrf(dest);
  copyTree(src, dest);
  for (const strip of ['Headers', 'PrivateHeaders', 'Modules', '_CodeSignature']) rmrf(path.join(dest, strip));
  run('chmod', ['-R', 'u+w', dest]);
  return dest;
}

function rpathDeps(file) {
  const r = run('llvm-otool', ['-L', file], { capture: true, allowFail: true });
  if (r.status !== 0) return [];
  return [...r.stdout.matchAll(/^\s+@rpath\/(\S+)/gm)].map((m) => m[1]);
}

export function stageAssemble(ctx, app) {
  const p = stagePaths(ctx);
  const bundle = appPath(ctx);
  rmrf(bundle);
  const frames = mkdirp(path.join(bundle, 'Frameworks'));
  const products = productsDir(ctx);

  // Executable (+ dSYM before stripping).
  const exeSrc = path.join(products, app.moduleName);
  const exe = path.join(bundle, app.executableName);
  fs.copyFileSync(exeSrc, exe);
  fs.chmodSync(exe, 0o755);
  const dsymutil = ['dsymutil', 'llvm-dsymutil'].find((t) => run('sh', ['-c', `command -v ${t}`], { capture: true, allowFail: true }).status === 0);
  if (dsymutil) {
    const dsym = path.join(ctx.outDir, 'App.app.dSYM');
    rmrf(dsym);
    const r = run(dsymutil, [exeSrc, '-o', dsym], { log: path.join(ctx.logDir, 'dsymutil.log'), allowFail: true });
    if (r.status !== 0) warn(`dsymutil failed (see ${path.join(ctx.logDir, 'dsymutil.log')}); no dSYM`);
  }
  if (ctx.configuration === 'Release') run('llvm-strip', ['-x', exe]);

  // Runtime frameworks of this flavor, ExpoModulesJSI, then any dynamic SwiftPM product the
  // images load (repeat until closed, as omarchy flutter/build.sh does).
  for (const f of flavoredFrameworks(ctx)) embedFramework(f.framework, frames);
  embedFramework(path.join(jsiFrameworkDir(ctx), 'ExpoModulesJSI.framework'), frames);
  for (let round = 0; round < 64; round++) {
    let added = 0;
    for (const img of [exe, ...walkImages(frames)]) {
      for (const dep of rpathDeps(img)) {
        const top = dep.includes('.framework/') ? dep.slice(0, dep.indexOf('.framework/') + '.framework'.length) : dep;
        if (exists(path.join(frames, top))) continue;
        for (const cand of [path.join(products, 'PackageFrameworks', top), path.join(products, top)]) {
          if (exists(cand)) {
            if (top.endsWith('.framework')) embedFramework(cand, frames);
            else fs.copyFileSync(cand, path.join(frames, top));
            info(`embedding ${top}`);
            added++;
            break;
          }
        }
      }
    }
    if (!added) break;
  }

  // The toolset links Swift images with an rpath into the build host's toolchain
  // (/opt/swift/usr/lib/swift-6.2/iphoneos); inert on a device, so drop it.
  for (const img of [exe, ...walkImages(frames)]) {
    const rpaths = [...run('llvm-otool', ['-l', img], { capture: true }).stdout.matchAll(/cmd LC_RPATH[\s\S]*?path (\S+) \(offset/g)].map((m) => m[1]);
    const host = [...new Set(rpaths.filter((r) => !r.startsWith('@') && !r.startsWith('/usr/lib') && !r.startsWith('/System/')))];
    if (host.length) run('llvm-install-name-tool', host.flatMap((r) => ['-delete_rpath', r]).concat(img), { capture: true });
  }

  // SwiftPM resource bundles of statically linked targets, then everything staged.
  if (exists(products)) {
    for (const ent of fs.readdirSync(products)) if (ent.endsWith('.bundle')) copyTree(path.join(products, ent), path.join(bundle, ent));
  }
  if (exists(p.res)) for (const ent of fs.readdirSync(p.res)) copyTree(path.join(p.res, ent), path.join(bundle, ent));
  fs.copyFileSync(p.infoPlist, path.join(bundle, 'Info.plist'));
  fs.writeFileSync(path.join(bundle, 'PkgInfo'), 'APPL????');
  if (app.entitlements && exists(app.entitlements)) fs.copyFileSync(app.entitlements, path.join(ctx.outDir, 'App.entitlements'));
  run('chmod', ['-R', 'u+w,go+rX', bundle]);
  return bundle;
}

function walkImages(frames) {
  return fs
    .readdirSync(frames)
    .map((ent) => (ent.endsWith('.framework') ? path.join(frames, ent, ent.replace(/\.framework$/, '')) : ent.endsWith('.dylib') ? path.join(frames, ent) : null))
    .filter((p) => p && exists(p));
}

/** Fail unless the bundle is a complete arm64 iOS app (acceptance checks, also run on every build). */
export function verifyApp(ctx, app) {
  const bundle = appPath(ctx);
  const report = { app: bundle, configuration: ctx.configuration };
  const plist = run('python3', [path.join(HERE, 'lib/plist_tool.py'), 'check-app', bundle], { capture: true });
  report.infoPlist = JSON.parse(plist.stdout);
  const exe = path.join(bundle, app.executableName);
  const header = run('llvm-otool', ['-hv', exe], { capture: true }).stdout;
  if (!/ARM64/.test(header) || !/EXECUTE/.test(header)) fail(`${exe} is not an arm64 Mach-O executable:\n${header}`);
  const loads = run('llvm-otool', ['-l', exe], { capture: true }).stdout;
  const block = /cmd LC_BUILD_VERSION\n([\s\S]*?)(?:\nLoad command|$)/.exec(loads)?.[1] ?? '';
  const field = (k) => new RegExp(`^\\s*${k} (\\S+)`, 'm').exec(block)?.[1];
  const platform = [null, field('platform'), field('minos'), field('sdk')];
  if (!['2', 'IOS', 'iOS', 'ios'].includes(platform[1])) fail(`${exe}: LC_BUILD_VERSION platform is not iOS (${platform[1]})`);
  if (platform[2] !== app.minIOS && platform[2] !== `${app.minIOS}.0`) fail(`${exe}: LC_BUILD_VERSION minos ${platform[2]} != deployment target ${app.minIOS}`);
  report.buildVersion = { platform: platform[1], minos: platform[2], sdk: platform[3] };
  const linked = run('llvm-otool', ['-L', exe], { capture: true }).stdout;
  report.linked = linked.split('\n').slice(1).map((l) => l.trim().split(' (')[0]).filter(Boolean);
  const required = ['React', 'ReactNativeDependencies', 'hermesvm', 'ExpoModulesJSI', 'ExpoModulesCore'];
  for (const r of required) if (!linked.includes(`@rpath/${r}.framework/${r}`)) fail(`${exe} does not link @rpath/${r}.framework`);
  // Every @rpath dependency of every image must be embedded.
  const frames = path.join(bundle, 'Frameworks');
  const missing = [];
  for (const img of [exe, ...walkImages(frames)]) {
    for (const dep of rpathDeps(img)) {
      if (img.endsWith(dep)) continue; // the image's own install name
      if (!exists(path.join(frames, dep))) missing.push(`${path.basename(img)} → @rpath/${dep}`);
    }
  }
  if (missing.length) fail(`unembedded dependencies:\n  ${[...new Set(missing)].join('\n  ')}`);
  report.frameworks = fs.readdirSync(frames).sort();
  if (ctx.configuration === 'Release') {
    const jsb = path.join(bundle, 'main.jsbundle');
    if (!exists(jsb) || !hermesMagic(jsb)) fail('main.jsbundle missing or not Hermes bytecode');
    report.mainJsbundle = { bytes: fs.statSync(jsb).size, format: 'Hermes bytecode' };
  }
  report.assetsCar = exists(path.join(bundle, 'Assets.car'));
  report.storyboards = fs.readdirSync(bundle).filter((f) => f.endsWith('.storyboardc'));
  report.closure = linkClosure(ctx);
  return report;
}

/**
 * dyld-style closure (lib/closure.py): every load command and every undefined symbol of
 * every image resolves against the embedded images and the SDK's .tbd files.
 */
export function linkClosure(ctx) {
  const out = path.join(ctx.outDir, 'closure.json');
  const r = run('python3', [path.join(HERE, 'lib/closure.py'), appPath(ctx), '--sdk', ctx.tools.iphoneosSdk, '--json', out], {
    capture: true,
    allowFail: true,
  });
  for (const l of r.stderr.split('\n').filter((l) => l.startsWith('warning: '))) warn(l.slice(9));
  if (r.status !== 0) fail(`link closure incomplete (${out}):\n${r.stderr.split('\n').filter((l) => l.startsWith('error: ')).join('\n')}`);
  info(r.stdout.trim());
  return { ...JSON.parse(fs.readFileSync(out, 'utf8')).summary, report: out };
}

/** omarchy macho-lint over the ipa; unsigned builds are expected to lack signatures only. */
export function machoLint(ctx, ipa, { signed }) {
  const lint = path.join(ctx.tools.omarchy, 'tools/macho-lint.py');
  if (!exists(lint)) {
    warn(`omarchy macho-lint not found at ${lint}`);
    return null;
  }
  mkdirp(path.join(os.homedir(), 'tmp'));
  const r = run('python3', [lint, ipa], { capture: true, allowFail: true });
  const lines = r.stdout.trim().split('\n');
  const real = lines
    .filter((l) => l.startsWith('FAIL'))
    .map((l) => ({ l, problems: l.split('  ').slice(-1)[0].split('; ').filter((pb) => signed || !/LC_CODE_SIGNATURE|rcodesign verify/.test(pb)) }))
    .filter((x) => x.problems.some((pb) => /cputype|platform|string pool|string table|LC_CODE_SIGNATURE|rcodesign/.test(pb)));
  if (real.length) fail(`macho-lint:\n${real.map((x) => x.l).join('\n')}`);
  return lines[lines.length - 1];
}

export function stagePackage(ctx) {
  const bundle = appPath(ctx);
  const stage = path.join(ctx.outDir, 'ipa-stage');
  rmrf(stage);
  mkdirp(path.join(stage, 'Payload'));
  copyTree(bundle, path.join(stage, 'Payload', 'App.app'));
  const ipa = path.join(ctx.outDir, 'App-unsigned.ipa');
  rmrf(ipa);
  run('zip', ['-qry', ipa, 'Payload'], { cwd: stage });
  rmrf(stage);
  return ipa;
}

export function writeReport(ctx, report) {
  writeJSON(path.join(ctx.outDir, 'build.json'), report);
}

