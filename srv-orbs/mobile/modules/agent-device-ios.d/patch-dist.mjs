#!/usr/bin/env node
// Patches agent-device's bundled dist (pinned version) so its Apple backend runs on Linux when
// AGENT_DEVICE_IOS_BROKER=1 (set by the agent-device wrapper): device discovery skips the
// "Apple tools are only available on macOS" refusal and lists physical devices only (no
// simulators, no host Mac). Every other Apple path already goes through xcrun / xcodebuild /
// plutil, which /opt/agent-device-ios/bin stands in for.
//
// usage: patch-dist.mjs /opt/agent-device   (idempotent; fails if a patch no longer applies)
import fs from 'node:fs';
import path from 'node:path';

const root = process.argv[2];
if (!root) {
  console.error('usage: patch-dist.mjs AGENT_DEVICE_DIR');
  process.exit(2);
}

const PATCHES = [
  {
    file: 'dist/src/inventory2.js',
    what: 'Apple discovery on Linux through the phone broker',
    from: 'if(n.hostOs!==`darwin`)throw B(n.hostOs);',
    to:
      'if(n.hostOs!==`darwin`){if(process.env.AGENT_DEVICE_IOS_BROKER!==`1`)throw B(n.hostOs);' +
      'return r.kind===`simulator`?[]:t(await k(n,i))}/*agent-device-ios*/',
  },
];

let failed = false;
for (const patch of PATCHES) {
  const file = path.join(root, patch.file);
  const text = fs.readFileSync(file, 'utf8');
  if (text.includes(patch.to)) {
    console.log(`patch-dist: already applied: ${patch.what}`);
    continue;
  }
  const count = text.split(patch.from).length - 1;
  if (count !== 1) {
    console.error(`patch-dist: ${patch.file}: expected 1 match for "${patch.what}", found ${count}`);
    failed = true;
    continue;
  }
  fs.writeFileSync(file, text.replace(patch.from, patch.to));
  console.log(`patch-dist: applied: ${patch.what}`);
}
process.exit(failed ? 1 : 0);
