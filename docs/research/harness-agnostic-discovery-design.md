# Harness-agnostic one-command discovery — 100th-percentile design

> **Status:** investigation complete (design, not yet built). Produced by a 16-agent Dynamic
> Workflow (10 Opus research axes + 2 Fable-5 adversarial + 1 synthesis + 3 Fable-5 red-team),
> 2026-07-14. All three red-team lenses (path-correctness, consent-security, completeness)
> returned **ship-with-fixes**; several claims verified against VS Code *source*, not just docs.
> Provenance + raw findings: workflow `wig5jjl7w` / run `wf_4dce9484-640`.

---

## TL;DR — the reframe

The question "should discovery be default-on, and are we set up for AGENTS.md / all platforms?"
rests on a **stale premise**. The corrected 2026 landscape:

1. **VS Code / GitHub Copilot already reads `~/.claude/CLAUDE.md` by default** (`chat.useClaudeMdFile`,
   VS Code ≥ 1.109; confirmed in VS Code source `promptFileLocations.ts:174-179`, not just docs).
   **So the existing opt-in block already covers 2 of the 3 required harnesses** (Claude Code +
   VS Code Copilot). The "VS Code gap" in `ONE_COMMAND_INSTALL_FEEDBACK_FINAL.md` P0-2 is a
   **docs/doctor gap, not a build gap.**
2. **Cursor is the one structural hole.** It has *no* supported global rules file — User Rules live
   in an opaque, cloud-synced settings DB (`state.vscdb`); the on-disk `~/.cursor/rules` is
   community-confirmed to *silently not apply* in Cursor 3.x. Clipboard-paste is the **honest
   ceiling**; writing any file for Cursor would convert a visible manual step into an **invisible
   false-green** — the worst outcome.
3. **There is no machine-wide `AGENTS.md`.** `AGENTS.md` is a *per-repo* standard (30+ harnesses read
   it in-repo). Machine-wide FILE surfaces exist only per-tool: `~/.claude/CLAUDE.md` (+ Copilot),
   `~/.codex/AGENTS.md`, `~/.gemini/GEMINI.md`, `~/.config/zed/AGENTS.md`, `~/.agents/AGENTS.md`
   (emerging cross-tool convention). Cursor/Copilot have **no** global file of their *own*.

**Net:** "machine-wide, harness-agnostic" is achievable as a **hub-and-adapter**, not a
write-5-global-files fan-out. The required three collapse to **~1.5 surfaces**: one hub file
(Claude Code + Copilot) + Cursor's clipboard adapter.

**Verdict on the original question:** keep discovery **prompted** (never silently edit a global
agent-instruction file — all three lenses agree, and the proposed non-tty auto-opt-in is a
security hole, see §5). The real work is (a) *documenting/verifying* the coverage you already have,
(b) fixing real shipped bugs (§3), and (c) closing Cursor honestly.

---

## 1. Corrected surface matrix (machine-wide)

| Harness | Global path | Automatable | Notes / confidence |
|---|---|---|---|
| **Claude Code** | `${CLAUDE_CONFIG_DIR:-~/.claude}/CLAUDE.md` — **preferred: `…/rules/agent-secrets.md`** | prompt | Loaded every session/repo. Must honor `CLAUDE_CONFIG_DIR` (install.sh:271 hardcodes `$HOME/.claude` — wrong when relocated; **this machine is a live example**). High confidence. |
| **VS Code / Copilot** | *none of its own* — **covered free by the Claude hub file**; fallback `~/.copilot/instructions/agent-secrets.instructions.md` | auto | Native default read of `~/.claude/CLAUDE.md` **and** `~/.claude/rules/` (VS Code source `promptFileLocations.ts:174-179`). Caveat: setting is `restricted:true` — untrusted workspaces / org policy suppress it → doctor must read the *effective* setting, not assume default. |
| **Cursor** | *none* — Settings ▸ Rules ▸ User Rules only (cloud-synced DB) | clipboard | File-less confirmed (cursor.com/docs/rules; forum 157335). **Do not** write `~/.cursor/rules` or `state.vscdb` (silent non-apply / sync-clobber). Only file-automatable global channel is `~/.cursor/mcp.json` (see §7 open-Q3). |
| **Codex CLI** | `${CODEX_HOME:-~/.codex}/AGENTS.md` (`AGENTS.override.md` wins if present) | prompt | Cheapest broader win; unconditional per-repo load. 32 KiB combined cap. High confidence. |
| **Gemini CLI** | `~/.gemini/GEMINI.md` | prompt | Write `GEMINI.md` (default-read), **not** a global AGENTS.md (loads only if added to `settings.json context.fileName`). |
| **Zed** | `~/.config/zed/AGENTS.md` (`%APPDATA%\Zed\AGENTS.md` on Windows) | prompt | **CONFIRMED shipped** (Zed 1.4.2) — red-team upgraded from "forward bet". |
| **Cline** | `~/.agents/AGENTS.md` (+ `~/Documents/Cline/Rules/`) | prompt | `~/.agents/AGENTS.md` is the **emerging cross-tool** global convention. Verify shipped support on-target before activating the row. |
| **Windsurf / Devin Desktop** | `~/.codeium/windsurf/memories/global_rules.md` | prompt | Low/med confidence — rebranded to Devin Desktop 2026-06, path may migrate to `~/.devin/`. **6,000-char cap** — append can silently truncate. Re-verify on-target. |
| **Repo `AGENTS.md`** (breadth, *not* machine-wide) | `<repo>/AGENTS.md` + `<repo>/CLAUDE.md` with `@AGENTS.md` | prompt | One file natively read by 7+ harnesses. But repo-scoped — structurally **cannot** deliver machine-wide discovery (chicken-and-egg: rules must precede the first agent action, incl. in repos the agent scaffolds). Ship as additive `agent-secrets init-agents-md`. |

**Managed-policy CLAUDE.md** (`/Library/Application Support/ClaudeCode/CLAUDE.md` etc., non-excludable,
loads *before* user files) is the *right* surface for a security invariant on MDM-managed machines —
worth a documented (not automated) path.

---

## 2. Architecture — hub-and-adapter

1. **ONE canonical renderer.** `agsec_agent_rules()` (`lib/common.sh:149-155`) is the sole rule DATA;
   a pure `agsec_render_rules <plain|claude-md|agents-md|copilot|mdc>` wraps those *same* lines in
   each surface's envelope. **Delete the hand-maintained `_discovery_block` body** (`install.sh:326-335`)
   — it is the proven drift seam (§3.1).
2. **Reuse one reversible primitive.** `manifest_pathblock_install(file, marker, content)`
   (`lib/manifest.sh:84-95`) is already generic, idempotent (strip-then-rewrite), and symlink-aware.
   Each machine-wide surface is one call → N surfaces = N calls, all rendered from the one source.
3. **Data-driven surface registry** is the scaling abstraction. Each row =
   `{harness, path-resolver (honors CLAUDE_CONFIG_DIR/CODEX_HOME/XDG), renderer, marker, gate
   (tool dir/binary present), session-detect-marker, max-bytes, doctor-check, verified-on-date}`.
   `install` / `doctor` / `uninstall` iterate the table. "Broader harness coverage" = **adding rows**,
   not editing `install.sh` logic. This is the honest meaning of "harness-agnostic."
4. **Version + content-hash per block.** Extend the pathblock manifest record (currently
   `{type,file,marker,created}`, `manifest.sh:77-80` — **no hash**) with `{body_sha256, rules_version}`.
   doctor recomputes the canonical render hash → `in-sync` / `STALE (re-run installer)` /
   `HAND-EDITED (hash mismatch → STOP-ASK, never silent-clobber)` / `absent`. Keep the *strip marker
   string* version-stable so strip-then-rewrite idempotency holds.
5. **Per-reader rows, not per-file rows** (red-team, all 3 lenses). The hub file is read by *multiple*
   harnesses. When `CLAUDE_CONFIG_DIR` ≠ `~/.claude`, the resolved write reaches Claude Code but VS
   Code reads the **literal** `~/.claude` path → Copilot silently un-covered. Claude Code and Copilot
   must be **separate registry rows sharing a renderer**; on divergence, write both (each its own
   consent) and doctor reports the split.
6. **Discovery ≠ enforcement (separate layers).** The instruction block is *affordance* — it tells an
   agent the tool exists and how to call it. Prose adherence tops out ≈ **68%** at high instruction
   density (IFScale arxiv 2507.11538; Claude Code's own "read-but-not-followed" issue lineage:
   #7777/#15443/#17530/#18660/#27032/#42863) — acceptable for a lint preference, **not** for a
   "never plaintext secret" invariant. The real guarantee (if in scope) is a deterministic **opt-in
   Claude Code PreToolUse hook** (deny Write/Edit to `.env*`) + `permissions.deny` patterns, with the
   names-only store as the actual invariant carrier. **Scope honestly:** the hook covers Write/Edit in
   *Claude Code only* — not Bash heredocs/`tee`/`python -c`, not Cursor/Copilot/Codex sessions.
7. **Self-guarding block content.** Prepend "ignore this section unless `<abs-path>` exists AND
   `<abs-path> doctor` succeeds"; emit the **resolved absolute** bin path; keep the body 4 lines. Kills
   three failure modes: false assertions on dotfile-synced machines lacking the tool, PATH-hijack
   coercion (agents piping secret VALUES to an impostor `agent-secrets`), and injection real-estate.
8. **Markers:** switch markdown surfaces from the current shell-comment `# >>> agent-secrets >>>`
   (**renders as an H1** in CLAUDE.md, `manifest.sh:14`) to HTML-comment markers
   `<!-- agent-secrets:begin/end -->`. Note Claude Code *strips* block HTML comments before injection,
   so markers+hash live in comments (disk-level grep targets, invisible to the agent) and all
   **agent-facing text stays plain markdown**. Strip logic must recognize **both** old and new markers
   permanently (or migrate records), else v1-installed machines leave orphan blocks on uninstall.

---

## 3. Real bugs in the CURRENTLY-SHIPPED code (independent of the redesign)

These were found in the live tree and are actionable now, regardless of whether the fan-out ships.

### 3.1 The "single source" has already drifted
`lib/common.sh:146-147` asserts `_discovery_block` wording is "intentionally identical" to
`agsec_agent_rules()`. It is **not**:
- `common.sh:151` "…or print a secret VALUE." vs `install.sh:330` "…print a secret VALUE **into the transcript**."
- `common.sh:152` "Run **tools** WITH secrets" vs `install.sh:331` "Run **any tool** WITH secrets… **(values die with the process)**"
- `common.sh:154` "Names/health/manifest" vs `install.sh:333` "Names · health · **full machine-readable** manifest"

`doctor`'s `check_discovery` (`cmd/doctor.sh:227-228`) greps only the begin marker → a v1 block
reports **`ok` forever** after the rules change. Fix: single renderer + hash-verified doctor.

### 3.2 Golden rule #3 can itself leak a secret when an *agent* follows it
The block instructs `printf %s "$VALUE" | agent-secrets add NAME` (`common.sh:153`, `install.sh:332`).
A human in a terminal has `$VALUE` in their shell; an **agent** executing this substitutes the
**literal secret** into the Bash tool command → it lands verbatim in `~/.claude/projects` transcript —
the exact leak the tool exists to prevent. And `cmd/add.sh` has **no** agent-session gate
(`agsec_in_agent_session` is enforced only in `setup.sh`). Fanning this rule to 7+ harnesses without
fixing it widens the exposure. **Fix:** reword the agent-facing render to "to add/rotate a secret, ask
the USER to run `agent-secrets add` in a real terminal (never paste a value into a command)"; add the
`agsec_in_agent_session` refusal (or hidden-stdin requirement) to `cmd/add.sh`.

### 3.3 `agsec_in_agent_session` only detects Claude Code + Cursor
`lib/common.sh:131-138` keys on `CLAUDECODE` / `CURSOR_*` only. Any fan-out that invites Codex / Gemini
/ Windsurf / Zed / Cline agents to run secret-bearing commands must pair **each registry row with a
session-detect marker** (`CODEX_*`, `GEMINI_CLI`, `TERM_PROGRAM`, …); rows lacking a reliable marker get
`detection: none` surfaced in doctor so the gap is *visible*, not silent.

### 3.4 Pathblock write can clobber a curated global config
`manifest_pathblock_install` does whole-file read-modify-write with **no lock, no pre-write backup**
(unlike the edit path), racing Claude Code's own `~/.claude/CLAUDE.md` writers (`#` shortcut, `/memory`)
— last-writer-wins silent loss. It also strips the user's trailing whitespace on every run, and `mv`
drops the original mode/ACLs. Fix: pre-write timestamped backup bound to the hash gate, an atomic
temp-write (`mktemp`+rename), mode preservation. (**Note:** `flock` is util-linux — **not** on stock
macOS; use an `mkdir`-based lock or a vendored helper. The real protection is backup+hash-diff; the lock
only serializes the tool against itself — Claude Code's writers don't honor it.) Adopting the dedicated
`~/.claude/rules/agent-secrets.md` file (open-Q2) **eliminates this whole class** for the primary path
(uninstall = delete, no shared-file surgery).

---

## 4. doctor — coverage table, not a marker grep

Replace the single `optional`-tier CLAUDE.md grep with a **per-surface, per-reader coverage table**:
`present/in-sync · STALE · HAND-EDITED · absent`, plus for the hub the **effective** `chat.useClaudeMdFile`
state, plus a **permanent** `cursor: UNVERIFIABLE — paste once` row (so Cursor absence is surfaced
forever, not once in scrollback). Promote discovery **out of** the summary-hidden optional tier to a
visible `attn` when absent. Add an `agent-secrets discovery {status,install}` subcommand and a final
unmissable line on piped installs. Phase 4: `doctor --probe` — headless per-harness one-shot adherence
smoke on the existing weekly launchd job (needs its own consent tier + spend cap — it runs tool-capable
agent sessions autonomously). Claude Code's `InstructionsLoaded` hook / `/memory` listing is a free,
deterministic "is our block actually LOADED this session" probe for the loaded-vs-present half.

---

## 5. Consent & security model

**Per-surface, never one blanket yes.** Three tiers keyed to *who owns the file*:

1. **Curated user file another tool also reads** (`~/.claude/CLAUDE.md`, `~/.codex/AGENTS.md`,
   `~/.gemini/GEMINI.md`, Windsurf `global_rules.md`): affirmative consent **mandatory** — this is the
   trust line; the block becomes standing orders every agent obeys. Default = interactive
   `[y=recommended · Enter=skip]` that **shows the exact rendered block first** (preview-before-write;
   consent-without-preview trains the exact habit the "Rules File Backdoor" exploits — Pillar Security,
   2025). **Hard-skip when piped/CI** (the `[ -t 0 ]` gate at `install.sh:272` is correct). Enumerate only
   *detected* surfaces and prompt per-surface (or one confirm with per-surface opt-out). Consent copy must
   **name the readers** ("Claude Code + VS Code Copilot + any CLAUDE.md-compatible tool").
2. **Tool-solely-owned dedicated files** (`~/.claude/rules/agent-secrets.md`,
   `~/.copilot/instructions/agent-secrets.instructions.md`): still prompt, but uninstall = **delete the
   file** — no shared-file surgery.
3. **Structured JSON edits** (VS Code `settings.json`): heaviest — mandatory consent + `jq`
   parse-validate the RESULT before replace + write-once backup. Never a raw text append (one stray
   comma breaks all user settings).

**Cursor (clipboard)** is inherently manual every time — faking an auto-write is a false-green regression.

**Precedent** (six installers) all agree — never silently edit a curated global config: Homebrew/direnv
print-and-let-user; rustup prompts + `-y` opt-in; oh-my-zsh backup+env-toggle; pre-commit refuses on
conflict.

**⚠️ The proposed non-tty auto-opt-in is a security hole — do NOT ship it as designed.** All three lenses
independently flagged `AGENT_SECRETS_DISCOVERY=1` / `--with-discovery`: env vars are **ambient authority,
not consent** — any agent-driven or prompt-injected `curl | bash` can set the flag and write standing
orders into `~/.claude/CLAUDE.md` with zero human in the loop, reopening the exact silent-edit hole the
`[ -t 0 ]` gate closed. If a non-tty consent channel is wanted at all: honor it **only** when
`agsec_in_agent_session` is *false*, require an **explicit surface list** (`AGENT_SECRETS_DISCOVERY=claude,codex`,
bare `1` = hub row only), echo the exact rendered block + per-surface write list as an audit record, and
surface a doctor `attn` row ("discovery installed via env-flag — review the block").

---

## 6. Reversibility (three primitives, all already in-repo)

1. **Marker block in a shared user file** — uninstall strips `begin..end`, deletes if tool-created.
   *Must* close the §3.4 clobber gaps before fan-out.
2. **Tool-owned dedicated file** (`manifest_record_file`, `created=1`) — uninstall just deletes it.
   Cleanest reversal; the reason `~/.claude/rules/agent-secrets.md` beats editing the shared monolith.
3. **Structured JSON key edit** (`manifest_record_edit`) — surgical `jq` revert. (Caveat for a future
   PreToolUse hook: hooks live in *nested arrays*, not top-level keys — the current revert only handles
   top-level keys, so extend the edit primitive before Phase 4.)

**Cursor clipboard = irreversible by the tool** (user-owned UI state) — doctor version-nag only.
**Dotfiles caveat:** a chezmoi/stow-synced `~/.claude/CLAUDE.md` can re-introduce/revert the block on
machine B; the self-guard "ignore if not on PATH" line neutralizes the false-assertion, and a
`# synced-from` provenance line lets a human trace an unauditable synced block.

---

## 7. Open decisions (yours — research won't resolve these)

| # | Decision | Recommendation from the evidence |
|---|---|---|
| **Q1** | **Enforcement vs discovery-only** — the load-bearing fork. Golden rules are a *security invariant*, but prose adherence ≈ 68%. Ship the opt-in PreToolUse hook (deterministic `.env` deny) as the real guarantee, or accept a discovery-only install (probabilistic ceiling, labeled "advisory, not enforced")? | **Ship the hook (opt-in)** — a "never plaintext secret" invariant deserves a deterministic floor; the store + hook is the invariant carrier, prose is discovery. Scope the claim honestly (Claude Code Write/Edit only). |
| **Q2** | **Machine-wide Claude target:** dedicated `~/.claude/rules/agent-secrets.md` vs `~/.claude/CLAUDE.md` marker block. | **Flip to the dedicated rules file** — red-team 1 & 3 confirmed (VS Code source + Claude Code docs) it's read by **both** Claude Code and Copilot at launch, with uninstall=delete and **no clobber race**. Keep the CLAUDE.md marker block only as a pre-1.109 fallback. |
| **Q3** | **MCP-as-complement for Cursor:** build a names-only `agent-secrets mcp` server (Cursor's only file-automatable global channel, `~/.cursor/mcp.json`)? | Optional. Gives Cursor real global *presence* (never returning values), at a per-session context tax. Complement, not policy carrier. |
| **Q4** | **`init-agents-md` commit posture:** committed (team-visible, but asserts a machine-local tool to teammates/CI) vs uncommitted (`.git/info/exclude`). | Default **uncommitted**; offer committed as a flag. |
| **Q5** | **Broader-harness scope for v1** beyond the required three. | Codex + Gemini (high-confidence, cheap) **and** Zed + Cline (now CONFIRMED) in the first broader wave; Windsurf deferred (path churn). |
| **Q6** | **Cross-platform:** macOS-only v1, or per-OS resolver now? | macOS-only v1, but **registry schema carries per-OS resolvers from day one** — Zed/Codex/Gemini already have Windows paths; retro-fitting the schema later is costly. |

---

## 8. Provenance

Dynamic Workflow `wig5jjl7w` (run `wf_4dce9484-640`), 2026-07-14: 16 agents, 0 errors, ~1.67M tokens,
386 tool calls, 28 min. 10 Opus/`deep-research` research axes + 2 Fable-5 adversarial (red-team +
negative-space) → 1 synthesis → 3 Fable-5 red-team lenses (path-correctness / consent-security /
completeness). All red-team verdicts: **ship-with-fixes** (fixes folded above). Key external claims
verified against current docs and, for the decisive VS Code claim, against VS Code source
(`promptFileLocations.ts:174-179`, `chat.useClaudeMdFile` default:true, `restricted:true`).
