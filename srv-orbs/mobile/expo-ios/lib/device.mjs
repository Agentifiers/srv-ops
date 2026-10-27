// `expo-ios sign` and `expo-ios install`.
// sign: omarchy-apple-dev's development signing (provision-dev.py + sign-dev.sh, App Store
// Connect API) when this orb has an ASC key; otherwise `iphone sign`, which signs on the srv
// host (the team key stays there) for the shared iPhone.
// install: `iphone install` / `iphone launch` through the host's iphone-broker (leased, USB).
import os from 'node:os';
import path from 'node:path';
import { appPath, machoLint } from './assemble.mjs';
import { readAppSettings } from './context.mjs';
import { exists, fail, info, run } from './util.mjs';

export function signingDir() {
  return process.env.EXPO_IOS_SIGNING_DIR ?? path.join(os.homedir(), '.config/omarchy-apple-dev/development');
}

function onPath(cmd) {
  return run('sh', ['-c', `command -v ${cmd}`], { capture: true, allowFail: true }).stdout.trim();
}

const ASC_VARS = ['ASC_KEY_ID', 'ASC_ISSUER_ID', 'ASC_KEY_PATH'];

/** Local signing (omarchy) when the orb has an App Store Connect key, else the host's broker. */
function signsLocally() {
  return ASC_VARS.every((k) => process.env[k]);
}

/** What sign/install still need, as human-readable lines (empty = ready). */
export function missingCredentials(ctx, { forInstall = false } = {}) {
  const lines = [];
  if (signsLocally()) {
    if (!onPath('rcodesign')) lines.push('rcodesign on PATH');
  } else if (!onPath('iphone')) {
    lines.push(`\`iphone\` (host signing; or set ${ASC_VARS.join(', ')} to sign in this orb)`);
  }
  if (forInstall && !onPath('iphone')) lines.push('`iphone` on PATH (the iphone-client image module)');
  return lines;
}

export function sign(ctx) {
  const app = readAppSettings(ctx);
  const bundle = appPath(ctx);
  if (!exists(bundle)) fail(`${bundle} not found; run \`expo-ios build --configuration ${ctx.configuration}\` first`);
  const missing = missingCredentials(ctx);
  if (missing.length) fail(`expo-ios sign cannot run yet. Missing:\n  - ${missing.join('\n  - ')}`);
  const ipa = path.join(ctx.outDir, 'App.ipa');
  if (signsLocally()) {
    const dev = signingDir();
    const omarchy = ctx.tools.omarchy;
    if (!exists(path.join(dev, `${app.bundleId}.mobileprovision`)) || !exists(path.join(dev, 'key.pem'))) {
      const args = [path.join(omarchy, 'tools/provision-dev.py'), '--bundle-id', app.bundleId, '--out', dev];
      if (process.env.EXPO_IOS_DEVICE_UDID) args.push('--udid', process.env.EXPO_IOS_DEVICE_UDID);
      run('python3', args, { env: ctx.env });
    }
    run('bash', [path.join(omarchy, 'tools/sign-dev.sh'), bundle, ipa, dev], { env: ctx.env });
  } else {
    info(`signing ${app.bundleId} on the srv host (iphone sign)`);
    run('iphone', ['sign', bundle, '-o', ipa], { env: ctx.env });
  }
  const lint = machoLint(ctx, ipa, { signed: true });
  info(`signed ${ipa}${lint ? ` (${lint})` : ''}`);
  return ipa;
}

export function install(ctx, { launch = false, consoleSeconds = 25 } = {}) {
  const app = readAppSettings(ctx);
  const ipa = path.join(ctx.outDir, 'App.ipa');
  const missing = missingCredentials(ctx, { forInstall: true });
  if (!exists(ipa)) missing.unshift(`${ipa} (run \`expo-ios sign --configuration ${ctx.configuration}\`)`);
  if (missing.length) fail(`expo-ios install cannot run yet. Missing:\n  - ${missing.join('\n  - ')}`);
  run('iphone', ['install', ipa], { cwd: ctx.outDir, env: ctx.env });
  if (launch) run('iphone', ['launch', app.bundleId, '--console', String(consoleSeconds)], { cwd: ctx.outDir, env: ctx.env });
}
