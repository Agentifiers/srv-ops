# pstack for Amp orbs

[pstack](https://github.com/cursor/plugins/tree/main/pstack) is Lauren Tan's set of engineering workflow skills, released under the MIT License. The `amp-orb` image installs it as user-level Amp skills, so every orb has it regardless of repository.

`srv-orbs/agents/` mirrors `/home/user/.config/agents/` in the image; `../build-image.sh` copies it there, owned by `user`.

| Path                                    | What it is                                                                                                                                       |
| --------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------ |
| `../skills/pstack/`                     | Generated copy of upstream's Claude Code tree: the skills, the two subagent prompts, the guide, and `LICENSE`. Do not edit it.                  |
| `amp.md`                                | The Amp adapter. Every pstack skill that uses Cursor names links to it (`../../../../pstack/amp.md`, which resolves to this file in the image). |
| `sync.ts`                               | Regenerates `../skills/pstack/` from upstream.                                                                                                   |

## Use

Ask for a skill by name, for example "use the poteto-mode skill to fix the flaky upload test". Amp has no slash commands for skills, and a loaded skill stays in context for the rest of the thread. Upstream marks most skills as typed-only. Amp lists every skill to the model, so `sync.ts` adds that rule to each typed-only skill's description instead.

Every subagent runs on the thread's model, because Amp's `Task` tool has no per-call model. Pick the model with the Amp mode picker, **Tune Modes**, or **Model Routing**. Review panels such as `interrogate` and `arena` still run independent subagents, but on one model. `setup-pstack` therefore only offers to create the verification skills. `amp.md` lists every mapping and every Cursor-only step that is skipped.

Repository rules still apply: `amp.md` tells the agent to follow each repository's `AGENTS.md`, including its required pre-commit checks.

## Update

From the srv-ops root:

```sh
bun srv-orbs/agents/pstack/sync.ts            # regenerate from upstream main
bun srv-orbs/agents/pstack/sync.ts --ref <sha>
bun srv-orbs/agents/pstack/sync.ts --check    # compare with the pinned revision in GENERATED.md
```

The script fetches `cursor/plugins` and confirms that upstream's Claude Code tree is current. It copies that tree, swaps each Claude Code adapter line for a link to `amp.md`, and gates the typed-only descriptions. It also points the guide's images at GitHub and drops the plugin manifests. It stops when a skill carries an adapter line in an unknown format. After an update, review the diff, check new Cursor names against `amp.md`, then rebuild the image (`sudo ../build-image.sh`). Existing orbs keep their old copy; new orbs get the update.
