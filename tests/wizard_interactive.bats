#!/usr/bin/env bats
# tests/wizard_interactive.bats — regression locks for the INTERACTIVE wizard paths, from the
# 2026-08-16 failed first-run (docs/plans/ONBOARDING_UX_REBUILD.md). F3 = the [4/7] abort;
# F2 = the unverified recovery-key delete. The screen functions are sourced directly (setup.sh's
# execute-only guard) and driven with canned stdin — deterministic, no PTY. Synthetic-HOME only.
load test_helper

# Source the wizard's screen functions and run ONE of them with canned stdin.
# $1 = printf-format canned input; rest = function + args.
_wiz() {
  local input="$1"; shift
  export AGENT_SECRETS_LIB="$REPO_ROOT/lib"
  printf '%b' "$input" | bash -c '. "$REPO_ROOT/cmd/setup.sh"; "$@"' _ "$@"
}

setup_file() { :; }

# ---- F3: [4/7] must never abort the wizard -----------------------------------------------------

@test "F3: empty value at the custom-secret prompt SKIPS after one retry — no abort (the author's crash)" {
  export AGENT_SECRETS_LIB="$REPO_ROOT/lib"
  # menu 3 (custom) → name → empty value → empty again ⇒ skip. Pre-fix: store_add's fail-closed
  # die killed the whole wizard here (set -e), stranding screens 5–7.
  run _wiz '3\nCODA_API_TOKEN\n\n\n' _first_secret
  [ "$status" -eq 0 ]
  [[ "$output" == *"clipboard may be empty"* ]] || return 1     # names the real cause
  [[ "$output" == *"agent-secrets add CODA_API_TOKEN"* ]] || return 1  # hands over the later path
  [[ "$output" != *"ERROR"* ]] || return 1                      # no store_add die reached the user
}

@test "F3: empty once then a real value on the retry stores it (value never surfaced)" {
  setup_store
  run _wiz '3\nCODA_API_TOKEN\n\nval-regression-f3\n' _first_secret
  [ "$status" -eq 0 ]
  [[ "$output" == *"stored CODA_API_TOKEN"* ]] || return 1
  [[ "$output" != *"val-regression-f3"* ]] || return 1
  run bash -c '. "$REPO_ROOT/lib/common.sh"; . "$REPO_ROOT/lib/keychain.sh"; . "$REPO_ROOT/lib/store.sh"; store_has CODA_API_TOKEN'
  [ "$status" -eq 0 ]
}

@test "F3: the menu offers an explicit skip — finishing setup without a first secret is a supported path" {
  export AGENT_SECRETS_LIB="$REPO_ROOT/lib"
  run _wiz '4\n' _first_secret
  [ "$status" -eq 0 ]
  [[ "$output" == *"skip for now"* ]] || return 1
  [[ "$output" == *"Skipped"* ]] || return 1
}

@test "F3: an invalid custom NAME re-prompts instead of reaching store_add's fatal die" {
  setup_store
  run _wiz '3\nBAD-NAME\nGOOD_NAME\nval-regression-name\n' _first_secret
  [ "$status" -eq 0 ]
  [[ "$output" == *"invalid name 'BAD-NAME'"* ]] || return 1
  [[ "$output" == *"stored GOOD_NAME"* ]] || return 1
}

@test "F3: an empty canary-token paste skips the arming — never aborts [4/7]" {
  setup_store
  run _wiz 'y\n\n\n' _arm_canary
  [ "$status" -eq 0 ]
  [[ "$output" == *"skipped"* ]] || return 1
  [[ "$output" != *"ERROR"* ]] || return 1
}

# ---- F2: no destructive delete on an unverified assertion --------------------------------------

# Mint a throwaway recovery keypair under the synthetic HOME; echoes the private-key line.
_mint_rec() {
  export AGENT_SECRETS_LIB="$REPO_ROOT/lib"
  mkdir -p "$AGENT_SECRETS_HOME/.config/secrets"
  age-keygen -o "$AGENT_SECRETS_HOME/.config/secrets/recovery.key" 2>/dev/null
  grep -m1 '^AGE-SECRET-KEY-' "$AGENT_SECRETS_HOME/.config/secrets/recovery.key"
}

@test "F2: a WRONG paste-back keeps recovery.key on disk — the delete needs verified proof (the loss lock)" {
  _mint_rec >/dev/null
  # Pre-rebuild, a bare default-y confirm deleted the file with zero verification.
  # 'y' clears the opt-in gate ("Save it off this Mac now?"), then two wrong pastes.
  run _wiz 'y\nAGE-SECRET-KEY-1WRONGWRONGWRONG\nAGE-SECRET-KEY-1WRONGAGAIN\n' \
      _recovery_handoff "$AGENT_SECRETS_HOME/.config/secrets/recovery.key"
  [ "$status" -eq 0 ]
  [ -f "$AGENT_SECRETS_HOME/.config/secrets/recovery.key" ]        # NOT deleted
  [[ "$output" == *"the key stays where it is safe"* ]] || return 1
  [[ "$output" == *"didn't match"* ]] || return 1
}

@test "F2: two EMPTY entries keep recovery.key on disk (skip is safe, never destructive)" {
  _mint_rec >/dev/null
  run _wiz 'y\n\n\n' _recovery_handoff "$AGENT_SECRETS_HOME/.config/secrets/recovery.key"
  [ "$status" -eq 0 ]
  [ -f "$AGENT_SECRETS_HOME/.config/secrets/recovery.key" ]
  [[ "$output" == *"nothing was pasted"* ]] || return 1
}

@test "F2: a VERIFIED paste-back deletes the on-disk copy (and never echoes the key)" {
  local keyline; keyline="$(_mint_rec)"
  run _wiz "y\n${keyline}\n" _recovery_handoff "$AGENT_SECRETS_HOME/.config/secrets/recovery.key"
  [ "$status" -eq 0 ]
  [ ! -f "$AGENT_SECRETS_HOME/.config/secrets/recovery.key" ]      # verified ⇒ removed
  [[ "$output" == *"verified saved"* ]] || return 1
  [[ "$output" != *"$keyline"* ]] || return 1                      # names-only: key never surfaced
}

@test "recovery: declining the offer is a first-class answer — file kept, no failure tone, no prompts" {
  _mint_rec >/dev/null
  run _wiz 'n\n' _recovery_handoff "$AGENT_SECRETS_HOME/.config/secrets/recovery.key"
  [ "$status" -eq 0 ]
  [ -f "$AGENT_SECRETS_HOME/.config/secrets/recovery.key" ]        # kept, untouched
  [[ "$output" == *"Later it is"* ]] || return 1
  [[ "$output" != *"from where you saved it"* ]] || return 1       # the paste ceremony never ran
}

# ---- End-to-end: the full interactive wizard on a real PTY (expect) ----------------------------
# These drive `bin/agent-secrets setup` exactly as a human at a terminal — the path the unattended
# suite can never cover, and the one that failed in the field. NOTE: always answer 'n' to the
# Keychain offer here — the mock `security -w` reads stdin to EOF and would swallow the script.

@test "E2E: the author's failed first-run now reaches [6/6] — empty pastes everywhere, nothing aborts, nothing destroyed" {
  command -v expect >/dev/null 2>&1 || skip "expect not available"
  cat >"$AGENT_SECRETS_HOME/drive.exp" <<'EOF'
set timeout 30
spawn env -u CLAUDECODE -u CLAUDE_CODE -u CURSOR_AGENT -u CURSOR_TRACE_ID -u TERM_PROGRAM bash $env(REPO_ROOT)/bin/agent-secrets setup
# AFTER spawn, so the handlers bind to the wizard's spawn_id — declared before spawn they bind
# to the pre-spawn id and every timeout is SILENT (measured: a desync then cascades into a
# forever-blocking `wait`, hanging the whole suite).
expect_after { timeout { puts "\nDESYNC-TIMEOUT"; exit 90 } eof { puts "\nEARLY-EOF"; exit 91 } }
# `sleep 1` before answering any HIDDEN prompt: bash's `read -s` termios switch FLUSHES queued
# input, so an answer sent in the µs between prompt-print and read-start is silently discarded
# (measured — the race hung the wizard at the second prove-read).
expect "Save it off this Mac now?" { send "y\r" }
expect "RECOVERY key (from where you saved it)" { sleep 1; send "\r" }
expect "RECOVERY key (from where you saved it)" { sleep 1; send "\r" }
expect "Populate your login Keychain" { send "n\r" }
expect -ex {choose [1-4, Enter = 1]:} { send "3\r" }
expect "name:" { send "CODA_API_TOKEN\r" }
expect "Value for CODA_API_TOKEN" { sleep 1; send "\r" }
expect "Value for CODA_API_TOKEN" { sleep 1; send "\r" }
expect "Arm it now?" { send "n\r" }
expect eof { }
catch wait result
exit [lindex $result 3]
EOF
  run expect "$AGENT_SECRETS_HOME/drive.exp"
  [ "$status" -eq 0 ]
  [[ "$output" == *"You're set up"* ]] || return 1                                # [6/6] reached
  [ -f "$AGENT_SECRETS_HOME/.config/secrets/recovery.key" ]                       # unverified ⇒ KEPT (F2)
  [ -L "$AGENT_SECRETS_HOME/bin/claude-agent" ]                                   # screen 5 ran
  [ -L "$AGENT_SECRETS_HOME/bin/apiKeyHelper" ]
  grep -q done "$AGENT_SECRETS_HOME/.local/state/agent-secrets/wizard-state.json" # wizard state: done
}

@test "E2E: happy path — verified recovery paste-back + a stored first secret, to [6/6]" {
  command -v expect >/dev/null 2>&1 || skip "expect not available"
  cat >"$AGENT_SECRETS_HOME/drive.exp" <<'EOF'
set timeout 30
spawn env -u CLAUDECODE -u CLAUDE_CODE -u CURSOR_AGENT -u CURSOR_TRACE_ID -u TERM_PROGRAM bash $env(REPO_ROOT)/bin/agent-secrets setup
# See the sibling test for why expect_after comes AFTER spawn and hidden prompts get `sleep 1`.
expect_after { timeout { puts "\nDESYNC-TIMEOUT"; exit 90 } eof { puts "\nEARLY-EOF"; exit 91 } }
expect "Save it off this Mac now?"
# The test's "password manager": read the key line from the on-disk file the wizard just minted.
set fh [open "$env(AGENT_SECRETS_HOME)/.config/secrets/recovery.key" r]
set keyline ""
while {[gets $fh l] >= 0} { if {[string match AGE-SECRET-KEY-* $l]} { set keyline $l } }
close $fh
send "y\r"
expect "RECOVERY key (from where you saved it)" { sleep 1; send -- "$keyline\r" }
expect "Populate your login Keychain" { send "n\r" }
expect -ex {choose [1-4, Enter = 1]:} { send "1\r" }
expect "Value for ANTHROPIC_API_KEY" { sleep 1; send "e2e-val-regression\r" }
expect "Arm it now?" { send "n\r" }
expect eof { }
catch wait result
exit [lindex $result 3]
EOF
  run expect "$AGENT_SECRETS_HOME/drive.exp"
  [ "$status" -eq 0 ]
  [[ "$output" == *"verified saved"* ]] || return 1
  [[ "$output" == *"You're set up"* ]] || return 1
  [ ! -f "$AGENT_SECRETS_HOME/.config/secrets/recovery.key" ]      # verified ⇒ removed
  [[ "$output" != *"e2e-val-regression"* ]] || return 1            # hidden read: value never echoed
  run agsec list
  [[ "$output" == *"ANTHROPIC_API_KEY"* ]] || return 1             # the secret actually landed
}
