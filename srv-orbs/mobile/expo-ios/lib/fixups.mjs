// Built-in Linux fixups for Expo SDK 58 / RN 0.88 node_modules (research gaps 2–5).
// Each fixup is idempotent and version tolerant: it looks for the upstream text,
// or for its own already-applied text, and fails the build when it finds neither.
import fs from 'node:fs';
import path from 'node:path';
import { fail, info, isSymlink, resolvePackageDir } from './util.mjs';

/** Replace `from` with `to` in `file`; `marker` proves an earlier run applied it. */
function replaceOnce(file, from, to, marker, label) {
  const text = fs.readFileSync(file, 'utf8');
  if (text.includes(marker)) return false;
  if (!text.includes(from)) {
    fail(`fixup "${label}": anchor not found in ${file}; the package changed, update lib/fixups.mjs`);
  }
  fs.writeFileSync(file, text.split(from).join(to));
  info(`fixup ${label}: ${file}`);
  return true;
}

// Gap 2: expo-modules-autolinking only runs the @ExpoModule scanner on macOS. The
// linux-x64 scanner ships as @expo/modules-macros-linux-x64 and works.
function scannerOnLinux(root) {
  const dir = resolvePackageDir(root, 'expo-modules-autolinking');
  if (!dir) fail('expo-modules-autolinking is not installed');
  const file = path.join(dir, 'build/platforms/apple/apple.js');
  replaceOnce(
    file,
    "if (process.platform !== 'darwin') {\n        return null;",
    "if (process.platform !== 'darwin' && process.platform !== 'linux') { // expo-ios: Linux scanner\n        return null;",
    'expo-ios: Linux scanner',
    'autolinking-scanner-linux'
  );
}

// The @ExpoModule scanner gets 5 s; the Linux build in a busy orb (cold page cache,
// parallel SwiftPM work) can take longer, which drops ExpoModulesCore's modules from
// the provider and fails the sync. Give it a minute.
function scannerTimeout(root) {
  const dir = resolvePackageDir(root, 'expo-modules-autolinking');
  replaceOnce(
    path.join(dir, 'build/platforms/apple/moduleScanner.js'),
    'timeout: 5000',
    'timeout: 60000 /* expo-ios: Linux scanner */',
    'expo-ios: Linux scanner',
    'autolinking-scanner-timeout'
  );
}

// Gap 5 helper / Release dev-client exclusion: EXPO_IOS_AUTOLINKING_EXCLUDE (comma
// separated) joins expo.autolinking.exclude for every autolinking command.
function excludeFromEnv(root) {
  const dir = resolvePackageDir(root, 'expo-modules-autolinking');
  const file = path.join(dir, 'build/commands/autolinkingOptions.js');
  replaceOnce(
    file,
    "const extraExclude = args.exclude?.filter((name)=>typeof name === 'string');",
    "const extraExclude = [ ...(args.exclude ?? []), ...(process.env.EXPO_IOS_AUTOLINKING_EXCLUDE ?? '').split(',').map((s)=>s.trim()).filter(Boolean) ].filter((name)=>typeof name === 'string'); // expo-ios: env exclude",
    'expo-ios: env exclude',
    'autolinking-exclude-env'
  );
}

// Gap 3: the SwiftPM plugin passes expo-modules-macros/apple/ExpoModulesMacros (a
// Mach-O) to -load-plugin-executable. Point that path at the Linux build.
function linuxMacroPlugin(root) {
  const macros = resolvePackageDir(root, 'expo-modules-macros');
  if (!macros) fail('expo-modules-macros is not installed');
  const linuxPkg = resolvePackageDir(macros, '@expo/modules-macros-linux-x64') ?? resolvePackageDir(root, '@expo/modules-macros-linux-x64');
  if (!linuxPkg) fail('@expo/modules-macros-linux-x64 is not installed (optional dependency skipped? reinstall without --omit=optional)');
  const linuxBin = path.join(linuxPkg, 'ExpoModulesMacros');
  if (!fs.existsSync(linuxBin)) fail(`missing ${linuxBin}`);
  const tool = path.join(macros, 'apple', 'ExpoModulesMacros');
  if (isSymlink(tool) && fs.realpathSync(tool) === fs.realpathSync(linuxBin)) return;
  if (fs.existsSync(tool) && !isSymlink(tool)) fs.renameSync(tool, `${tool}.macos`);
  else if (isSymlink(tool)) fs.unlinkSync(tool);
  fs.symlinkSync(linuxBin, tool);
  fs.chmodSync(linuxBin, 0o755);
  info(`fixup macro-plugin-linux: ${tool} -> ${linuxBin}`);
}

// Gap 4: CoreFoundation's CFGetTypeID/CFBooleanGetTypeID are missing from Linux
// Foundation, so these manifests do not compile on the build host.
function cfBooleanCheck(root) {
  for (const name of ['react-native-reanimated', 'react-native-worklets']) {
    const dir = resolvePackageDir(root, name);
    if (!dir) continue;
    const file = path.join(dir, 'Package.swift');
    if (!fs.existsSync(file)) continue;
    const text = fs.readFileSync(file, 'utf8');
    if (!text.includes('CFGetTypeID') && !text.includes('expo-ios: objCType')) continue;
    replaceOnce(
      file,
      'if CFGetTypeID(number) == CFBooleanGetTypeID() {',
      'if String(cString: number.objCType) == "c" { // expo-ios: objCType',
      'expo-ios: objCType',
      `${name}-cfboolean`
    );
  }
}

export function applyFixups(root) {
  scannerOnLinux(root);
  excludeFromEnv(root);
  scannerTimeout(root);
  linuxMacroPlugin(root);
  cfBooleanCheck(root);
}

// Gap 5: `setup-apple-spm.js scaffold` writes manifests whose public-headers dir
// holds an umbrella header next to sub-directories, which SwiftPM rejects with
// "invalid header layout". A module.modulemap in that dir replaces SwiftPM's
// inference with the module it would have inferred. Returns the files written.
export function fixScaffoldedHeaderLayouts(errors) {
  const fixed = [];
  for (const { target, umbrella } of errors) {
    const modulemap = path.join(path.dirname(umbrella), 'module.modulemap');
    if (fs.existsSync(modulemap)) fail(`${modulemap} exists but SwiftPM still reports an invalid header layout for ${target}`);
    fs.writeFileSync(
      modulemap,
      `// expo-ios: explicit module map (scaffolded header layout, research gap 5)\nmodule ${target} {\n  umbrella header "${path.basename(umbrella)}"\n  export *\n}\n`
    );
    info(`fixup modulemap: ${modulemap}`);
    fixed.push(modulemap);
  }
  return fixed;
}
