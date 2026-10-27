// expo-ios: build Expo iOS apps on Linux (see ../README.md).
import fs from 'node:fs';
import path from 'node:path';
import { HERE, createContext, readAppSettings, requireSdk } from './context.mjs';
import { applyFixups } from './fixups.mjs';
import { applyOverlays, applyPatches } from './patching.mjs';
import { stageGraph, stagePrebuild } from './graph.mjs';
import { stageJsi } from './jsi.mjs';
import { modulesNeedingPrebuild, precompiledRoot, stageModules } from './spm-prebuild.mjs';
import { stageCompile, stageShell } from './shell.mjs';
import {
  resourceFiles, stageAssets, stageConstants, stageJs, stagePlainResources, stagePlist, stageStoryboards,
} from './resources.mjs';
import { appPath, machoLint, stageAssemble, stagePackage, verifyApp, writeReport } from './assemble.mjs';
import { install, missingCredentials, sign } from './device.mjs';
import { BuildError, exists, fail, info, mkdirp, run, stage, stageDone } from './util.mjs';

export const STAGES = [
  'patch', 'prebuild', 'graph', 'jsi', 'modules', 'shell', 'compile',
  'js', 'constants', 'resources', 'plist', 'assemble', 'package',
];
const HOOK_STAGES = new Set(['graph', 'modules', 'compile', 'assemble']);

const USAGE = `usage:
  expo-ios build --configuration Debug|Release [--out DIR] [--clean]
                 [--until STAGE] [--only STAGE,...] [--skip STAGE,...] [--project DIR]
  expo-ios sign    [--configuration C] [--out DIR]
  expo-ios install [--configuration C] [--out DIR] [--launch [SECONDS]]
  expo-ios doctor
  expo-ios stages
Stages: ${STAGES.join(' → ')}`;

function parseArgs(argv) {
  const opts = { command: argv[0], configuration: 'Release', project: process.cwd(), only: null, skip: [] };
  for (let i = 1; i < argv.length; i++) {
    const a = argv[i];
    const val = () => argv[++i] ?? fail(`${a} needs a value\n${USAGE}`);
    if (a === '--configuration' || a === '-c') opts.configuration = val();
    else if (a.startsWith('--configuration=')) opts.configuration = a.split('=')[1];
    else if (a === '--out') opts.out = val();
    else if (a === '--project') opts.project = val();
    else if (a === '--until') opts.until = val();
    else if (a === '--only') opts.only = val().split(',');
    else if (a === '--skip') opts.skip = val().split(',');
    else if (a === '--clean') opts.clean = true;
    else if (a === '--launch') {
      opts.launch = true;
      if (/^\d+$/.test(argv[i + 1] ?? '')) opts.consoleSeconds = Number(argv[++i]);
    } else if (a === '-h' || a === '--help') opts.command = 'help';
    else fail(`unknown argument ${a}\n${USAGE}`);
  }
  for (const s of [opts.until, ...(opts.only ?? []), ...opts.skip].filter(Boolean)) {
    if (!STAGES.includes(s)) fail(`unknown stage ${s}; stages: ${STAGES.join(', ')}`);
  }
  return opts;
}

function runHooks(ctx, stageName, extra) {
  const dir = path.join(HERE, 'hooks', `${stageName}.d`);
  if (!exists(dir)) return;
  for (const hook of fs.readdirSync(dir).sort()) {
    const file = path.join(dir, hook);
    if (!(fs.statSync(file).mode & 0o111)) continue;
    info(`hook ${stageName}.d/${hook}`);
    run(file, [], {
      cwd: ctx.projectRoot,
      env: {
        ...ctx.env,
        EXPO_IOS_CONFIGURATION: ctx.configuration,
        EXPO_IOS_FLAVOR: ctx.flavor,
        PROJECT_ROOT: ctx.projectRoot,
        IOS_DIR: ctx.iosDir,
        BUILD_DIR: ctx.outDir,
        SHELL_PACKAGE: ctx.shellDir,
        DARWIN_SDK_BUNDLE: ctx.tools.sdkBundle ?? '',
        IPHONEOS_SDK: ctx.tools.iphoneosSdk ?? '',
        EXPO_PRECOMPILED_MODULES_PATH: precompiledRoot(ctx),
        ...extra,
      },
      log: path.join(ctx.logDir, `hook-${stageName}.log`),
    });
  }
}

async function build(opts) {
  const ctx = createContext({ projectRoot: opts.project, configuration: opts.configuration, out: opts.out });
  ctx.env.EXPO_PRECOMPILED_MODULES_PATH = precompiledRoot(ctx);
  mkdirp(ctx.outDir);
  mkdirp(ctx.logDir);
  const started = Date.now();
  let selected = STAGES;
  if (opts.until) selected = STAGES.slice(0, STAGES.indexOf(opts.until) + 1);
  if (opts.only) selected = selected.filter((s) => opts.only.includes(s));
  selected = selected.filter((s) => !opts.skip.includes(s));
  const timings = {};
  let app = null;
  const appSettings = () => (app ??= readAppSettings(ctx));
  let pendingModules = null;
  const pending = () => (pendingModules ??= modulesNeedingPrebuild(ctx));
  const notPrebuilt = () =>
    pending()
      .filter((m) => !['debug', 'release'].every((f) => m.products.every((p) => exists(path.join(precompiledRoot(ctx), m.packageName, 'output', f, 'xcframeworks', `${p.name}.xcframework`)))))
      .map((m) => m.packageName);
  let report = {};
  let resources = null;

  for (const name of selected) {
    stage(`${name} (${ctx.configuration})`);
    switch (name) {
      case 'patch':
        applyPatches(ctx);
        applyOverlays(ctx);
        applyFixups(ctx.projectRoot);
        break;
      case 'prebuild':
        stagePrebuild(ctx, { clean: opts.clean });
        break;
      case 'graph': {
        const excluded = notPrebuilt();
        if (excluded.length) info(`left out until the modules stage prebuilds them: ${excluded.join(', ')}`);
        stageGraph(ctx, { pendingExclude: excluded });
        ctx.graphExcluded = excluded;
        break;
      }
      case 'jsi':
        stageJsi(ctx, appSettings());
        break;
      case 'modules': {
        const mods = pending();
        if (mods.length) info(`Linux prebuild: ${mods.map((m) => `${m.packageName}@${m.version} (${m.products.map((p) => p.name).join(', ')})`).join(', ')}`);
        const built = stageModules(ctx, appSettings(), mods);
        if (built.length || (ctx.graphExcluded ?? notPrebuilt()).length) stageGraph(ctx, { pendingExclude: [] });
        break;
      }
      case 'shell':
        stageShell(ctx, appSettings());
        break;
      case 'compile':
        stageCompile(ctx, appSettings());
        break;
      case 'js':
        stageJs(ctx);
        break;
      case 'constants':
        stageConstants(ctx);
        break;
      case 'resources': {
        resources = resourceFiles(ctx, appSettings());
        const copied = stagePlainResources(ctx, resources);
        if (copied.length) info(`resources: ${copied.join(', ')}`);
        stageAssets(ctx, appSettings(), resources);
        stageStoryboards(ctx, appSettings(), resources);
        break;
      }
      case 'plist':
        stagePlist(ctx, appSettings());
        break;
      case 'assemble':
        stageAssemble(ctx, appSettings());
        report = verifyApp(ctx, appSettings());
        break;
      case 'package': {
        const ipa = stagePackage(ctx);
        report.ipa = ipa;
        report.machoLint = machoLint(ctx, ipa, { signed: false });
        break;
      }
    }
    timings[name] = stageDone(name);
    if (HOOK_STAGES.has(name)) {
      runHooks(ctx, name, {
        PRODUCTS_DIR: path.join(ctx.scratchDir, 'out', 'Products', `${ctx.configuration}-iphoneos`),
        APP_BUNDLE: appPath(ctx),
        MIN_IOS: app?.minIOS ?? '',
      });
    }
  }
  const total = ((Date.now() - started) / 1000).toFixed(1);
  if (selected.includes('assemble') || selected.includes('package')) {
    writeReport(ctx, { ...report, timings, totalSeconds: Number(total), nproc: navigatorCpus() });
  }
  process.stderr.write(`\n== done in ${total}s: ${Object.entries(timings).map(([k, v]) => `${k} ${v}s`).join(', ')}\n`);
  if (exists(appPath(ctx)) && selected.includes('package')) {
    console.log(appPath(ctx));
    console.log(report.ipa);
  }
}

function navigatorCpus() {
  return (fs.readFileSync('/proc/cpuinfo', 'utf8').match(/^processor\s*:/gm) ?? []).length;
}

function doctor(opts) {
  const ctx = createContext({ projectRoot: opts.project, configuration: opts.configuration });
  const t = ctx.tools;
  const rows = [
    ['node', t.node],
    ['swift', t.swift],
    ['Darwin SDK bundle', t.sdkBundle],
    ['iPhoneOS.sdk', t.iphoneosSdk && exists(t.iphoneosSdk) ? t.iphoneosSdk : null],
    ['SwiftBuild toolset', t.toolset && exists(t.toolset) ? t.toolset : null],
    ['shims', exists(t.shims) ? t.shims : null],
    ['omarchy-apple-dev', exists(t.omarchy) ? t.omarchy : null],
    ['actool', t.actool],
    ['ibtool', t.ibtool],
    ['hermesc (linux)', t.hermesc && exists(t.hermesc) ? t.hermesc : null],
    ['llvm-otool', t.otool],
    ['pod', run('sh', ['-c', 'command -v pod'], { capture: true, allowFail: true }).stdout.trim() || null],
  ];
  for (const [k, v] of rows) console.log(`${v ? 'ok     ' : 'MISSING'} ${k}${v ? `: ${v}` : ''}`);
  let bundleId;
  try {
    bundleId = readAppSettings(ctx).bundleId;
  } catch {}
  const creds = missingCredentials(ctx, { forInstall: true, bundleId });
  for (const c of creds) console.log(`MISSING ${c}`);
  try {
    requireSdk(ctx);
    console.log(`ok      SDK version ${ctx.sdkVersion}`);
  } catch (e) {
    console.log(`MISSING ${e.message}`);
  }
}

export async function main(argv) {
  try {
    const opts = parseArgs(argv);
    switch (opts.command) {
      case 'build':
        await build(opts);
        break;
      case 'sign': {
        const ctx = createContext({ projectRoot: opts.project, configuration: opts.configuration, out: opts.out });
        console.log(sign(ctx));
        break;
      }
      case 'install': {
        const ctx = createContext({ projectRoot: opts.project, configuration: opts.configuration, out: opts.out });
        install(ctx, { launch: opts.launch, consoleSeconds: opts.consoleSeconds });
        break;
      }
      case 'doctor':
        doctor(opts);
        break;
      case 'stages':
        console.log(STAGES.join('\n'));
        break;
      case 'help':
      case '--help':
      case '-h':
      case undefined:
        console.log(USAGE);
        break;
      default:
        fail(`unknown command ${opts.command}\n${USAGE}`);
    }
  } catch (e) {
    if (e instanceof BuildError) {
      process.stderr.write(`\nexpo-ios: error: ${e.message}\n`);
      process.exit(1);
    }
    throw e;
  }
}
