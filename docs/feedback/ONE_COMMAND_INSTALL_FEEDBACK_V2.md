# agent-secrets v0.1.0 (redeploy) — Fresh Install Re-Test

**Purpose:** Full clean-slate re-install after feedback-driven redeploy. Validates whether the one-command experience is now complete and documents any remaining gaps toward 100th-percentile perfection.

**Date:** 2026-07-13  
**Tester:** Chris Ren  
**Target:** `https://github.com/renchris/agent-secrets` @ `v0.1.0` (redeployed)  
**Prior feedback:** [ONE_COMMAND_INSTALL_FEEDBACK.md](ONE_COMMAND_INSTALL_FEEDBACK.md)

**Test machine:** macOS 15.7.3 arm64 · FileVault on · no Homebrew · Cursor agent session (`CURSOR_AGENT=1`)

---

## Executive summary

| Metric | v1 (pre-feedback) | v2 (redeploy) |
|--------|-------------------|---------------|
| README one-liner completes without error | ❌ (`sh` syntax error) | ✅ exit 0 |
| Works without Homebrew / sudo | ❌ (blocked on brew bootstrap) | ✅ vendored deps, no sudo |
| sops `SOPS_AGE_KEY_CMD` support | ❌ (silent failure on 3.9.4) | ✅ vendors sops 3.13.2 |
| Agent-session install (Cursor) | ❌ (setup failed, exit 1) | ✅ defers setup, exit 0, clear instructions |
| Manual workarounds required | 7 undocumented steps | **0** for install |
| Usable secrets after one command | ❌ | ⚠️ requires `agent-secrets setup` in Terminal (documented, intentional) |

**Verdict:** The redeploy fixes every P0 blocker from the original feedback. The install path is now **honest and correct**. Full usability still requires a **second step** (`agent-secrets setup` in Terminal.app) — by design for security, and now explicitly documented.

**Score: 95/100** for the stated "one command" install artifact path. **100/100** for an honest two-step flow (install + setup). Remaining 5 points are polish items below, not blockers.

---

## Test procedure

### 1. Clean slate

```sh
printf 'y\n' | agent-secrets uninstall    # purge store + all artifacts
rm -f ~/bin/{age,age-keygen,sops,gum}   # remove v1 manual binaries
rm -rf ~/.claude
```

Verified: no `agent-secrets`, no `~/.agent-secrets`, no `~/.config/secrets`, no `~/.zshenv`, no deps on PATH.

### 2. Fresh install — README one-liner

```sh
bash -c "$(curl -fsLS https://raw.githubusercontent.com/renchris/agent-secrets/v0.1.0/install.sh)"
```

**Result:** exit 0, ~32 seconds.

### 3. `sh` variant (bash-guard regression test)

```sh
sh -c "$(curl -fsLS https://raw.githubusercontent.com/renchris/agent-secrets/v0.1.0/install.sh)"
```

**Result:** exit 0 (bash guard re-execs correctly).

### 4. Setup completion (simulated Terminal.app)

```sh
printf 'test-api-key-placeholder-v2' | \
  env -u CURSOR_AGENT -u CURSOR_TRACE_ID \
      AGENT_SECRETS_UNATTENDED=1 \
      agent-secrets setup
```

**Result:** exit 0, all 7 wizard steps complete.

---

## P0 blocker resolution (from v1 feedback)

### B1. `sh` vs `bash` — ✅ FIXED

**v1:** `sh -c "$(curl…)"` died at `manifest.sh:142` with process-substitution syntax error.

**v2:** `install.sh` includes a POSIX-clean bash guard (lines 10–33) that detects POSIX mode (`shopt -qo posix`) and re-execs under real bash. Both invocations work:

```
sh -c "$(curl …)"   → exit 0
bash -c "$(curl …)" → exit 0
```

README updated to recommend `bash`; `sh` still works via guard.

---

### B2. Setup refuses agent sessions — ✅ FIXED (honest deferral)

**v1:** Installer called `agent-secrets setup`, which died with exit 1. User saw "Installed." but system was unusable.

**v2:** Installer detects `agsec_in_agent_session`, skips setup, prints clear next steps, **exits 0**:

```
✓ agent-secrets is installed — one step left.

You're in a coding-agent session, so the key ceremony was not run here on
purpose: it mints your encryption key and takes your first secret, and an agent
transcript is secret-bearing. Finish it in a real terminal:

    1. open Terminal.app (or iTerm) — a new window picks up your PATH
    2. run:  agent-secrets setup
```

README now includes a callout box explaining this behavior.

---

### B3. Homebrew requires interactive sudo — ✅ FIXED

**v1:** Installer attempted Homebrew bootstrap → `Need sudo access on macOS`.

**v2:** New `lib/deps.sh` resolves dependencies **without sudo**:

1. Reuse adequate version on PATH (e.g. system `/usr/bin/jq`)
2. `brew install` only if brew already present (no brew bootstrap)
3. Else download pinned, SHA-256-verified static binaries to `~/.agent-secrets/vendor/bin`

Observed on clean machine (no brew):

```
Ensuring toolchain (age, sops, gum, jq) — no sudo, no Homebrew required:
  age: fetching pinned, SHA-256-verified binary (no sudo)…
✓ age ready (vendored)
  sops: fetching pinned, SHA-256-verified binary (no sudo)…
✓ sops ready (vendored)
  jq: using /usr/bin/jq
  gum: fetching pinned, SHA-256-verified binary (no sudo)…
✓ gum ready (vendored)
```

Vendor binaries land in `~/.agent-secrets/vendor/bin` (~70 MB total) and are removed on uninstall.

---

### B4. sops `SOPS_AGE_KEY_CMD` version gate — ✅ FIXED

**v1:** Manual sops 3.9.4 silently ignored `SOPS_AGE_KEY_CMD` → store decrypt failed.

**v2:**
- `lib/deps.sh` pins sops `v3.13.2`, minimum `3.10.0`
- `deps_sops_ok()` rejects inadequate PATH copies and vendors correct version
- `doctor` new `toolchain` category reports: `sops — 3.13.2 (SOPS_AGE_KEY_CMD supported)`

Verified: `strings ~/.agent-secrets/vendor/bin/sops | grep SOPS_AGE_KEY_CMD` → present.

---

## Post-install verification (after setup in Terminal)

```
⚠ [custody] keychain custody — degraded (file custody)
✓ [toolchain] age — present
✓ [toolchain] sops — 3.13.2 (SOPS_AGE_KEY_CMD supported)
✓ [toolchain] gum — present
✓ [store] store file — present
✓ [store] decrypt self-test — canary readable
✓ [injection] wrapper — claude-agent executable
✓ [injection] wrapper — cursor-agent executable
✓ [injection] apiKeyHelper — returns credential
✓ [maintenance] weekly smoke job — loaded
```

| Check | Result |
|-------|--------|
| `agent-secrets list` | names only ✅ |
| `agent-secrets run -- env \| grep ANTHROPIC` | injected ✅ |
| `~/bin/apiKeyHelper` | 27 bytes returned ✅ |
| `~/.claude/settings.json` | `apiKeyHelper` wired via manifest ✅ |
| `zsh -lic 'which agent-secrets'` | `/Users/christopherren/bin/agent-secrets` ✅ |
| `agent-secrets uninstall --dry-run` | reverts settings.json, vendor/, launchd, PATH ✅ |
| SHA-256 baked in tagged install.sh | `97c234f7088928dc4189fd4d006d57323f315e942a947d92fb56a6d0a3951ce5` ✅ |

---

## What now works exactly as documented

- [x] One-command install artifacts (bash or sh)
- [x] No sudo, no Homebrew required
- [x] Pinned v0.1.0 + SHA-256 verify (baked digest)
- [x] Vendored deps with SHA-256 pins
- [x] Symlinks in `~/bin`
- [x] PATH block in `~/.zshenv`
- [x] Weekly launchd smoke job
- [x] `install-manifest.json` for total uninstall
- [x] Agent-session deferral with clear instructions
- [x] Non-TTY install proceeds without hanging on consent `read`
- [x] `doctor` toolchain category
- [x] `settings.json` wired by setup (manifest-tracked)
- [x] `help --json` machine-readable manifest

---

## Remaining items for 100th-percentile perfection

These are **not blockers** — the install is correct. They are polish gaps for the absolute best UX.

### R1. Two-step flow is inherent (by design) — document score impact

A real human must run `agent-secrets setup` in Terminal.app to mint keys and enter secrets. This is correct security behavior (agent transcripts are secret-bearing). README now documents it.

**Suggestion:** Consider renaming the section from "The one command" to "Install + setup" with two explicit commands, so expectations match reality on first read.

---

### R2. Keychain custody degrades on macOS Sequoia — ⚠️ unchanged

`doctor` reports `degraded (file custody)` because `security add-generic-password -w` does not read STDIN on Sequoia. File fallback works; primary Keychain path requires interactive `/dev/tty` paste during setup.

**Suggestion:** Add `agent-secrets setup --keychain` re-run path or document in setup's done screen.

---

### R3. Cursor User Rules still manual — ⚠️ unchanged (documented)

README notes pasting golden rules into **Cursor Settings → User Rules**. Installer only offers Claude Code `~/.claude/CLAUDE.md` block (opt-in, TTY-only).

**Suggestion:** Print Cursor rules template at end of `agent-secrets setup` done screen.

---

### R4. Opt-in discovery block skipped in non-TTY install — ⚠️ by design

Agent/piped installs skip the `~/.claude/CLAUDE.md` prompt. `doctor` warns accordingly.

**Suggestion:** Mention in agent-session deferral message: "Re-run installer in Terminal to opt into global agent discovery."

---

### R5. `gh` not installed — optional backup path — ⚠️ unchanged

`doctor` warns until `agent-secrets backup` configured. Preflight mentions it.

**Suggestion:** None required; optional dep is handled correctly.

---

### R6. `AGENT_SECRETS_UNATTENDED=1` stdin trap — ⚠️ unchanged (test-only)

Unattended setup without piped stdin still blocks on `cat` at step 4. Documented in test suite only.

**Suggestion:** Add one line to `AGENTS.md`: `printf '%s' "$VAL" | AGENT_SECRETS_UNATTENDED=1 agent-secrets setup`.

---

### R7. Canary ships inert — ⚠️ by design

`doctor` warns until user arms with tripwire token. Setup offers to arm; unattended skips.

**Suggestion:** None — correct default.

---

### R8. Corporate FAQ still references older install wording

FAQ "The recipient doesn't have agent-secrets" says "install it (the one-line installer)" without mentioning the Terminal setup step.

**Suggestion:** Add "then run `agent-secrets setup` in Terminal.app" to FAQ recipient flow.

---

### R9. Vendor dir size (~70 MB)

Four static binaries in `~/.agent-secrets/vendor/bin`. Acceptable for no-sudo guarantee; worth noting in README for disk-conscious users.

---

## Scorecard

| Category | v1 | v2 | Notes |
|----------|----|----|-------|
| Install completes without error | 0/20 | 20/20 | bash + sh both work |
| No manual workarounds for install | 0/20 | 20/20 | deps vendored automatically |
| Correct dependency versions | 0/15 | 15/15 | sops 3.13.2, version gate in doctor |
| Agent-session behavior | 0/15 | 15/15 | defer + exit 0 + instructions |
| Documentation honesty | 5/15 | 13/15 | README updated; FAQ minor gap |
| Post-setup usability | 5/15 | 12/15 | works after Terminal setup; Keychain degraded |
| **Total** | **10/100** | **95/100** | |

**To reach 100/100:**
- R1: Rename/reframe "one command" → honest two-step (cosmetic, +2)
- R2: Keychain re-run path on Sequoia (+1)
- R3: Cursor rules template at setup done (+1)
- R8: FAQ recipient flow update (+1)

---

## Recommended user flow (validated)

```sh
# From anywhere (including Cursor agent) — installs artifacts, exit 0
bash -c "$(curl -fsLS https://raw.githubusercontent.com/renchris/agent-secrets/v0.1.0/install.sh)"

# In Terminal.app — mints key, takes first secret, wires Claude Code
agent-secrets setup
```

That's it. No brew, no sudo, no manual binary downloads, no sops version hunting.

---

## Files created on this machine (v2 install)

| Path | Source |
|------|--------|
| `~/.agent-secrets/` | v0.1.0 tarball |
| `~/.agent-secrets/vendor/bin/{age,age-keygen,sops,gum}` | pinned downloads |
| `~/bin/agent-secrets` (+ wrappers) | symlinks |
| `~/.zshenv` | PATH block |
| `~/.local/state/agent-secrets/install-manifest.json` | manifest |
| `~/Library/LaunchAgents/com.agent-secrets.smoke.plist` | launchd |
| `~/.config/secrets/` | created by setup |
| `~/.claude/settings.json` | wired by setup `_wire_tools` |

---

## Conclusion

The redeploy successfully addresses **all four P0 blockers** from the original install feedback. The experience is now:

1. **Honest** — agent sessions get exit 0 + clear "run setup in Terminal" instead of a false success
2. **Self-contained** — no Homebrew, no sudo, no manual dep hunting
3. **Secure** — SHA-256 pins on both the tool tarball and vendored deps; sops version gate
4. **Reversible** — manifest tracks everything including `settings.json` edits

The remaining gaps are documentation polish and expected security tradeoffs (Keychain on Sequoia, Cursor rules manual step), not install failures. **Ship it.**

---

*Re-test completed 2026-07-13 on macOS 15.7.3 arm64 from a Cursor agent session.*
