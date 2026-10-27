#!/usr/bin/env bun
// Regenerates srv-orbs/agents/skills/pstack from upstream pstack (cursor/plugins). srv-orbs/agents/
// mirrors ~/.config/agents/ in the orb image, so the adapter links work there unchanged:
//   bun srv-orbs/agents/pstack/sync.ts [--ref <git ref>] [--source <cursor/plugins checkout>] [--check]
import {
  chmodSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, relative } from "node:path";

const UPSTREAM = "https://github.com/cursor/plugins";
const PORT = dirname(import.meta.path);
const OUT = join(PORT, "..", "skills", "pstack");
const SHOWN = "srv-orbs/agents/skills/pstack";
const ADAPTER = join(PORT, "amp.md");
const TREE = join("harness", "pstack", "claude-code");
const DROPPED = [/^plugin\.json$/u, /^\.claude-plugin\//u, /^docs\/guide\/images\//u];
const CLAUDE_LINE =
  /^In Claude Code, read \[the Claude Code adapter\]\([^)]*\) once per session before you follow this skill\. It maps the Cursor names in pstack skills to Claude Code\.$/mu;
const TYPED_ONLY =
  "pstack, typed-only. Load only when the user names this skill or a loaded pstack skill routes to it.";

type Entry = { bytes: Buffer; executable: boolean };

function option(name: string): string | undefined {
  const index = process.argv.indexOf(name);
  return index === -1 ? undefined : process.argv[index + 1];
}

function run(command: string[], cwd: string): string {
  const child = Bun.spawnSync(command, { cwd, stderr: "pipe", stdout: "pipe" });
  if (child.exitCode !== 0) {
    throw new Error(
      `${command.join(" ")} failed in ${cwd}:\n${child.stdout.toString()}${child.stderr.toString()}`,
    );
  }
  return child.stdout.toString().trim();
}

// `--check` compares against the revision the tree was generated from, so a new upstream commit is not drift.
function pinnedRevision(): string | undefined {
  const generated = join(OUT, "GENERATED.md");
  if (!existsSync(generated)) return undefined;
  return /\/tree\/([0-9a-f]{40})\//u.exec(readFileSync(generated, "utf8"))?.[1];
}

function checkout(): string {
  const source = option("--source");
  if (source) return source;
  const ref =
    option("--ref") ?? (process.argv.includes("--check") ? pinnedRevision() : undefined) ?? "main";
  const directory = mkdtempSync(join(tmpdir(), "pstack-upstream-"));
  run(["git", "init", "--quiet"], directory);
  run(["git", "fetch", "--quiet", "--depth", "1", `${UPSTREAM}.git`, ref], directory);
  run(["git", "checkout", "--quiet", "FETCH_HEAD"], directory);
  return directory;
}

function walk(directory: string): string[] {
  return readdirSync(directory).flatMap((name) => {
    const path = join(directory, name);
    return statSync(path).isDirectory() ? walk(path) : [path];
  });
}

function entry(path: string): Entry {
  return { bytes: readFileSync(path), executable: (statSync(path).mode & 0o111) !== 0 };
}

// Amp lists every discovered skill to the model and has no typed-only flag, so the description carries the gate.
function gateDescription(text: string, path: string): string {
  const match = /^---\n([\s\S]*?)\n---\n/u.exec(text);
  if (!match?.[1]) throw new Error(`${path} has no frontmatter`);
  const frontmatter = Bun.YAML.parse(match[1]) as Record<string, unknown>;
  if (frontmatter["disable-model-invocation"] !== true) return text;
  const lines = Object.entries({
    ...frontmatter,
    description: `${TYPED_ONLY} ${String(frontmatter["description"])}`,
  }).map(([key, value]) => `${key}: ${JSON.stringify(value)}`);
  return `---\n${lines.join("\n")}\n---\n${text.slice(match[0].length)}`;
}

function render(upstream: string, revision: string): Map<string, Entry> {
  const tree = join(upstream, TREE);
  const files = new Map<string, Entry>();
  let wrapped = 0;
  for (const path of walk(tree)) {
    const name = relative(tree, path);
    if (DROPPED.some((pattern) => pattern.test(name))) continue;
    const file = entry(path);
    if (name.endsWith(".md")) {
      let text = file.bytes.toString("utf8");
      if (name.endsWith("/SKILL.md")) {
        if (CLAUDE_LINE.test(text)) {
          const link = relative(dirname(join(OUT, name)), ADAPTER);
          text = text.replace(
            CLAUDE_LINE,
            `In Amp, read [the Amp adapter](${link}) once per thread before you follow this skill. It maps the Cursor names in pstack skills to Amp.`,
          );
          wrapped += 1;
        } else if (text.includes("In Claude Code, read [the Claude Code adapter]")) {
          throw new Error(`${name} has an adapter line this script does not recognize`);
        }
        text = gateDescription(text, name);
      }
      text = text.replaceAll(
        /\]\(\.\/images\/([^)]+)\)/gu,
        `](https://raw.githubusercontent.com/cursor/plugins/${revision}/pstack/docs/guide/images/$1)`,
      );
      file.bytes = Buffer.from(text);
    }
    files.set(name, file);
  }
  if (wrapped === 0)
    throw new Error(
      "No SKILL.md carried the Claude Code adapter line. The upstream layout changed.",
    );
  files.set("GENERATED.md", {
    bytes: Buffer.from(
      `# Generated pstack tree\n\nGenerated by \`bun srv-orbs/agents/pstack/sync.ts\` in srv-ops from ${UPSTREAM}/tree/${revision}/${TREE}. Do not edit by hand. Installed in the amp-orb image as ~/.config/agents/skills/pstack; see srv-ops \`srv-orbs/agents/pstack/README.md\`.\n`,
    ),
    executable: false,
  });
  return files;
}

const upstream = checkout();
const revision = run(["git", "rev-parse", "HEAD"], upstream);
// Upstream CI keeps the Claude Code tree in sync with pstack/; confirm before building on it.
run(["node", "scripts/generate-pstack-harness-trees.mjs", "--check"], upstream);
const rendered = render(upstream, revision);

if (process.argv.includes("--check")) {
  const onDisk = new Map(
    existsSync(OUT) ? walk(OUT).map((path) => [relative(OUT, path), entry(path)]) : [],
  );
  const drifted = [...new Set([...rendered.keys(), ...onDisk.keys()])]
    .toSorted((a, b) => a.localeCompare(b))
    .filter((path) => {
      const [want, have] = [rendered.get(path), onDisk.get(path)];
      return (
        !want || !have || !want.bytes.equals(have.bytes) || want.executable !== have.executable
      );
    });
  for (const path of drifted) console.log(`${SHOWN}/${path}`);
  if (drifted.length > 0) {
    console.log(`${SHOWN} differs from ${revision}. Run \`bun srv-orbs/agents/pstack/sync.ts\`.`);
    process.exit(1);
  }
  console.log(`${SHOWN} matches ${revision}.`);
} else {
  rmSync(OUT, { force: true, recursive: true });
  for (const [path, { bytes, executable }] of rendered) {
    mkdirSync(dirname(join(OUT, path)), { recursive: true });
    writeFileSync(join(OUT, path), bytes);
    chmodSync(join(OUT, path), executable ? 0o755 : 0o644);
  }
  const skills = [...rendered.keys()].filter((path) => path.endsWith("/SKILL.md")).length;
  console.log(`Wrote ${rendered.size} files (${skills} skills) from ${revision}.`);
}
