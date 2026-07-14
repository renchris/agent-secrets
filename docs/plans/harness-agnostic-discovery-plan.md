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
| **W1** | Foundation: single renderer, drift kill, rule-#3 reword, `add.sh` gate | **lead** | — | repo root |
| **W2** | Manifest hardening: hash+version record, HTML markers + dual-marker strip, clobber hardening (backup/atomic/mode) | **lead** | W1 | repo root |
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

## Phase 1 (W1) — Foundation — EXPANDED

**Goal:** kill the already-shipped drift (§3.1) + the rule-#3 agent-leak (§3.2), establish the single
renderer everything else consumes. Lowest back-compat risk (no marker/schema change yet).

### 1a. Single renderer — `lib/common.sh`
- Add `agsec_render_rules <plain|claude-md>` as the SOLE rule data + envelope source.
  - `plain` → the 4 golden-rule lines currently in `agsec_agent_rules()` (common.sh:149-155).
  - `claude-md` → the markdown-wrapped block currently hand-maintained in `_discovery_block()`
    (install.sh:326-335) — now GENERATED from the same 4 lines + a markdown header.
- `agsec_agent_rules()` becomes a thin alias → `agsec_render_rules plain` (keep the name; `setup.sh`
  + tests call it).
- `install.sh` `_discovery_block()` becomes a thin alias → `agsec_render_rules claude-md` (delete the
  hand-maintained body — the drift seam).
- **Preserve test-locked substrings verbatim:** `"NEVER write a secret to a .env"`,
  `"agent-secrets run -- <cmd>"` (onboarding.bats:109-110,122; flows.bats:122).

### 1b. Rule #3 reword (agent-safe) — in the single renderer
- Current rule #3 tells agents `printf %s "$VALUE" | agent-secrets add NAME` — an agent substitutes the
  LITERAL secret into the Bash command → transcript leak.
- New agent-facing wording (both `plain` + `claude-md`): *"To add/rotate a secret, ask the USER to run
  `agent-secrets add <NAME>` in a real terminal — never place a secret value in a command."* Keep the
  human-facing STDIN form in `AGENTS.md`/`help` where the reader is a human, clearly labeled.

### 1c. `add.sh` session guard — `cmd/add.sh` (**DECISION: warn, don't refuse**)
- `add` via STDIN is a legitimate scriptable path — a hard refusal breaks automation. So: when
  `agsec_in_agent_session` is true AND stdin is a tty (interactive agent typing a value), emit a loud
  warning routing to a real terminal; when stdin is piped, proceed (the value is already off-argv) but
  print a one-line note that values must never be placed literally in a command. Rationale: preserves
  the scriptable pipe path, closes the "agent types the literal value" foot-gun.
- **Open sub-decision for the user:** if you'd rather `add` HARD-refuse inside an agent session
  (stricter, breaks pipe automation), say so — default is warn.

**W1 acceptance:** `agsec_render_rules plain` == old `agsec_agent_rules`; `claude-md` render contains
the locked substrings; no textual drift possible (one source); `add` warns in-agent; `bats tests/`
green (update discovery/onboarding/flows locks for the rule-#3 wording in the same commit).

---

## Phase 2 (W2) — Manifest hardening + marker migration — EXPANDED

Delicate: `lib/manifest.sh` is the most-tested file. Back-compat is mandatory (existing installs have
`# >>>` blocks + hash-less pathblock records).

- **Record schema:** extend `pathblock` record with `{body_sha256, rules_version}` (manifest.sh:77-80).
  `manifest_record_pathblock` gains params; `_manifest_append` unchanged.
- **HTML-comment markers:** `_manifest_block_begin/end` (manifest.sh:14-15) → emit
  `<!-- agent-secrets:begin -->` for markdown surfaces. **Keep `# >>>` for shell-rc surfaces**
  (`~/.zshenv`) — the marker style becomes a per-record field (`marker_style`), not a global. Store
  literal begin/end (or style) in the record so `_manifest_rb_pathblock` reconstructs the RIGHT pair
  (red-team: rollback must read the record, never the global function).
- **Dual-marker strip (permanent):** `_manifest_strip_block` recognizes BOTH `# >>>` and
  `<!-- agent-secrets:begin -->` forever (≈5 lines awk) so v1-installed machines uninstall cleanly.
  Update `doctor.sh` grep to dual-marker in the same commit.
- **Clobber hardening (§3.4):** in `manifest_pathblock_install` — timestamped pre-write backup into the
  manifest dir (bound to the hash gate), `mktemp`+atomic rename, `stat`/`chmod` mode preservation,
  `mkdir`-based lock (NOT `flock` — util-linux, absent on macOS). Keep write-through-symlink behavior
  (manifest.sh:20-24). On existing-block hash mismatch vs record → STOP-ASK (interactive) / refuse+report
  (non-tty): never silent-clobber a hand-edit.

**W2 acceptance:** existing `# >>>` installs strip clean; new installs use HTML markers; re-run is
idempotent + hash-stable; hand-edit is detected not clobbered; `bats tests/` green (+ new marker/back-compat locks).

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
