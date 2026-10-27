// Shared helpers: logging, subprocesses, filesystem.
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { createRequire } from 'node:module';

export class BuildError extends Error {}

export function fail(message) {
  throw new BuildError(message);
}

let stageStart = 0;
export function stage(name) {
  stageStart = Date.now();
  process.stderr.write(`\n== ${name}\n`);
}
export function stageDone(name) {
  const s = ((Date.now() - stageStart) / 1000).toFixed(1);
  process.stderr.write(`   ${name}: ${s}s\n`);
  return Number(s);
}
export function info(msg) {
  process.stderr.write(`   ${msg}\n`);
}
export function warn(msg) {
  process.stderr.write(`warning: ${msg}\n`);
}

/**
 * Run a command. Output goes to `log` (a file path) when given, else inherits.
 * Fails loudly with the tail of the log on a non-zero exit.
 */
export function run(cmd, args, { cwd, env, log, input, capture = false, allowFail = false } = {}) {
  const opts = { cwd, env: env ?? process.env, maxBuffer: 512 * 1024 * 1024, input };
  let res;
  if (log && !capture) {
    // Stream into the log so long stages (compile) can be followed with `tail -f`.
    fs.mkdirSync(path.dirname(log), { recursive: true });
    fs.appendFileSync(log, `$ ${[cmd, ...args].join(' ')}\n`);
    const start = fs.statSync(log).size;
    const fd = fs.openSync(log, 'a');
    try {
      res = spawnSync(cmd, args, { ...opts, stdio: [input === undefined ? 'ignore' : 'pipe', fd, fd] });
    } finally {
      fs.closeSync(fd);
    }
    res.stdout = fs.readFileSync(log).subarray(start).toString('utf8');
    res.stderr = '';
    fs.appendFileSync(log, '\n');
  } else if (capture || log) {
    res = spawnSync(cmd, args, { ...opts, encoding: 'utf8' });
    if (log) {
      fs.mkdirSync(path.dirname(log), { recursive: true });
      fs.appendFileSync(log, `$ ${[cmd, ...args].join(' ')}\n${res.stdout ?? ''}${res.stderr ?? ''}\n`);
    }
  } else {
    res = spawnSync(cmd, args, { ...opts, stdio: ['inherit', 'inherit', 'inherit'] });
  }
  if (res.error) {
    if (allowFail) return res;
    fail(`${cmd}: ${res.error.message}`);
  }
  if (res.status !== 0 && !allowFail) {
    let detail = '';
    if (capture || log) {
      const text = `${res.stdout ?? ''}${res.stderr ?? ''}`.trimEnd().split('\n');
      const errors = text.filter((l) => /error[:\]]/i.test(l));
      detail = '\n' + (errors.length ? errors.slice(0, 60) : text.slice(-60)).join('\n');
      if (log) detail += `\n(full log: ${log})`;
    }
    fail(`command failed (exit ${res.status}): ${[cmd, ...args].join(' ')}${detail}`);
  }
  return res;
}

export function exists(p) {
  return fs.existsSync(p);
}

export function readJSON(p) {
  return JSON.parse(fs.readFileSync(p, 'utf8'));
}

export function writeJSON(p, value) {
  fs.mkdirSync(path.dirname(p), { recursive: true });
  fs.writeFileSync(p, JSON.stringify(value, null, 2) + '\n');
}

/** Write only when the contents differ, so SwiftPM's incremental build keeps its state. */
export function writeIfChanged(p, contents) {
  if (fs.existsSync(p) && fs.readFileSync(p, 'utf8') === contents) return false;
  fs.mkdirSync(path.dirname(p), { recursive: true });
  fs.writeFileSync(p, contents);
  return true;
}

export function rmrf(p) {
  if (!fs.existsSync(p) && !isSymlink(p)) return;
  // SwiftPM outputs can be read-only.
  spawnSync('chmod', ['-R', 'u+w', p]);
  fs.rmSync(p, { recursive: true, force: true });
}

export function isSymlink(p) {
  try {
    return fs.lstatSync(p).isSymbolicLink();
  } catch {
    return false;
  }
}

export function mkdirp(p) {
  fs.mkdirSync(p, { recursive: true });
  return p;
}

/** cp -R preserving symlinks (frameworks use them on macOS; iOS ones are flat). */
export function copyTree(src, dest) {
  run('cp', ['-R', '--no-preserve=ownership', src, dest]);
}

export function sha256File(p) {
  return crypto.createHash('sha256').update(fs.readFileSync(p)).digest('hex');
}

export function sha256(text) {
  return crypto.createHash('sha256').update(text).digest('hex');
}

/** All files under `dir` (relative paths), following no symlinked directories. */
export function walk(dir, { followSymlinks = false } = {}) {
  const out = [];
  const visit = (rel) => {
    const abs = path.join(dir, rel);
    for (const ent of fs.readdirSync(abs, { withFileTypes: true })) {
      const r = rel ? `${rel}/${ent.name}` : ent.name;
      let isDir = ent.isDirectory();
      if (ent.isSymbolicLink() && followSymlinks) {
        try {
          isDir = fs.statSync(path.join(dir, r)).isDirectory();
        } catch {
          continue;
        }
      }
      if (isDir) visit(r);
      else out.push(r);
    }
  };
  if (fs.existsSync(dir)) visit('');
  return out.sort();
}

/**
 * Minimal glob → RegExp for patterns used by spm.config.json and our contract:
 * `**`, `*`, `?`, `{a,b}`. Matches relative POSIX paths.
 */
export function globToRegExp(glob) {
  let re = '';
  for (let i = 0; i < glob.length; i++) {
    const c = glob[i];
    if (c === '*') {
      if (glob[i + 1] === '*') {
        // `**/` matches zero or more directories; a trailing `**` matches everything.
        if (glob[i + 2] === '/') {
          re += '(?:.*/)?';
          i += 2;
        } else {
          re += '.*';
          i += 1;
        }
      } else {
        re += '[^/]*';
      }
    } else if (c === '?') re += '[^/]';
    else if (c === '{') {
      const end = glob.indexOf('}', i);
      const alts = glob.slice(i + 1, end).split(',').map((a) => a.replace(/[.+^$()|[\]\\]/g, '\\$&'));
      re += `(?:${alts.join('|')})`;
      i = end;
    } else re += c.replace(/[.+^$()|[\]\\]/g, '\\$&');
  }
  return new RegExp(`^${re}$`);
}

export function matchesAny(rel, globs) {
  return globs.some((g) => globToRegExp(g).test(rel));
}

/** Resolve an npm package's directory from the project root (hoisting-aware). */
export function resolvePackageDir(projectRoot, name) {
  const direct = path.join(projectRoot, 'node_modules', name);
  if (fs.existsSync(path.join(direct, 'package.json'))) return fs.realpathSync(direct);
  try {
    const req = createRequire(path.join(projectRoot, 'package.json'));
    return path.dirname(req.resolve(`${name}/package.json`));
  } catch {
    return null;
  }
}

export function packageVersion(dir) {
  return readJSON(path.join(dir, 'package.json')).version;
}

export function shellQuote(s) {
  return /^[\w@%+=:,./-]+$/.test(s) ? s : `'${String(s).replace(/'/g, `'\\''`)}'`;
}
