# agent-secrets — Final Release Feedback (One and Done)

**Audience:** agent-secrets / agent-teams maintainers  
**From:** Chris Ren — real-machine install journey (v1→v4 + production use)  
**Date:** 2026-07-14  
**Target:** One final release (`v0.2.0` or `v0.1.1`) — no fifth feedback round  
**Test machine:** macOS 15.7.3 arm64 · FileVault on · **no Homebrew** · Cursor + Terminal

**Prior reports:** `ONE_COMMAND_INSTALL_FEEDBACK_V3.md`, `ONE_COMMAND_INSTALL_FEEDBACK_V4.md`

---

## Executive summary

### What is done (do not regress)

The **install + setup core** is production-ready after v4:

- `bash`/`sh` one-liner works (bash guard); exit 0 from agent sessions
- No sudo, no Homebrew required; `lib/deps.sh` vendors age/sops/gum/jq with SHA-256 pins
- sops ≥3.10 / `SOPS_AGE_KEY_CMD` gate; doctor `toolchain` category
- Honest **Install + setup** two-step docs; agent/non-TTY deferral with clear next steps
- `setup --keychain`, UNATTENDED bounded stdin, returning-user re-wire, `settings.json` doctor check
- Machine-wide install (`~/.agent-secrets`, `~/bin`, `~/.zshenv`, encrypted store, manifest, uninstall)
- User completed interactive Terminal install + **discovery opt-in** → `✓ global agent rules — present in ~/.claude/CLAUDE.md`

### What one final release must fix

v1–v4 solved **installer correctness**. Remaining gaps are **post-install onboarding** and **multi-IDE discovery** — the reasons users still ask questions after a “100/100” install:

| Gap | User impact |
|-----|-------------|
| `gh` / `az` outside installer toolchain | Blocked on GitHub/Azure setup without manual downloads + Python 3.14 for `az` |
| Discovery is Claude Code–only | User opted in, then asked if Cursor/Copilot/`AGENTS.md` are covered — they are not |
| Placeholder secret + doc literals | User ran `$YOUR_REAL_ANTHROPIC_KEY` verbatim; confusing error |
| Keychain still degraded after full Terminal setup | Extra `setup --keychain` step on Sequoia not surfaced proactively |
| Doctor noise on fresh install | 7× `⚠` on first `doctor` — feels broken though exit 0 |
| “What to configure first” | User skipped Anthropic, wanted GitHub/Azure — ladder philosophy not in setup flow |

**Release thesis:** Ship **“complete onboarding”** — one guided path from install → configured for GitHub + Azure + chosen IDE, without Homebrew, without doc placeholders, without fifth-round questions.

---

## Journey recap (context for engineers)

| Round | Score | Fixed |
|-------|-------|-------|
| **v1** | 10/100 | — |
| **v2** | 95/100 | `sh`→bash guard; `lib/deps.sh` no-sudo; agent deferral exit 0; sops 3.13.2 |
| **v3** | 100/100 install | Install+setup framing; `--keychain`; Cursor rules on done screen; FAQ; UNATTENDED timeout |
| **v4** | 100/100 hardening | `settings.json` doctor check; non-TTY deferral; wire JSON fix; wrapper clobber guard |

**v1 blockers (must stay fixed):** `sh` syntax error; Homebrew sudo; setup exit 1 in agent; sops 3.9.4 silent decrypt failure; 7 manual workarounds.

---

## P0 — Must ship in final release

### P0-1. Post-install “configure your services” guide (in-product, not README-only)

**Problem:** Installer vendors 4 binaries; user immediately needs `gh` and `az`, which are **not** in `deps_ensure`. On brew-less Mac:

- `gh`: manual download to `~/bin` (we did v2.96.0 arm64 zip)
- `az`: tarball to `~/lib/azure-cli` + **Python 3.14** + `AZ_PYTHON` + pyenv install (~3 min)

**Ship:**

1. **`agent-secrets doctor` new category `onboarding`** (or setup step 8 “Next steps”) listing:
   - `gh` — install recipe + `gh auth login` (preferred over `GITHUB_TOKEN` in store)
   - `az` — install recipe + `az login` (preferred over `AZURE_*` in store)
   - Anthropic — `agent-secrets add ANTHROPIC_API_KEY` when ready (optional for Claude/cursor-agent)
2. **`docs/POST_INSTALL.md`** (linked from deferral message, done screen, `help onboarding`) with brew-less recipes:
   - `gh`: pinned GitHub release → `~/bin` (mirror `deps_fetch_*` pattern)
   - `az`: tarball + `AZ_PYTHON` requirements **called out before download** (Python 3.14 is non-obvious)
3. **Do not vendor `gh`/`az` in installer** (too heavy, different lifecycle) unless willing to own ~100MB+ and Python coupling — **document beats bundle** for P0.

**Acceptance:** Fresh brew-less Mac, after install+setup, user can follow in-product pointers to working `gh auth login` and `az login` without external blog posts.

---

### P0-2. Multi-IDE discovery — close the Cursor gap

**Problem:** Opt-in writes `~/.claude/CLAUDE.md` only. User asked: *“Does this work for AGENTS.md / Cursor / Copilot?”* Answer today: **no** for global discovery.

| Surface | Current | Target |
|---------|---------|--------|
| Claude Code | `~/.claude/CLAUDE.md` opt-in ✅ | Keep |
| Cursor | Manual paste to User Rules | **Automate or semi-automate** |
| VS Code Copilot | Nothing | Document; optional `copilot-instructions.md` if stable |
| Repo `AGENTS.md` | Not installer scope | `agent-secrets init-agents-md` or doc template |

**Ship (pick at least one automated path for Cursor):**

1. **Setup/installer opt-in:** “Also configure Cursor?” → if Cursor config path exists and is writable, append marker-delimited block (mirror `manifest_pathblock_install` pattern). Research: `~/.cursor/` rules location — if unstable, do not write files; use fallback below.
2. **Copy-to-clipboard (always):** At end of setup + discovery opt-in success: `pbcopy` the golden-rules block + print *“Pasted to clipboard — Cursor Settings → Rules → User Rules”*.
3. **Doctor check:** New row `discovery — cursor user rules` with status `unknown` / `not configured` / `present` (grep User Rules DB if API exists; else `attn` + one-line instruction).
4. **README table:** “Who reads what” — 4 rows, no ambiguity.

**Acceptance:** User who opts into discovery in Terminal leaves with Claude **and** explicit Cursor action (clipboard or file write) in one session — no FAQ hunt.

---

### P0-3. Placeholder secret UX — never confuse users with doc literals

**Problem:** User ran `printf '%s' "$YOUR_REAL_ANTHROPIC_KEY" | agent-secrets add …` literally. Error: *“NON-EMPTY single-line value on STDIN (got end of input)”* — technically correct, human-opaque.

**Ship:**

1. **`store_add` / `add` error** when stdin empty: append *“If you copied from docs, replace the placeholder with your real key, or run `agent-secrets add NAME` for a hidden prompt.”*
2. **Setup done screen** when `ANTHROPIC_API_KEY` equals unattended placeholder or seed value: print *“Replace test placeholder: `agent-secrets add ANTHROPIC_API_KEY`”* (names-only check — compare digest or `AGENT_SECRETS_SEED_VALUE` marker in manifest).
3. **AGENTS.md / help examples:** use `agent-secrets add ANTHROPIC_API_KEY` (interactive) as **primary** example; pipe examples use `$ANTHROPIC_API_KEY` with comment “must be set in your shell”.

**Acceptance:** No doc string is copy-pasteable as a variable name that looks like a real env var.

---

### P0-4. Keychain prompt at end of **interactive** setup (Sequoia)

**Problem:** Full Terminal install + setup still shows `⚠ custody — degraded (file custody)`. User must discover `setup --keychain` separately.

**Ship:**

1. After `_key_ceremony` in interactive setup, if `kc_status` ≠ primary: **`_confirm "Populate login Keychain now for prompt-free use?"`** → run keychain paste flow inline (same as `--keychain` screen).
2. If declined: done screen already mentions `--keychain` (keep).
3. Doctor: keep remediation text (already good).

**Acceptance:** Interactive Terminal setup on Sequoia ends with `✓ keychain custody — primary` **or** explicit user decline recorded (not silent degrade).

---

## P1 — Should ship in same release

### P1-1. Setup preflight: “prefer CLI login over stored secrets”

**Problem:** User had no Anthropic key; correctly moved to GitHub/Azure. Ladder exists in `lib/ladder.sh` but not in setup UX.

**Ship:** Preflight screen (step 2) prints:

```
Recommended order (no raw tokens unless required):
  1. gh auth login     — GitHub (also enables agent-secrets backup)
  2. az login          — Azure
  3. agent-secrets add — only for keys that must live in env (API keys)
```

Link to `help onboarding` / POST_INSTALL.

---

### P1-2. Doctor output tiers — “fresh install” vs “hardened”

**Problem:** First `doctor` after setup shows 7× `⚠` (canary, backup, discovery if skipped, hygiene, supply-chain, custody). Exit 0 but feels alarming.

**Ship:**

1. **`doctor --summary`** (default for setup step 6): show only `✗` and `custody`/`store`/`injection`/`toolchain` — hide optional `attn` unless `--verbose`.
2. Or: **`doctor --gates`** becomes the quiet default post-setup; full output on `doctor` alone.
3. **Setup step 6** calls `doctor --summary` so wizard ends green unless real `bad`.

**Do not:** Remove checks — tier the presentation.

---

### P1-3. Wire `cleanupPeriodDays` when creating `settings.json`

**Problem:** `⚠ hygiene — cleanupPeriodDays — unset (want ≤14)` immediately after setup creates `settings.json`.

**Ship:** In `_wire_tools`, when creating new `settings.json`:

```json
{ "apiKeyHelper": "...", "cleanupPeriodDays": 14 }
```

Manifest-recorded edit; reversible. Clears one hygiene warning for Claude Code users.

---

### P1-4. Canary: setup nudge without forcing

**Problem:** `INERT decoy` warning forever unless user arms.

**Ship:**

1. Keep default inert (security choice).
2. Done screen one-liner: *“Optional: arm breach canary — `agent-secrets add AWS_BACKUP_ACCESS_KEY_ID` with a token from canarytokens.org”*
3. Doctor `canary` row: append *“(optional)”* in detail string.

---

### P1-5. `agent-secrets backup` prerequisite chain

**Problem:** `backup` needs `gh` + `gh auth login`; doctor warns `backup — none` with no dependency hint.

**Ship:** Doctor backup row when `gh` missing: *“install gh + gh auth login, then agent-secrets backup”* with link to POST_INSTALL gh recipe.

---

## P2 — Document if not coded (acceptable for “one and done” if P0/P1 ship)

| Item | Recommendation |
|------|----------------|
| Vendor `gh` in `deps.sh` | **No** — document fetch recipe; gh auth is interactive |
| Vendor `az` + Python 3.14 | **No** — document tarball + `AZ_PYTHON`; too coupled |
| VS Code Copilot global rules | Document `.github/copilot-instructions.md` per repo; no stable global path |
| Machine-wide `AGENTS.md` | Optional `agent-secrets print-discovery > AGENTS.md` for user to drop in repos |
| `npm ignore-scripts` | One line in done screen; not installer scope |
| `~/.claude/projects` hygiene | Only relevant for Claude Code project users; keep `attn` |

---

## Validated flows — regression suite (CI + manual)

Every final release must pass these on **brew-less macOS arm64**:

```sh
# 1. Clean slate
printf 'y\n' | agent-secrets uninstall

# 2. Install from agent session
bash -c "$(curl -fsLS https://raw.githubusercontent.com/renchris/agent-secrets/v0.1.0/install.sh)"
# → exit 0, deferral message, no setup in agent

# 3. sh variant
sh -c "$(curl -fsLS .../install.sh)"  # → exit 0 via bash guard

# 4. Interactive setup (Terminal)
agent-secrets setup  # → 7 steps, settings.json wired

# 5. Discovery opt-in (TTY install re-run or first interactive install)
# → ✓ discovery present in ~/.claude/CLAUDE.md

# 6. UNATTENDED no hang
env -u CURSOR_AGENT AGENT_SECRETS_UNATTENDED=1 agent-secrets setup  # → <5s, no block

# 7. Core ops
agent-secrets list          # names only
agent-secrets run -- env    # injects
agent-secrets doctor        # exit 0, no bad

# 8. Uninstall
agent-secrets uninstall --dry-run  # reverts manifest incl. settings.json
```

**Must not regress:** SHA-256 baked digest; vendor sops 3.13.2+; `SOPS_AGE_KEY_CMD`; manifest rollback; wrapper symlinks; launchd smoke label `com.agent-secrets.smoke`.

---

## Acceptance criteria — “one and done” checklist

Release is **done** when a brew-less Mac user can:

- [ ] Install + setup without manual binary hunting for **agent-secrets deps** (age/sops/gum/jq)
- [ ] Follow **in-product** steps to `gh auth login` and `az login` without reading GitHub issues
- [ ] Opt into discovery and **know** Claude vs Cursor vs Copilot coverage without asking
- [ ] Replace placeholder API key without mistaking doc literals for env vars
- [ ] Complete interactive setup on Sequoia with **primary Keychain** or explicit decline
- [ ] Run `doctor` after setup and see **≤3 attn lines** by default (or clear “optional hardening” section)
- [ ] Uninstall fully with no orphaned PATH/settings/launchd

**Stakeholder sign-off:** One Terminal session from zero → GitHub authenticated + Azure authenticated + agent-secrets injecting secrets + discovery configured for **their** IDE(s).

---

## Suggested release notes outline

```markdown
# agent-secrets v0.2.0 — Complete onboarding

## Install (unchanged)
- No sudo, no Homebrew; pinned vendored toolchain
- Install + setup two-step; agent/non-TTY deferral

## New: Post-install onboarding
- `agent-secrets help onboarding` — gh/az install recipes (brew-less macOS)
- Setup preflight: prefer `gh auth login` / `az login` over stored tokens
- Doctor summary mode — quieter first-run health check

## New: Multi-IDE discovery
- Cursor: clipboard + instructions at setup/discovery opt-in
- README: who-reads-what table (Claude / Cursor / Copilot / AGENTS.md)

## Improved
- Interactive setup offers Keychain populate on Sequoia (fewer degraded custody)
- `add` empty-stdin error explains doc placeholders
- `settings.json` sets cleanupPeriodDays=14 on create
- Backup doctor hint chains to gh install

## Fixed
- (none — v4 baseline; this release is UX completion)

## Upgrade
bash -c "$(curl -fsLS .../v0.2.0/install.sh)"  # idempotent
agent-secrets setup   # re-run safe; new onboarding screens
```

---

## Implementation map (files likely touched)

| Item | Files |
|------|-------|
| Onboarding help | `cmd/onboarding.sh` or extend `help.sh`; `docs/POST_INSTALL.md` |
| Cursor clipboard | `cmd/setup.sh` `_done_screen`, `install.sh` discovery block |
| Doctor tiers | `cmd/doctor.sh`; `help.sh` flags |
| Keychain inline | `cmd/setup.sh` `_key_ceremony` tail |
| cleanupPeriodDays | `cmd/setup.sh` `_wire_tools` |
| add error message | `lib/store.sh` `store_add` |
| README IDE table | `README.md` |
| Tests | `tests/flows.bats`, `tests/doctor.bats`, `tests/onboarding.bats` |

---

## What we will **not** file again

If P0 + P1 ship with acceptance criteria met, these are **closed**:

- `sh` vs `bash` installer breakage
- Homebrew/sudo requirement for core deps
- Agent session false-success install
- sops version / `SOPS_AGE_KEY_CMD` silent failure
- Undocumented manual workarounds for age/sops/gum/jq
- Missing `settings.json` doctor verification
- UNATTENDED stdin hang

---

## Appendix: user session evidence

| Event | Outcome |
|-------|---------|
| v1 install from Cursor | Failed `sh` / brew / setup exit 1 |
| v4 install from Cursor | exit 0, deferral ✅ |
| Terminal install + discovery `y` | `✓ discovery — present in ~/.claude/CLAUDE.md` ✅ |
| User asked Cursor/Copilot coverage | Gap identified — P0-2 |
| `$YOUR_REAL_ANTHROPIC_KEY` literal | Gap identified — P0-3 |
| `gh auth login` | `command not found` → manual `~/bin/gh` install |
| `az login` | `command not found` → tarball + Python 3.14 + pyenv |
| No Anthropic key | Proceeded to GitHub/Azure — ladder UX gap P1-1 |

---

*Single release brief for agent-teams. Goal: ship once, close onboarding forever.*
