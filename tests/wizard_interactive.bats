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

@test "menu: four bad answers cancel the first secret — setup continues, nothing stored" {
  run _wiz '9\n9\n9\n9\n' _first_secret
  [ "$status" -eq 0 ]
  [[ "$output" == *"Enter a number from 1 to 4"* ]] || return 1
  [[ "$output" == *"Skipped"* ]] || return 1
  [ ! -e "$AGENT_SECRETS_HOME/.config/secrets/secrets.env" ]
}

@test "menu: EOF at the first-secret menu skips — nothing stored" {
  run _wiz '' _first_secret
  [ "$status" -eq 0 ]
  [[ "$output" == *"Skipped"* ]] || return 1
  [[ "$output" != *"Value for"* ]] || return 1                   # no value prompt under an unchosen name
  [ ! -e "$AGENT_SECRETS_HOME/.config/secrets/secrets.env" ]
}

@test "menu: a bad answer asks again, then the explicit skip skips" {
  run _wiz '7\n4\n' _first_secret
  [ "$status" -eq 0 ]
  [[ "$output" == *"Enter a number from 1 to 4"* ]] || return 1
  [[ "$output" == *"Skipped"* ]] || return 1
  [ ! -e "$AGENT_SECRETS_HOME/.config/secrets/secrets.env" ]
}

@test "F3: an invalid custom NAME re-prompts instead of reaching store_add's fatal die" {
  setup_store
  run _wiz '3\nBAD-NAME\nGOOD_NAME\nval-regression-name\n' _first_secret
  [ "$status" -eq 0 ]
  [[ "$output" == *"invalid name 'BAD-NAME'"* ]] || return 1
  [[ "$output" == *"stored GOOD_NAME"* ]] || return 1
}

# (The canary-arming prompt was removed from the wizard on 2026-09-17 — a default-`no` keystroke
# almost every first run spent on Enter. Arming is `agent-secrets add <canary NAME>`, which doctor
# names; the F3 ladder it shared with the first secret is still locked by the tests above.)

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
# suite can never cover, and the one that failed in the field. The Keychain populate no longer
# prompts (it goes file → pipe → `security -i`, and the mock honours `-i`), and the canary prompt
# is gone — so the drives below answer only the recovery save and the first-secret screen.

@test "E2E: the author's failed first-run now reaches [6/6] — empty pastes everywhere, nothing aborts, nothing destroyed" {
  command -v expect >/dev/null 2>&1 || skip "expect not available"
  cat >"$AGENT_SECRETS_HOME/drive.exp" <<'EOF'
# One wall-clock bound on the whole drive, and no per-expect timeout. A timeout action in expect_after
# never fires on this expect, wherever it is declared (measured 2026-11-07, expect 5.45): a timed-out
# `expect` returns silently, so a slow wizard under load lost its output tail, then blocked forever in
# `wait` while the wizard sat in kernel exit waiting for its pty to drain. An early exit makes the next
# expect or send fail, which also fails the drive.
set timeout -1
after 900000 { puts "\nDESYNC-TIMEOUT"; exit 90 }
spawn env -u CLAUDECODE -u CLAUDE_CODE -u CURSOR_AGENT -u CURSOR_TRACE_ID -u TERM_PROGRAM bash $env(REPO_ROOT)/bin/agent-secrets setup
# `sleep 1` before answering any HIDDEN prompt: bash's `read -s` termios switch FLUSHES queued
# input, so an answer sent in the µs between prompt-print and read-start is silently discarded
# (measured — the race hung the wizard at the second prove-read).
expect "Save it off this Mac now?" { send "y\r" }
expect "RECOVERY key (from where you saved it)" { sleep 1; send "\r" }
expect "RECOVERY key (from where you saved it)" { sleep 1; send "\r" }
expect -ex {choose [1-4, Enter = 1]:} { send "3\r" }
expect "name:" { send "CODA_API_TOKEN\r" }
expect "Value for CODA_API_TOKEN" { sleep 1; send "\r" }
expect "Value for CODA_API_TOKEN" { sleep 1; send "\r" }
expect eof { }
catch wait result
# A signal death reads as 0 in field 3 (measured), so it must not pass as a clean exit.
if {[llength $result] > 4} { puts "\nWIZARD-KILLED $result"; exit 92 }
exit [lindex $result 3]
EOF
  run expect "$AGENT_SECRETS_HOME/drive.exp"
  [ "$status" -eq 0 ]
  [[ "$output" == *"You're set up"* ]] || return 1                                # [6/6] reached
  [[ "$output" == *"Keychain custody — primary"* ]] || return 1                   # no paste, no prompt
  [ -f "$AGENT_SECRETS_HOME/.config/secrets/recovery.key" ]                       # unverified ⇒ KEPT (F2)
  [ -L "$AGENT_SECRETS_HOME/bin/claude-agent" ]                                   # screen 4 ran
  [ -L "$AGENT_SECRETS_HOME/bin/apiKeyHelper" ]
  grep -q done "$AGENT_SECRETS_HOME/.local/state/agent-secrets/wizard-state.json" # wizard state: done
}

@test "E2E: happy path — verified recovery paste-back + a stored first secret, to [6/6]" {
  command -v expect >/dev/null 2>&1 || skip "expect not available"
  cat >"$AGENT_SECRETS_HOME/drive.exp" <<'EOF'
# See the sibling test for why there is one wall-clock bound and why hidden prompts get `sleep 1`.
set timeout -1
after 900000 { puts "\nDESYNC-TIMEOUT"; exit 90 }
spawn env -u CLAUDECODE -u CLAUDE_CODE -u CURSOR_AGENT -u CURSOR_TRACE_ID -u TERM_PROGRAM bash $env(REPO_ROOT)/bin/agent-secrets setup
expect "Save it off this Mac now?"
# On a terminal the recovery offer is the wizard's FIRST prompt (mode matrix, tty row).
if {[regexp {\[[yY]/[nN]\]|choose \[} $expect_out(buffer)]} { puts "\nEARLIER-PROMPT"; exit 93 }
# The test's "password manager": read the key line from the on-disk file the wizard just minted.
set fh [open "$env(AGENT_SECRETS_HOME)/.config/secrets/recovery.key" r]
set keyline ""
while {[gets $fh l] >= 0} { if {[string match AGE-SECRET-KEY-* $l]} { set keyline $l } }
close $fh
send "y\r"
expect "RECOVERY key (from where you saved it)" { sleep 1; send -- "$keyline\r" }
expect -ex {choose [1-4, Enter = 1]:} { send "1\r" }
expect "Value for ANTHROPIC_API_KEY" { sleep 1; send "e2e-val-regression\r" }
expect eof { }
catch wait result
if {[llength $result] > 4} { puts "\nWIZARD-KILLED $result"; exit 92 }
exit [lindex $result 3]
EOF
  run expect "$AGENT_SECRETS_HOME/drive.exp"
  [ "$status" -eq 0 ]
  [[ "$output" == *"verified saved"* ]] || return 1
  [[ "$output" == *"You're set up"* ]] || return 1
  [ ! -f "$AGENT_SECRETS_HOME/.config/secrets/recovery.key" ]      # verified ⇒ removed
  [[ "$output" != *"e2e-val-regression"* ]] || return 1            # hidden read: value never echoed
  [[ "$output" == *"wired apiKeyHelper"* ]] || return 1            # the key IS stored ⇒ the helper is wired
  [[ "$output" == *"Run this again without prompts:"* ]] || return 1          # the no-prompt replay
  [[ "$output" == *"setup --headless --no-discovery --import-env ANTHROPIC_API_KEY"* ]] || return 1
  run agsec list
  [[ "$output" == *"ANTHROPIC_API_KEY"* ]] || return 1             # the secret actually landed
}

# ---- restore: a signal mid-paste gives the terminal its echo back -------------------------------

@test "Ctrl-C during the hidden key paste restores terminal echo" {
  command -v expect >/dev/null 2>&1 || skip "expect not available"
  # A non-interactive outer shell, not `bash -i`: an interactive bash restores the terminal itself
  # when a foreground job dies of a signal, which would hide a missing handler. Here the outer shell
  # runs `stty -a` only if restore_flow handled the INT itself (a SIGINT death would end it too).
  cat >"$AGENT_SECRETS_HOME/drive.exp" <<'EOF'
set timeout -1
after 900000 { puts "\nDESYNC-TIMEOUT"; exit 90 }
spawn bash --norc --noprofile -c {cd "$REPO_ROOT"; ( . lib/common.sh; . lib/ui.sh; . lib/keychain.sh; . lib/store.sh; . lib/restore.sh; restore_flow ); echo "RC=$?"; stty -a}
# The prompt prints after echo is off and the handlers are set. Under load bash 3.2 can still swallow
# a SIGINT that lands while it reaps a subshell, and then blocks in read, so wait a second and repeat
# the Ctrl-C every 20 s until restore_flow returns. The repeat stops at RC= so it cannot hit stty -a.
proc again {} { global again_id; catch { send "\003" }; set again_id [after 20000 again] }
expect "then press Ctrl-D:" { send "AGE-SECRET-KEY-1PARTIAL"; sleep 1; send "\003"; set again_id [after 20000 again] }
expect "RC=" { after cancel $again_id }
expect eof { }
catch wait result
if {[llength $result] > 4} { puts "\nDRIVE-KILLED $result"; exit 92 }
exit [lindex $result 3]
EOF
  run expect "$AGENT_SECRETS_HOME/drive.exp"
  [ "$status" -eq 0 ]
  [[ "$output" == *"RC=130"* ]] || return 1
  local lflags; lflags="$(printf '%s\n' "$output" | grep -m1 'lflags:')"
  [[ " $lflags " == *" echo "* ]] || { echo "echo still off: $lflags"; return 1; }
  [[ "$lflags" != *"-echo "* ]] || { echo "echo still off: $lflags"; return 1; }
  [[ "$output" != *"PARTIAL"* ]] || return 1                       # the paste was never echoed
}
