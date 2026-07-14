# Implementation plan — harness-agnostic discovery

> Companion to the design: `docs/research/harness-agnostic-discovery-design.md` (16-agent workflow,
> red-team ship-with-fixes). This plan sequences the BUILD. Conventions: completed phases compact to
> learnings+hashes; upcoming phases stay expanded.

**Scope (frozen):** build machine-wide, harness-agnostic agent discovery for `agent-secrets` —
single rule renderer + data-driven surface registry; dedicated `~/.claude/rules/agent-secrets.md`
(covers Claude Code **and** VS Code Copilot); broader rows Codex / Gemini / Zed / Cline; names-only
`agent-secrets mcp` server + Cursor registration; per-surface `doctor` coverage table (hash-verify,
permanent Cursor row, **advisory/not-enforced** labeling); the §3 shipped-bug fixes; macOS-first with
per-OS resolvers carried in the registry schema. **Out of scope (user decisions 2026-07-14):** no
PreToolUse enforcement hook (discovery-only/advisory); Windsurf deferred (path churn); Windows/Linux
code ships later (schema ready now).

**User decisions locked (2026-07-14):** full scope incl. broader harnesses · discovery-only (advisory,
never claims a hard guarantee) · MCP complement for Cursor = YES.

---

## Phase 0 — orchestration

**Shape of the work:** this is largely ONE subsystem (the discovery mechanism) with heavy coupling
through shared core files (`lib/common.sh`, `lib/manifest.sh`, `install.sh`, `cmd/doctor.sh`). Per the
Category-B rule (single-subsystem, depth-coordinated → single coherent implementer wins) the coupled
core is **lead-solo**; only the genuinely separable leaves are teamed.

| Wave | Work | Owner | Depends on | Isolation |
|---|---|---|---|---|
| ~~W1~~ ✅ | Foundation: single renderer, drift kill, rule-#3 reword (`add.sh` gate descoped) | **lead** | — | repo root · `b23fbdc` |
| ~~W2~~ ✅ | Manifest: per-surface marker style (md/sh) + dual-strip + mode preserve (backup/lock deferred) | **lead** | W1 | repo root · `0b5bda9` |
| **W3** | Surface registry `lib/discovery.sh` + Claude rules-file row + Copilot coverage detection | **lead** | W2 | repo root |
| **W4a** | Broader rows: Codex, Gemini, Zed, Cline (follow W3 pattern) | teammate A | W3 | worktree |
| **W4b** | `cmd/mcp.sh` names-only MCP server + registration writers | teammate B | W2 (markers/manifest) | worktree |
| **W5** | `doctor` per-surface coverage table + advisory labeling | **lead** | W3, W4a | repo root |
| **W6** | Tests (per surface + regression locks) + docs (README who-reads-what, AGENTS.md, help) | teammate C + lead | W5 | worktree |

**Serialization:** W1→W2→W3 are strictly sequential (each edits the shared core the next builds on).
W4a/W4b fan out only AFTER W3 lands (they consume the registry + manifest primitives). Merge W4a/W4b
before W5. Single owner per shared file: **lead owns `manifest.sh`, `common.sh`, `install.sh`,
`doctor.sh`**; teammates own only NEW files (`lib/discovery-rows-broader.sh` fragment, `cmd/mcp.sh`) +
their own test files.

**Green gate every wave:** `bats tests/` must stay green (198 baseline). Any wave that changes shipped
rule text or markers updates the locking tests IN THE SAME COMMIT.

---

## Phase 1 (W1) — Foundation — DONE (`b23fbdc`, 2026-07-14)

Single renderer `agsec_render_rules <plain|claude-md>` in `lib/common.sh` is now the SOLE rule source;
`agsec_agent_rules` aliases `plain`; `install.sh:280` renders the CLAUDE.md block via `claude-md`; the
drifted `_discovery_block` is deleted. Rule #3 reworded to drop the leak-prone `printf %s "$VALUE" | add`
example. 198/198 green, shellcheck clean.

**Key learnings:**
- `install.sh` sources `lib/common.sh` at line 202 (before the discovery write at 280), so the renderer
  is a clean single-source — no data-file indirection needed. That is why the drift was *fixable*, not
  structural.
- **`add.sh` session-guard DESCOPED (evidence-based).** `add` is already argv-safe (name on argv, value
  on STDIN only), so it *cannot* prevent the §3.2 leak — the literal lands in the agent's `printf`
  command **upstream**, before `add.sh` runs. A guard there would be educational-only. The real §3.2 fix
  is the rule-text reword (done). Revisit only if stricter behavior is explicitly wanted.
- **`CLAUDECODE=1` is set in the dev shell** → `bats` runs with `agsec_in_agent_session` **true** (and
  `store.bats` pipes `agsec add` ~8×). Any future agent-session guard must not fire spuriously here — a
  second reason the `add.sh` guard was wrong. Tests rely on `AGENT_SECRETS_UNATTENDED=1` to bypass the
  `setup` ceremony refusal under this condition.
- No test asserts the `claude-md` block *body* (only the `plain` output via `agsec_agent_rules`), so the
  markdown block was free to unify. Test-locked substrings preserved: `"NEVER write a secret to a .env"`,
  `"agent-secrets run -- <cmd>"`.

---

## Phase 2 (W2) — Manifest hardening + marker migration — DONE (`0b5bda9`, 2026-07-14)

`manifest_pathblock_install <file> <marker> <line> [style=sh]` now takes a per-surface marker style:
`sh` (`# >>>`, shell rc) or `md` (`<!-- >>> … -->`, markdown surfaces, so no H1-heading pollution).
`_manifest_strip_block` matches BOTH styles unconditionally → legacy `#` blocks and new `md` blocks
both strip clean (dual-marker strip is PERMANENT). Mode preserved across the rewrite. Record gains a
stable `style` field. 201/201 green (+3 locks: `W2-MD`, `W2-DUAL`, `W2-MODE`).

**Key decisions / learnings:**
- **No content hash in the record** (dropped the planned `body_sha256`). A per-version hash would break
  the move-to-tail dedup (`_manifest_append` compares whole records) — a changed hash leaves TWO
  pathblock records for one file. doctor detects a STALE block by **content-comparing** the installed
  block body to the current `agsec_render_rules` output instead (W5). Simpler and dedup-safe.
- **Clobber pre-write-backup + lock DEFERRED (evidence-based, not skipped).** The red-team itself noted a
  tool-side lock only serializes the tool against ITSELF — it cannot stop Claude Code's own `#`/`/memory`
  writes to CLAUDE.md. W3 moves the high-traffic Claude surface OFF CLAUDE.md to a dedicated
  `~/.claude/rules/agent-secrets.md` (whole-file `manifest_record_file` create — no shared-file
  read-modify-write, so the race is *gone* for the file that mattered). Remaining shared-file surfaces
  (Codex `AGENTS.md`, Gemini `GEMINI.md`) have low concurrent-write risk. Mode-preserve + atomic
  `.new`+rename + write-through-symlink already cover the practical case. Revisit if a shared-surface
  clobber is ever observed. **`doctor` dual-marker grep also deferred to W5** (the discovery block still
  uses `sh` markers until W3 moves it; W5 rewrites `check_discovery` wholesale anyway).

---

## Phase 3 (W3) — Surface registry + Claude/Copilot rows — EXPANDED

- New `lib/discovery.sh`: the data-driven registry. Each row =
  `{harness, path_resolver_fn, renderer_format, marker, marker_style, gate_fn (tool dir/binary present),
  session_marker, max_bytes, doctor_label, verified_on, os_paths{macos,linux,windows}}`.
- `install` / `uninstall` / `doctor` iterate the registry (replace the single hardcoded CLAUDE.md block
  in install.sh:266-285 with a registry loop; keep the per-surface consent prompt + `[ -t 0 ]` skip).
- **Claude Code row:** target `${CLAUDE_CONFIG_DIR:-~/.claude}/rules/agent-secrets.md` (dedicated file,
  `manifest_record_file` created — uninstall=delete, no clobber). Honor `CLAUDE_CONFIG_DIR`.
- **Copilot row (per-READER, separate from Claude):** checks the LITERAL `~/.claude/rules/` (VS Code
  hardcodes `~/.claude`, ignores `CLAUDE_CONFIG_DIR`); when the two diverge, report/write both. Detect
  effective `chat.useClaudeMdFile`; fallback `~/.copilot/instructions/agent-secrets.instructions.md`
  (needs `applyTo:'**'` frontmatter).
- Consent copy names the readers ("Claude Code + VS Code Copilot + any CLAUDE.md-compatible tool").

## Phase 4 (W4a/W4b) — Broader rows + MCP — EXPANDED

- **W4a rows** (registry additions, gated on tool dir existing; each carries verified path + max_bytes):
  Codex `${CODEX_HOME:-~/.codex}/AGENTS.md` (detect `AGENTS.override.md`; 32 KiB cap) · Gemini
  `~/.gemini/GEMINI.md` · Zed `~/.config/zed/AGENTS.md` · Cline `~/.agents/AGENTS.md` (verify shipped
  on-target). Each row pairs a `session_marker`; rows lacking one surface `detection: none` in doctor.
- **W4b MCP server** `cmd/mcp.sh`: stdio MCP exposing names-only tools (`list`, `doctor`, `help --json`)
  — **NEVER returns a secret value**. Registration writers merge into `~/.cursor/mcp.json`,
  VS Code user `mcp.json`, and `claude mcp add --scope user` (JSON-merge via jq + backup, consent-gated,
  manifest-recorded). Dispatcher gets an `mcp` verb.

## Phase 5 (W5) — doctor coverage table — EXPANDED

- Replace `check_discovery` (doctor.sh:225-231) with a per-surface, per-reader table:
  `present/in-sync · STALE · HAND-EDITED · absent`, hub effective-setting read, **permanent
  `cursor: UNVERIFIABLE — paste once` row**, advisory labeling ("discovery is advisory, not enforced").
  Promote discovery out of the summary-hidden optional tier to visible `attn` when absent. Add
  `agent-secrets discovery {status,install}` + `mcp {status}` subcommands.

## Phase 6 (W6) — tests + docs

- Per-surface tests, marker back-compat locks, MCP names-only test (assert no value ever emitted),
  registry-iteration tests. Docs: correct the README who-reads-what table (VS Code covered via
  `~/.claude/rules`), AGENTS.md machine-wide section, `help` topics; label everything advisory.

---

## Known back-compat hazards (carry forward)
- Marker migration: dual-strip must be permanent OR records migrated on first v2 run.
- `CLAUDE_CONFIG_DIR` split: Claude Code vs Copilot read different paths — per-reader rows, not per-file.
- Dotfiles sync: self-guard "ignore unless `<abs-path>` exists AND `doctor` succeeds" line + `# synced-from` provenance.
- Windsurf 6 KB / Codex 32 KiB caps: registry `max_bytes`, refuse-and-report before crossing.
