// patches/ and overlays/ (contract: README.md "Contract: overlays, patches, hooks").
import fs from 'node:fs';
import path from 'node:path';
import { createRequire } from 'node:module';
import { HERE } from './context.mjs';
import { fail, info, packageVersion, readJSON, resolvePackageDir, run, walk } from './util.mjs';

const PATCHES = path.join(HERE, 'patches');
const OVERLAYS = path.join(HERE, 'overlays');

function excluded(ctx, name) {
  return ctx.exclude.includes(name);
}

function semverSatisfies(ctx, version, range) {
  let semver;
  try {
    semver = createRequire(path.join(ctx.projectRoot, 'package.json'))('semver');
  } catch {
    semver = createRequire(path.join(ctx.expo, 'package.json'))('semver');
  }
  return semver.satisfies(version, range, { includePrerelease: true });
}

/** `@expo+ui+58.0.23.patch` → { name: '@expo/ui', version: '58.0.23' } */
export function parsePatchName(file) {
  const base = file.replace(/\.patch$/, '');
  const i = base.lastIndexOf('+');
  if (i <= 0) fail(`bad patch file name ${file}: expected <package>+<version>.patch`);
  const rawName = base.slice(0, i);
  const name = rawName.startsWith('@') ? rawName.replace('+', '/') : rawName;
  return { name, version: base.slice(i + 1) };
}

export function applyPatches(ctx) {
  if (!fs.existsSync(PATCHES)) return [];
  const byName = new Map();
  for (const file of fs.readdirSync(PATCHES).filter((f) => f.endsWith('.patch')).sort()) {
    const p = parsePatchName(file);
    if (!byName.has(p.name)) byName.set(p.name, []);
    byName.get(p.name).push({ ...p, file: path.join(PATCHES, file) });
  }
  const applied = [];
  for (const [name, patches] of byName) {
    const dir = resolvePackageDir(ctx.projectRoot, name);
    if (!dir || excluded(ctx, name)) continue;
    const version = packageVersion(dir);
    const matching = patches.filter((p) => p.version === version);
    if (matching.length === 0) {
      fail(
        `patches exist for ${name} (${patches.map((p) => p.version).join(', ')}) but the installed version is ${version}. ` +
          `Port the patch to ${version} in ${PATCHES}, or exclude ${name} with EXPO_IOS_EXCLUDE.`
      );
    }
    for (const p of matching) {
      const already = run('patch', ['-p1', '-d', dir, '--dry-run', '-R', '-s', '-f', '-i', p.file], { capture: true, allowFail: true });
      if (already.status === 0) continue;
      const fwd = run('patch', ['-p1', '-d', dir, '--dry-run', '-s', '-f', '-i', p.file], { capture: true, allowFail: true });
      if (fwd.status !== 0) fail(`patch ${path.basename(p.file)} does not apply to ${dir}:\n${fwd.stdout}${fwd.stderr}`);
      run('patch', ['-p1', '-d', dir, '-s', '-f', '--no-backup-if-mismatch', '-i', p.file], { capture: true });
      info(`patched ${name}@${version}: ${path.basename(p.file)}`);
      applied.push(path.basename(p.file));
    }
  }
  return applied;
}

/** Overlay roots: overlays/<name>/ and overlays/@scope/<name>/. */
function overlayPackages() {
  if (!fs.existsSync(OVERLAYS)) return [];
  const out = [];
  for (const ent of fs.readdirSync(OVERLAYS, { withFileTypes: true })) {
    if (!ent.isDirectory()) continue;
    if (ent.name.startsWith('@')) {
      for (const sub of fs.readdirSync(path.join(OVERLAYS, ent.name), { withFileTypes: true })) {
        if (sub.isDirectory()) out.push(`${ent.name}/${sub.name}`);
      }
    } else out.push(ent.name);
  }
  return out.sort();
}

export function applyOverlays(ctx) {
  const applied = [];
  for (const name of overlayPackages()) {
    const root = path.join(OVERLAYS, name);
    const dir = resolvePackageDir(ctx.projectRoot, name);
    if (!dir || excluded(ctx, name)) continue;
    const metaFile = path.join(root, '.expo-ios.json');
    const meta = fs.existsSync(metaFile) ? readJSON(metaFile) : {};
    if (meta.configurations && !meta.configurations.includes(ctx.configuration)) continue;
    const version = packageVersion(dir);
    if (meta.versions && !semverSatisfies(ctx, version, meta.versions)) {
      fail(`overlay ${name} supports ${meta.versions} but ${version} is installed; update ${root}`);
    }
    let changed = 0;
    for (const rel of walk(root)) {
      if (rel === '.expo-ios.json') continue;
      const src = path.join(root, rel);
      const dest = path.join(dir, rel);
      const data = fs.readFileSync(src);
      if (fs.existsSync(dest) && fs.readFileSync(dest).equals(data)) continue;
      fs.mkdirSync(path.dirname(dest), { recursive: true });
      if (fs.existsSync(dest)) fs.chmodSync(dest, 0o644);
      fs.writeFileSync(dest, data, { mode: fs.statSync(src).mode & 0o777 });
      changed++;
    }
    if (changed) info(`overlay ${name}@${version}: ${changed} file(s)`);
    applied.push(name);
  }
  return applied;
}

/** Digest of everything we put into a package, so cached prebuilds see local changes. */
export function localChangesDigest(name) {
  const parts = [];
  const overlay = path.join(OVERLAYS, name);
  for (const rel of walk(overlay)) parts.push(rel, fs.readFileSync(path.join(overlay, rel), 'utf8'));
  if (fs.existsSync(PATCHES)) {
    for (const f of fs.readdirSync(PATCHES).sort()) {
      if (f.endsWith('.patch') && parsePatchName(f).name === name) parts.push(f, fs.readFileSync(path.join(PATCHES, f), 'utf8'));
    }
  }
  return parts.join('\0');
}
