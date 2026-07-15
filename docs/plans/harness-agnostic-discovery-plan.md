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
| ~~W3~~ ✅ | Surface registry `lib/discovery.sh` + Claude rules-file row + Copilot per-reader coverage | **lead** | W2 | repo root · `0b43917` |
| ~~W4a~~ ✅ | Broader rows: Codex, Gemini, Zed, Cline + per-surface byte-cap guard | **lead** | W3 | repo root · `02b3c62` |
| **W4b** ⚠️ | `cmd/mcp.sh` names-only MCP server + Cursor registration | **lead** | W2 | repo root — **BLOCKED, see below** |
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

## Phase 3 (W3) — Surface registry + Claude/Copilot rows — DONE (`0b43917`, 2026-07-14)

`lib/discovery.sh` is the data-driven registry (`_disc_row`/`_disc_gate`/`_disc_field` per key;
`agsec_discovery_write_key` / `agsec_discovery_install_all` / `agsec_discovery_status_key`). Claude
surface = dedicated `~/.claude/rules/agent-secrets.md` (whole file, `manifest_record_file` → uninstall
deletes it). `install.sh` sources it + drives the opt-in prompt via the registry; `doctor`'s
`check_discovery` iterates the registry, content-compares each surface to the current render
(in-sync/stale/absent), labels discovery **advisory, not enforced**. 204/204 green, shellcheck clean.

**Key decisions / learnings:**
- **Sandbox-safe resolvers are load-bearing.** `CLAUDE_CONFIG_DIR=~/.claude-secondary` is set in the dev
  shell and `test_helper` does NOT unset it — so `_disc_claude_dir` pins to `$AGENT_SECRETS_HOME/.claude`
  whenever `AGENT_SECRETS_HOME` is set (test/synthetic-home), honoring `CLAUDE_CONFIG_DIR`/`CODEX_HOME`
  only in production. Without this, tests would write to the real config dir.
- **Per-reader coverage:** Claude Code reads `$CLAUDE_CONFIG_DIR/rules`; VS Code Copilot reads the
  LITERAL `~/.claude/rules`. When they diverge the write goes to BOTH (each its own `manifest_record_file`).
  In the common case (var unset) and under tests they coincide → one file.
- **doctor uses content-comparison, not a hash** (see W2) — `agsec_discovery_status_key` diffs the
  installed file/block body against `agsec_render_rules <fmt>`.
- **`DISCOVERY_MARKER` removed from `install.sh`** (was dead after the registry switch) — the marker now
  has a single source: `AGENT_SECRETS_DISCOVERY_MARKER` in `common.sh`. discovery.bats test rewritten to
  assert that single-source by construction.
- **install tests build the tarball from `git archive HEAD`** (install.bats:12), so a new lib file must
  be COMMITTED before install tests can source it — commit W-with-new-lib before running the full suite.
- **Copilot fallback file + effective-`chat.useClaudeMdFile` detection deferred to W5/W6** — the dedicated
  `~/.claude/rules` file already covers Copilot by default; the `~/.copilot/instructions` fallback is only
  needed when the setting is off (a doctor-reported edge, not a v1 write).

## Phase 4a (W4a) — Broader rows — DONE (`02b3c62`, 2026-07-14)

Registry rows enabled for Codex `${CODEX_HOME:-~/.codex}/AGENTS.md`, Gemini `~/.gemini/GEMINI.md`, Zed
`~/.config/zed/AGENTS.md`, Cline `~/.agents/AGENTS.md` — each an md-marker block gated on the tool's
config dir existing (never fabricated), reversible. Per-surface byte-cap guard (Codex 32 KiB): an append
that would cross the cap is refused + reported, never a silent truncation. +2 locks. 206/206 green.

## Phase 4b (W4b) — names-only MCP server — ⚠️ BLOCKED (constraints discovered 2026-07-14)

**Status: NOT started — two constraints surfaced that change the planned path and warrant a user call.**

1. **`bin/` is permission-denied** in this environment (agent cannot read or edit `bin/agent-secrets`,
   the verb dispatcher). So the planned `agent-secrets mcp` VERB cannot be added cleanly.
   *Workaround (no bin/ needed):* ship `cmd/mcp.sh` as a **standalone, self-bootstrapping** script
   (resolves `AGENT_SECRETS_LIB` from its own path) that Cursor's `~/.cursor/mcp.json` invokes **by
   path** — Cursor does not need a verb. Registration + status move to the installer + a `discovery.sh`
   function + a `doctor` row (all editable). The verb is a human convenience, deferred pending bin/ access.
2. **Reversible registration into the NESTED `~/.cursor/mcp.json` key** hits the exact gap the red-team
   flagged: `manifest_record_edit`'s revert (`_manifest_rb_edit`) only `del`s a **top-level** key
   (`del(."$marker")`), but the MCP entry lives at `.mcpServers["agent-secrets"]`. Clean reversal needs
   EITHER (a) extend the edit-record to carry a jq PATH (more delicate `manifest.sh` surgery), OR (b) the
   coarse backup-restore (discards any post-install user edits to `mcp.json` — imperfect if the user
   added other MCP servers later).

**Design still valid:** `cmd/mcp.sh` = stdio JSON-RPC MCP exposing ONLY names-only tools (`list` /
`doctor` / `help --json`); NEVER exposes `run`/`add`/`share`/`receive` and never returns a value. That
core is unaffected by the constraints — only the wiring (verb → path-invocation) and reversibility path
change. **Note the bare-minimum a/b/c is ALREADY met without W4b:** Claude Code + VS Code via the rules
file (W3), Cursor via the existing clipboard (`setup` done-screen). W4b is the Cursor *file-automation*
enhancement the user opted into — real value, but beyond the required floor.

**Decision needed** (see session checkpoint): grant bin/ for the clean verb · accept standalone-script +
extend `manifest.sh` for nested-key reversal · accept standalone-script + coarse backup-restore · or
defer W4b (Cursor stays clipboard-covered).

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
- Dotfiles sync: self-guard "ignore unless `<abs-path>` exists" line + `# synced-from` provenance.
- Windsurf 6 KB / Codex 32 KiB caps: registry `max_bytes`, refuse-and-report before crossing.

---

# Phase C — composable, corporate-safe hardening (added 2026-07-14)

**Trigger:** user asked for the "100th-percentile, long-horizon, vulnerability-free-for-corporate"
decision. A 7-agent adversarial workflow (`wkst974ty`, verdict **"revised"**) + a 2-agent source/docs
cross-check settled the architecture. **SSOT for the verdict:** `docs/research/` (workflow output) + the
in-repo write-up below. **Guiding principle (user, 2026-07-14):** composable & applicable to ALL
environments (managed/unmanaged, any OS, tool-present/absent, writable/read-only) — general primitives,
NOT hardcoded corporate branches.

**The validated model — management-state-conditional, deference-first:**
1. **MCP = dropped from default, permanently.** Config-registration IS the RCE primitive regardless of
   names-only output (OX Security 2026; MCPoison CVE-2025-54136 name-trust swap; CurXecute CVE-2025-54135
   prompt-injection write→exec; Anthropic calls it "expected"/unpatched). Persistent EDR-visible process
   + settings-sync-propagated hijackable command reference + allowlist-policy collision. Never default;
   at most explicit opt-in, "unmanaged machines only," loud warning.
2. **On MANAGED machines → per-user installer writes NOTHING machine-wide; it DETECTS + DEFERS.** The
   machine-wide invariant, if any, is IT-deployed to the managed tier (managed `claudeMd` +
   `permissions.deny .env*`), which the tool SHIPS as a documented copy-paste fragment for Jamf/Intune —
   never auto-written (root/MDM paths are unwritable by design). Only the managed tier is centrally
   audited, tamper-protected, highest-precedence, and outranks a malicious repo's Project Rules.
3. **On UNMANAGED machines → inert advisory files as an opt-in FALLBACK**, framed as "advisory
   defense-in-depth, NEVER the security invariant." The `sops+age` store + Keychain custody remain the
   SOLE invariant carriers. **"Inert" is a category error** — an instruction file is executed-by-proxy at
   the agent's full privilege; sell it on auditability + reversibility + precedence-deference.

## HC1 — Copilot target fix + render hardening — DONE (`1c22228`, 2026-07-14)

VS Code Copilot does NOT read user-home `~/.claude/rules` by default on stable (source `main@52dde1f`
shows `true`, but the published/stable settings reference shows `false` — version skew; don't rely on
it). Only `~/.claude/CLAUDE.md` is default-read on every version (`chat.useClaudeMdFile=true`). So the
Claude+Copilot surface moved back to a `~/.claude/CLAUDE.md` md-comment block (W2 markers), per-reader
dual-write on `CLAUDE_CONFIG_DIR` divergence. Render is now: **abs-path-pinned** (anti PATH-hijack),
**self-guarded** (inert when synced to a tool-less machine), **version+integrity-marked**
(`agsec_block_integrity` → ok/tampered/unmarked), **graceful-degrade + false-green-fixed** (denied write
= skip; label only on a confirmed write), rule-3 routes value entry to a human terminal. README
corrected. 206 green. Key fact for HC: VS Code exposes NO `policy:` field on these settings → an org
cannot centrally disable CLAUDE.md ingestion via VS Code policy, only via MDM-pinned settings.

## HC2 — doctor integrity + honest coverage — EXPANDED (next)

- Wire `agsec_block_integrity` into `agsec_discovery_status_key`: emit `present-tampered` (embedded
  sha≠recompute → **flip `had_bad`/exit 1** + STOP-ASK wording) vs `present-stale` (integrity ok but
  embedded `version` < `agsec_version` → benign, "re-run installer") vs `present-in-sync`.
- Directory-level audit: enumerate the FULL loaded rules set + each shared `AGENTS.md`; flag any
  non-authored `agent-secrets`-marked block in an unexpected file, and any hidden-Unicode/bidi/zero-width
  char in a loaded instruction file (Rules-File-Backdoor / ATLAS AML-CS0041) → `bad` (exit 1).
- doctor rows for `managed layer present — deferring` and `denied/read-only — skipped` (no false green).
- Discovery integrity must affect exit code even under `--summary` (tampered is not `optional`).

## HC3 — managed-layer detect + defer — EXPANDED (composable, data-driven)

- New `_disc_managed_present <key>`: a GENERAL capability probe (data-driven per-surface managed paths in
  the registry, per-OS), returns 0 if a higher-precedence managed/policy layer exists — Claude Code
  managed `CLAUDE.md`/`managed-settings.json` (macOS `/Library/Application Support/ClaudeCode`, Linux
  `/etc/claude-code`, Windows `C:\Program Files\ClaudeCode`), `~/.claude/remote-settings.json`, VS Code /
  Cursor policy files. When present → SKIP the per-user machine-wide write + doctor "deferring" row.
  Registry rows carry `os_paths{macos,linux,windows}` + `managed_paths` from day one (composable across
  OSes even though v1 ships macOS behavior).

## HC4 — install consent + add.sh gate — EXPANDED

- Per-surface, per-file explicit consent naming each product/file (no one-keypress fan to six vendors);
  narrow the default to the Claude surface, broader rows behind their own opt-in line.
- `cmd/add.sh`: add the `agsec_in_agent_session` awareness (mirror `setup.sh:318`) — an in-session warn +
  route value entry to a real terminal (the gate absent since W1's descope; the corporate panel wants it).

## HC5 — IT managed-policy fragment + SECURITY.md — EXPANDED

- Ship `docs/` (or `share/`) a copy-paste managed-settings fragment (`claudeMd` + `permissions.deny
  .env*`) for IT to deploy via Jamf/Intune — documented, NOT auto-written.
- SECURITY.md: an "MCP not shipped by default" subsection (the CVEs + the "expected"/unpatched config→exec
  primitive) so the ABSENCE reads as a deliberate, documented security decision; document the discovery
  threat model (advisory, bidirectional, names-only shrinks-not-removes, managed-tier for invariants).

## HC residual risks (carry forward, from the panel)
- Local-tamper defense is fundamentally limited (an attacker controlling PATH/binary controls a
  `doctor`-based check too) → self-guard is a PURE file-existence predicate, NOT "run doctor".
- Density dilution: added standing orders lower adherence (~68% ceiling) to ALL instructions incl. the
  org's own — keep the block minimal.
- Threat-model consistency: `bin/apiKeyHelper` is itself a PATH-resolved command reference whose stdout is
  a live credential — either it gets the same abs-path/scrutiny as the MCP-drop rationale, or that
  rationale reads as conclusion-driven. (`bin/` is permission-locked in this env; flag for the owner.)
