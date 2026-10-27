#!/usr/bin/env python3
"""dyld-style link closure check of an iOS .app on Linux.

For every Mach-O image in the bundle (executable, Frameworks/*.framework, Frameworks/*.dylib):
  * every LC_LOAD/REEXPORT/UPWARD dylib must resolve, @rpath through the image's (and the
    executable's) LC_RPATHs, to an embedded image or to a .tbd of the iOS SDK;
  * every undefined symbol must be exported (export trie / .tbd, re-exports followed) by
    the library its two-level-namespace ordinal names, or by any loaded image for
    flat-namespace lookups;
  * embedded images must carry an install name matching where they are embedded.
Weak imports that do not resolve are reported but not fatal (dyld binds them to 0).

usage: closure.py APP_BUNDLE --sdk IPHONEOS_SDK [--json OUT] [--cache DIR]
Exit status 0 when the closure is complete.
"""
import argparse
import hashlib
import json
import os
import plistlib
import re
import subprocess
import sys

LOAD_CMDS = ('LC_LOAD_DYLIB', 'LC_LOAD_WEAK_DYLIB', 'LC_REEXPORT_DYLIB', 'LC_LOAD_UPWARD_DYLIB', 'LC_LAZY_LOAD_DYLIB')
OBJC_PREFIXES = {
    'objc_class': ('_OBJC_CLASS_$_', '_OBJC_METACLASS_$_'),
    'objc_eh_type': ('_OBJC_EHTYPE_$_',),
    'objc_ivar': ('_OBJC_IVAR_$_',),
}


def sh(*args):
    r = subprocess.run(args, capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError(f"{' '.join(args)}: {r.stderr.strip()[:400]}")
    return r.stdout


def short_name(install_name):
    """llvm-nm -m's guess of a library's short name ("from X")."""
    base = os.path.basename(install_name)
    if '.framework/' in install_name:
        return re.sub(r'_(debug|profile)$', '', base)
    base = re.sub(r'\.dylib$', '', base)
    base = re.sub(r'_(debug|profile)$', '', base)
    return base.split('.')[0]


class Image:
    def __init__(self, path):
        self.path = path
        self.id = None
        self.loads = []  # (cmd, install name) in ordinal order
        self.rpaths = []
        self.platform = None
        self.minos = None
        cmd = None
        for line in sh('llvm-otool', '-l', path).splitlines():
            line = line.strip()
            if line.startswith('cmd '):
                cmd = line.split()[1]
            elif line.startswith('name ') and cmd in LOAD_CMDS + ('LC_ID_DYLIB',):
                name = line[5:].rsplit(' (offset', 1)[0]
                if cmd == 'LC_ID_DYLIB':
                    self.id = name
                else:
                    self.loads.append((cmd, name))
            elif line.startswith('path ') and cmd == 'LC_RPATH':
                self.rpaths.append(line[5:].rsplit(' (offset', 1)[0])
            elif line.startswith('platform ') and cmd == 'LC_BUILD_VERSION' and self.platform is None:
                self.platform = line.split()[1]
            elif line.startswith('minos ') and cmd == 'LC_BUILD_VERSION' and self.minos is None:
                self.minos = line.split()[1]
        self._exports = None

    def exports(self):
        if self._exports is None:
            self._exports = set()
            for line in sh('llvm-objdump', '--macho', '--exports-trie', self.path).splitlines():
                m = re.match(r'^\s*0x[0-9A-Fa-f]+\s+(\S+)', line)
                if m:
                    self._exports.add(m.group(1))
                    continue
                m = re.match(r'^\s*\[re-export\]\s+(\S+)', line)
                if m:
                    self._exports.add(m.group(1))
        return self._exports

    def imports(self):
        """[(symbol, from-short-name | None for flat lookup, weak)]"""
        out = []
        for line in sh('llvm-nm', '-m', '-u', self.path).splitlines():
            m = re.match(r'^\s*\(undefined\)\s+(weak\s+)?external\s+(\S+)(?:\s+\((?:from (\S+)|(dynamically looked up))\))?', line)
            if not m:
                continue
            out.append((m.group(2), m.group(3), bool(m.group(1))))
        return out


class Sdk:
    def __init__(self, root, cache):
        self.root = root
        self.cache = cache
        self.libs = {}  # install name -> {'exports': set, 'reexports': [names]}
        self.loaded_tbds = set()

    def _tbd_path(self, install_name):
        rel = install_name.lstrip('/')
        fw = re.match(r'^(.*\.framework)/(?:Versions/[^/]+/)?([^/]+)$', rel)
        if fw:
            cands = [os.path.join(self.root, fw.group(1), fw.group(2) + '.tbd')]
        else:
            stem = re.sub(r'\.dylib$', '', rel)
            cands = [os.path.join(self.root, stem + '.tbd')]
        return next((c for c in cands if os.path.exists(c)), None)

    def _load_tbd(self, tbd):
        if tbd in self.loaded_tbds:
            return
        self.loaded_tbds.add(tbd)
        key = hashlib.sha256(f'{tbd}:{os.path.getmtime(tbd)}'.encode()).hexdigest()[:24]
        cached = os.path.join(self.cache, key + '.json') if self.cache else None
        if cached and os.path.exists(cached):
            with open(cached) as f:
                doc = json.load(f)
        else:
            out = cached or '/dev/stdout'
            if cached:
                os.makedirs(self.cache, exist_ok=True)
                sh('llvm-readtapi', '--filetype=tbd-v5', tbd, '-o', out + '.tmp')
                os.replace(out + '.tmp', out)
                with open(out) as f:
                    doc = json.load(f)
            else:
                doc = json.loads(sh('llvm-readtapi', '--filetype=tbd-v5', tbd))
        for lib in [doc['main_library'], *doc.get('libraries', [])]:
            names = [n['name'] for n in lib.get('install_names', [])]
            exports = set()
            for section in ('exported_symbols', 'reexported_symbols'):
                for group in lib.get(section, []):
                    for kind in ('data', 'text'):
                        for k, syms in group.get(kind, {}).items():
                            if k in OBJC_PREFIXES:
                                for s in syms:
                                    exports.update(p + s for p in OBJC_PREFIXES[k])
                            else:
                                exports.update(syms)
            reexports = [n for group in lib.get('reexported_libraries', []) for n in group.get('names', [])]
            for n in names:
                self.libs[n] = {'exports': exports, 'reexports': reexports}

    def lib(self, install_name):
        if install_name not in self.libs:
            tbd = self._tbd_path(install_name)
            if tbd:
                self._load_tbd(tbd)
        if install_name not in self.libs and install_name in self.previous_index():
            # Only `$ld$previous` entries name it: symbols moved elsewhere, linked against
            # the old install name for older deployment targets (see previous()).
            self.libs[install_name] = {'exports': set(), 'reexports': []}
        return self.libs.get(install_name)

    def previous_index(self):
        """`$ld$previous$<install name>$<compat>$<platform>$<start>$<end>$<symbol>$` in any
        .tbd: for deployment targets in [start, end) ld links <symbol> against <install name>
        (Swift overlays merged into their frameworks: libswiftNetwork → Network.framework).
        -> {install name: {symbol: [[start, end], ...]}} for platform 2 (iOS)."""
        if getattr(self, '_previous', None) is not None:
            return self._previous
        settings = os.path.join(self.root, 'SDKSettings.json')
        stamp = f"{self.root}:{os.path.getmtime(settings) if os.path.exists(settings) else 0}"
        cached = os.path.join(self.cache, 'previous-' + hashlib.sha256(stamp.encode()).hexdigest()[:24] + '.json') if self.cache else None
        if cached and os.path.exists(cached):
            with open(cached) as f:
                self._previous = json.load(f)
            return self._previous
        # Swift symbols contain '$' themselves: the symbol runs to the '$' before the quote.
        pat = re.compile(rb'\$ld\$previous\$([^$]+)\$[^$]*\$(\d+)\$([\d.]+)\$([\d.]+)\$([^\'"\s,]+)\$[\'"]')
        index = {}
        for dirpath, _, files in os.walk(self.root):
            for fn in files:
                if not fn.endswith('.tbd'):
                    continue
                with open(os.path.join(dirpath, fn), 'rb') as f:
                    data = f.read()
                if b'$ld$previous$' not in data:
                    continue
                for m in pat.finditer(data):
                    if m.group(2) != b'2':
                        continue
                    rng = [m.group(3).decode(), m.group(4).decode()]
                    syms = index.setdefault(m.group(1).decode(), {})
                    if rng not in syms.setdefault(m.group(5).decode(), []):
                        syms[m.group(5).decode()].append(rng)
        if cached:
            os.makedirs(self.cache, exist_ok=True)
            with open(cached + '.tmp', 'w') as f:
                json.dump(index, f)
            os.replace(cached + '.tmp', cached)
        self._previous = index
        return index

    def previous(self, install_name, symbol, minos):
        """True if ld links `symbol` against `install_name` for deployment target `minos`."""
        v = version(minos)
        return any(version(a) <= v < version(b) for a, b in self.previous_index().get(install_name, {}).get(symbol, []))


def version(s):
    return tuple(int(x) for x in (s or '0').split('.'))


def bundle_images(app):
    with open(os.path.join(app, 'Info.plist'), 'rb') as f:
        info = plistlib.load(f)
    images = [os.path.join(app, info['CFBundleExecutable'])]
    frames = os.path.join(app, 'Frameworks')
    if os.path.isdir(frames):
        for ent in sorted(os.listdir(frames)):
            p = os.path.join(frames, ent)
            if ent.endswith('.framework'):
                fw_info = os.path.join(p, 'Info.plist')
                exe = ent[: -len('.framework')]
                if os.path.exists(fw_info):
                    with open(fw_info, 'rb') as f:
                        exe = plistlib.load(f).get('CFBundleExecutable', exe)
                images.append(os.path.join(p, exe))
            elif ent.endswith('.dylib'):
                images.append(p)
    return images


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('app')
    ap.add_argument('--sdk', required=True)
    ap.add_argument('--json')
    ap.add_argument('--cache', default=os.path.expanduser('~/.cache/expo-ios/tbd-json'))
    a = ap.parse_args()
    app = os.path.abspath(a.app)
    sdk = Sdk(a.sdk, a.cache)
    exe_path, *_ = bundle_images(app)
    images = {p: Image(p) for p in bundle_images(app)}
    exe = images[exe_path]
    errors, warnings = [], []
    report = {'app': app, 'sdk': a.sdk, 'images': {}}

    # Embedded images by the install name dyld would load them under.
    embedded = {}
    for p, img in images.items():
        if img is exe:
            continue
        rel = os.path.relpath(p, os.path.join(app, 'Frameworks'))
        expected = f'@rpath/{rel}'
        if img.id != expected:
            errors.append(f'{rel}: install name {img.id!r}, expected {expected!r}')
        embedded[expected] = img
        if img.id:
            embedded[img.id] = img
    for p, img in images.items():
        if img.platform not in ('2', 'IOS', 'iOS'):
            errors.append(f'{os.path.relpath(p, app)}: LC_BUILD_VERSION platform {img.platform}, not iOS')

    def resolve(img, name):
        """-> ('embedded', Image) | ('sdk', install name, lib) | None"""
        cands = [name]
        if name.startswith('@rpath/'):
            cands = []
            for rp in img.rpaths + [r for r in exe.rpaths if r not in img.rpaths]:
                rp = rp.replace('@executable_path', app).replace('@loader_path', os.path.dirname(img.path))
                cands.append(os.path.normpath(os.path.join(rp, name[len('@rpath/'):])))
        for c in cands:
            if c.startswith(app + '/'):
                rel = os.path.relpath(c, os.path.join(app, 'Frameworks'))
                if f'@rpath/{rel}' in embedded:
                    return ('embedded', embedded[f'@rpath/{rel}'])
                continue
            if name in embedded and c == name:
                return ('embedded', embedded[name])
            if c.startswith('/') and (c.startswith('/usr/lib/') or c.startswith('/System/')):
                lib = sdk.lib(c)
                if lib is not None:
                    return ('sdk', c, lib)
        return None

    def export_set(target, seen=None):
        seen = seen if seen is not None else set()
        if target[0] == 'embedded':
            img = target[1]
            if img.path in seen:
                return set()
            seen.add(img.path)
            out = set(img.exports())
            for cmd, n in img.loads:
                if cmd == 'LC_REEXPORT_DYLIB':
                    r = resolve(img, n)
                    if r:
                        out |= export_set(r, seen)
            return out
        name, lib = target[1], target[2]
        if name in seen:
            return set()
        seen.add(name)
        out = set(lib['exports'])
        for n in lib['reexports']:
            sub = sdk.lib(n)
            if sub is not None:
                out |= export_set(('sdk', n, sub), seen)
        return out

    export_cache = {}

    def exports_of(target):
        key = target[1].path if target[0] == 'embedded' else target[1]
        if key not in export_cache:
            export_cache[key] = export_set(target)
        return export_cache[key]

    host_rpaths = set()
    for p, img in images.items():
        rel_img = os.path.relpath(p, app)
        for rp in img.rpaths:
            if not (rp.startswith('@') or rp.startswith('/usr/lib') or rp.startswith('/System/')):
                host_rpaths.add(rp)
        targets = {}
        by_short = {}
        for cmd, n in img.loads:
            r = resolve(img, n)
            if r is None:
                (warnings if cmd == 'LC_LOAD_WEAK_DYLIB' else errors).append(f'{rel_img}: {cmd} {n} resolves to nothing embedded or in the SDK')
            targets[n] = r
            by_short.setdefault(short_name(n), []).append(n)
        imports = img.imports()
        unresolved, weak_missing, moved = [], [], []
        all_loaded = [t for t in targets.values() if t]
        for sym, frm, weak in imports:
            if frm is None:
                pool = all_loaded + [('embedded', i) for i in images.values() if i is not img]
            elif frm in ('executable',):
                pool = [('embedded', exe)]
            else:
                names = by_short.get(frm)
                if not names:
                    unresolved.append(f'{sym} (from {frm}: no such load command)')
                    continue
                pool = [targets[n] for n in names if targets[n]]
            if any(sym in exports_of(t) for t in pool):
                continue
            # A symbol that moved (`$ld$previous`) is linked against its old install name
            # for this image's deployment target, as ld64 does.
            if any(t[0] == 'sdk' and sdk.previous(t[1], sym, img.minos) for t in pool):
                moved.append(sym)
                continue
            (weak_missing if weak else unresolved).append(f'{sym} (from {frm or "flat lookup"})')
        report['images'][rel_img] = {
            'install_name': img.id,
            'platform': img.platform,
            'minos': img.minos,
            'loads': {n: (None if t is None else t[0] if t[0] == 'sdk' else 'embedded') for n, t in targets.items()},
            'imports': len(imports),
            'unresolved': unresolved,
            'weak_unresolved': weak_missing,
            'moved_symbols': len(moved),
        }
        if unresolved:
            errors.append(f'{rel_img}: {len(unresolved)} unresolved symbol(s): ' + ', '.join(unresolved[:8]) + (' …' if len(unresolved) > 8 else ''))
        if weak_missing:
            warnings.append(f'{rel_img}: {len(weak_missing)} weak import(s) not found (bound to NULL at runtime): ' + ', '.join(weak_missing[:5]))
    if host_rpaths:
        warnings.append('build-host LC_RPATHs (inert on device): ' + ', '.join(sorted(host_rpaths)))
    total = sum(v['imports'] for v in report['images'].values())
    total_moved = sum(v['moved_symbols'] for v in report['images'].values())
    report['summary'] = {
        'images': len(images),
        'imports': total,
        'moved_symbols': total_moved,
        'sdk_libraries_loaded': len(sdk.libs),
        'errors': errors,
        'warnings': warnings,
        'ok': not errors,
    }
    if a.json:
        with open(a.json, 'w') as f:
            json.dump(report, f, indent=2)
    for w in warnings:
        print(f'warning: {w}', file=sys.stderr)
    for e in errors:
        print(f'error: {e}', file=sys.stderr)
    print(f"closure: {len(images)} images, {total} undefined symbols checked ({total_moved} via $ld$previous), {len(errors)} error(s), {len(warnings)} warning(s)")
    sys.exit(0 if not errors else 1)


if __name__ == '__main__':
    main()
