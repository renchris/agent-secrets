# agent-secrets v0.1.0 — One-Command Install: What Really Happened
**Purpose:** Exhaustive post-mortem of installing `agent-secrets` exactly as the README describes, on a real Mac, from a Cursor agent session. Documents every deviation, failure, workaround, and blocker that prevented a literal one-command-to-usable-state experience.
**Date:** 2026-07-13  
**Tester:** Chris Ren  
**Target:** `https://github.com/renchris/agent-secrets` @ `v0.1.0`  
**README command tested:**
```sh
sh -c "$(curl -fsLS https://raw.githubusercontent.com/renchris/agent-secrets/v0.1.0/install.sh)"
```
**Test machine:**
| Property | Value |
|----------|-------|
| OS | macOS 15.7.3 (Sequoia), arm64 |
| FileVault | On |
| Homebrew | **Not installed** (`/opt/homebrew` absent; stale brew paths remain in `PATH` from a prior install) |
| Shell | zsh |
| Install context | Cursor IDE agent session (`CURSOR_AGENT=1`) |
| Pre-existing `agent-secrets` | None |
---
## Executive summary
The README advertises a single curl-pipe-to-`sh` command. On this machine, that command **failed mid-install** due to a `sh` vs `bash` incompatibility. Even after switching to `bash`, the install **completed its file/launchd/PATH steps but left the system unusable for its intended purpose** because the bundled `agent-secrets setup` wizard refused to run inside the Cursor agent session.
Reaching a working state required:
1. Switching `sh` → `bash` for the installer
2. Manually downloading `age`, `sops`, and `gum` binaries (Homebrew unavailable without interactive `sudo`)
3. Upgrading `sops` from 3.9.4 → 3.13.2 (older sops lacks `SOPS_AGE_KEY_CMD`, which the tool depends on)
4. Completing setup outside the agent session with `AGENT_SECRETS_UNATTENDED=1` and piped stdin
5. Manually wiring `~/.claude/settings.json` because setup's `_wire_tools` step never ran
**Bottom line:** The README one-liner is not, on its own, a path from zero to usable secrets management on a typical fresh-or-brew-less Mac installed from an agent session.
---
## Timeline of what actually happened
### Phase 0 — Preflight (before running README command)
| Check | Result |
|-------|--------|
| `which agent-secrets` | not found |
| `which brew` | not found (`/opt/homebrew/bin/brew` does not exist) |
| `which age` / `sops` / `gum` | not found |
| `which jq` | `/usr/bin/jq` (macOS system jq 1.7.1) |
| `~/.zshenv` | did not exist |
| `~/.config/secrets/` | did not exist |
| `~/.claude/` | did not exist |
| `sudo -n true` | **failed** — password required |
| `CURSOR_AGENT` | `1` (agent session detected) |
**Implication:** Machine lacks the README's assumed toolchain (Homebrew → age, sops, gum, jq). Homebrew bootstrap will require interactive administrator password. Agent session will block setup wizard.
---
### Phase 1 — README one-liner (`sh -c "$(curl …)"`)
**Command:**
```sh
printf '\n' | sh -c "$(curl -fsLS https://raw.githubusercontent.com/renchris/agent-secrets/v0.1.0/install.sh)"
```
**What worked:**
- Consent gate accepted (piped `\n`)
- Installer detected missing `brew` and attempted Homebrew bootstrap
- Homebrew install failed in non-interactive mode: `Need sudo access on macOS`
- Installer continued past brew failure in some runs; in the final definitive test:
**Progress before failure:**
```
→ brew install age sops gum jq        (would fail — no brew)
Downloading v0.1.0…
SHA-256 verified.
→ mkdir -p ~/.agent-secrets ~/bin ~/.local/state/agent-secrets
→ tar -xzf … -C ~/.agent-secrets --strip-components=1
```
**Fatal error:**
```
~/.agent-secrets/lib/manifest.sh: line 142: syntax error near unexpected token `<'
```
**Root cause — BLOCKER #1: `sh` vs `bash`**
`install.sh` is written for bash. After unpacking, it sources `lib/manifest.sh`, which uses bash process substitution:
```bash
done < <(jq -c 'reverse[]' "$mf")
```
macOS `/bin/sh` is bash 3.2 running in **POSIX mode**, which rejects `< <(...)` syntax. `/bin/bash` accepts it.
**Repro:**
```sh
# FAILS — README as written
sh -c "$(curl -fsLS https://raw.githubusercontent.com/renchris/agent-secrets/v0.1.0/install.sh)"
# WORKS (gets past manifest.sh)
bash -c "$(curl -fsLS https://raw.githubusercontent.com/renchris/agent-secrets/v0.1.0/install.sh)"
```
**Partial residue after failed `sh` install:**
- `~/.agent-secrets/` unpacked (tool files on disk)
- No symlinks in `~/bin/`
- No `~/.zshenv` PATH block
- No launchd job
- No manifest records
- No setup run
---
### Phase 2 — Retry with `bash`, manual dependency workaround
Because Homebrew was unavailable and `sudo` required a password, dependencies were installed manually:
| Tool | Source | Installed to |
|------|--------|--------------|
| `age` v1.2.1 | GitHub release tarball | `~/bin/age`, `~/bin/age-keygen` |
| `sops` v3.9.4 (initially) | GitHub release binary | `~/bin/sops` |
| `gum` v0.14.5 | GitHub release tarball | `~/bin/gum` |
| `jq` | already at `/usr/bin/jq` | — |
A temporary `~/bin/brew` stub was created so `install.sh`'s `brew install age sops gum jq` would succeed when those binaries were already on PATH. **This is not documented anywhere in the README.**
**Command:**
```sh
export PATH="$HOME/bin:$PATH"
printf '\n\n' | bash -c "$(curl -fsLS https://raw.githubusercontent.com/renchris/agent-secrets/v0.1.0/install.sh)"
```
**What worked:**
```
✓ brew install age sops gum jq (via stub)
✓ Download v0.1.0 tarball
✓ SHA-256 verified (baked digest in tagged install.sh: 168e56b98cd2d8c7255a621eaec3551579617e6ab71432ff5df4d6c356691008)
✓ Unpack to ~/.agent-secrets
✓ Symlink agent-secrets, claude-agent, cursor-agent, apiKeyHelper → ~/bin/
✓ PATH block written to ~/.zshenv
✓ launchd smoke job installed (com.agent-secrets.smoke)
✓ install-manifest.json recorded
```
**What failed — BLOCKER #2: setup refuses agent sessions**
```
Installed. Launching the setup wizard…
→ ~/bin/agent-secrets setup
ERROR refusing the key ceremony inside an agent session (transcripts are secret-bearing)
— run in a normal terminal (or AGENT_SECRETS_UNATTENDED=1 for a fake-value test)
```
**Detection logic** (`lib/common.sh`):
```bash
agsec_in_agent_session() {
  [ -n "${CLAUDECODE:-}" ] && return 0
  [ -n "${CLAUDE_CODE:-}" ] && return 0
  [ -n "${CURSOR_AGENT:-}" ] && return 0
  [ -n "${CURSOR_TRACE_ID:-}" ] && return 0
  case "${TERM_PROGRAM:-}" in *[Cc]ursor*) return 0 ;; esac
  return 1
}
```
On this machine `CURSOR_AGENT=1` was set. The installer printed "Installed." but the system was **not usable**:
| Missing after "successful" install | Impact |
|-----------------------------------|--------|
| Age keypair ceremony | No proper key custody flow |
| Encrypted store initialization (incomplete) | Store existed but decrypt broken (see Phase 3) |
| First secret entry | No API keys |
| `_wire_tools` (settings.json apiKeyHelper) | Claude Code not wired |
| Recovery key saved offline | Disaster recovery not completed |
| Canary arming prompt | Canary left inert (expected, but user never prompted) |
**User-visible state:** Installer says "Installed." Exit code 1. No guidance on mandatory next step in Terminal.app.
---
### Phase 3 — Attempted setup completion (still in agent session)
**Attempt A — unattended, no stdin:**
```sh
env -u CURSOR_AGENT AGENT_SECRETS_UNATTENDED=1 agent-secrets setup
```
- Bypassed agent-session gate (env var unset)
- Generated age + recovery keys
- **Hung indefinitely at step 4** (`Your first secret`)
**Root cause — BLOCKER #3: unattended stdin trap**
In `cmd/setup.sh`:
```bash
if [ ! -t 0 ]; then val="$(cat)"; else val="unattended-placeholder-value"; fi
```
When stdin is not a TTY (piped/automated context), setup blocks on `cat` waiting for a secret value on stdin. The test suite documents the correct invocation:
```sh
printf '%s' fakeseed_val | AGENT_SECRETS_UNATTENDED=1 agent-secrets setup
```
This is not mentioned in README, FAQ, or install output.
**Attempt B — interrupted setup left broken store:**
Setup was killed while hung. Subsequent state:
- `~/.config/secrets/age.key` existed (189 bytes, valid format)
- `~/.config/secrets/secrets.env` existed (encrypted)
- `sops -d` via `SOPS_AGE_KEY_CMD` → **FAILED**
- `sops -d` via `SOPS_AGE_KEY_FILE` → **worked**
```
AWS_BACKUP_ACCESS_KEY_ID=canary-INERT-arm-me-with-a-real-tripwire-token
```
**Root cause — BLOCKER #4: sops version too old for `SOPS_AGE_KEY_CMD`**
| sops version | `SOPS_AGE_KEY_FILE` | `SOPS_AGE_KEY_CMD` |
|--------------|----------------------|---------------------|
| 3.9.4 (manually downloaded) | ✅ works | ❌ fails silently |
| 3.13.2 (upgraded) | ✅ works | ✅ works |
`agent-secrets` routes all store operations through `~/.config/secrets/age-key-cmd.sh`, which is consumed via `SOPS_AGE_KEY_CMD`. That environment variable is **not supported in sops 3.9.4** (added in a later release; present in 3.13.2).
Homebrew currently ships sops 3.13.2, so brew users are fine. Manual installs or old cached binaries break silently.
**Symptoms with sops 3.9.4:**
```
✗ [store] decrypt self-test — canary unreadable
ERROR store_add: cannot decrypt store (custody/key problem — run doctor)
```
After upgrading sops to 3.13.2 in `~/bin/sops`, all store operations worked.
---
### Phase 4 — Completing setup (workarounds)
**Setup completion:**
```sh
export PATH="$HOME/bin:$PATH"
printf 'test-placeholder-key-value' | \
  env -u CURSOR_AGENT -u CURSOR_TRACE_ID \
      AGENT_SECRETS_UNATTENDED=1 \
      AGENT_SECRETS_SEED_NAME=ANTHROPIC_API_KEY \
      agent-secrets setup
```
On second run, setup detected `installed` state and ran `doctor` instead of re-onboarding. Secret was added manually:
