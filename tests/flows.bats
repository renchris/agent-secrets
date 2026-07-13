#!/usr/bin/env bats
# tests/flows.bats — wizard (unattended), run guard, cursor single-instance guard, restore drill.
load test_helper

@test "unattended wizard completes and seeds the first secret" {
  run bash -c "printf '%s' fakeseed_val | AGENT_SECRETS_UNATTENDED=1 bash '$REPO_ROOT/bin/agent-secrets' setup"
  [ "$status" -eq 0 ]
  [[ "$output" == *"set up"* ]]
  run agsec list
  [[ "$output" == *"ANTHROPIC_API_KEY"* ]]
  [[ "$output" != *"fakeseed_val"* ]]
}

@test "unattended wizard seeds from AGENT_SECRETS_SEED_VALUE with NO stdin (deterministic automation)" {
  run env AGENT_SECRETS_HOME="$AGENT_SECRETS_HOME" AGENT_SECRETS_UNATTENDED=1 \
      AGENT_SECRETS_SEED_NAME=OPENAI_API_KEY AGENT_SECRETS_SEED_VALUE=env-seed-xyz \
      bash "$REPO_ROOT/bin/agent-secrets" setup </dev/null
  [ "$status" -eq 0 ]
  run agsec list
  [[ "$output" == *"OPENAI_API_KEY"* ]]
  [[ "$output" != *"env-seed-xyz"* ]]     # value never surfaced
}

@test "unattended wizard cannot hang on an open-but-empty stdin (feedback BLOCKER #3)" {
  # Reproduce an agent session's inherited stdin: a pipe held OPEN with no data (never sends EOF). The
  # old val="\$(cat)" blocked here forever; the bounded read must fall through to the placeholder. A perl
  # fork+alarm hard-kills a genuine hang (exit 124) so the suite fails loudly instead of hanging.
  command -v perl >/dev/null 2>&1 || skip "perl needed for the timeout guard"
  local fifo="$AGENT_SECRETS_HOME/seed.fifo"; mkfifo "$fifo"
  exec 9<>"$fifo"                          # hold a writer end open with nothing written
  run perl -e 'my $p=fork; if(!$p){exec @ARGV or die} local $SIG{ALRM}=sub{kill "KILL",$p; exit 124}; alarm 20; waitpid $p,0; exit($? >> 8)' \
      env AGENT_SECRETS_HOME="$AGENT_SECRETS_HOME" AGENT_SECRETS_UNATTENDED=1 \
      bash "$REPO_ROOT/bin/agent-secrets" setup <"$fifo"
  exec 9>&-
  [ "$status" -eq 0 ]                      # 124 ⇒ it hung past the alarm (the old cat bug)
  run agsec list
  [[ "$output" == *"ANTHROPIC_API_KEY"* ]] # placeholder still seeded the default name
}

@test "wizard is idempotent: re-run mints no second key (resume)" {
  printf '%s' v1 | AGENT_SECRETS_UNATTENDED=1 bash "$REPO_ROOT/bin/agent-secrets" setup >/dev/null 2>&1
  local pub1; pub1=$(cat "$AGENT_SECRETS_HOME/.config/secrets/age.pub")
  printf '%s' v2 | AGENT_SECRETS_UNATTENDED=1 bash "$REPO_ROOT/bin/agent-secrets" setup >/dev/null 2>&1
  local pub2; pub2=$(cat "$AGENT_SECRETS_HOME/.config/secrets/age.pub")
  [ "$pub1" = "$pub2" ]
}

@test "wizard resumes after age.pub is lost — gates idempotency on the private key alone (no silent wedge)" {
  printf '%s' v1 | AGENT_SECRETS_UNATTENDED=1 bash "$REPO_ROOT/bin/agent-secrets" setup >/dev/null 2>&1
  local key1 pub1
  key1=$(cat "$AGENT_SECRETS_HOME/.config/secrets/age.key")
  pub1=$(cat "$AGENT_SECRETS_HOME/.config/secrets/age.pub")
  # age.pub is documented as a "non-secret recipient"; lose it (+ the wrapper, so state is 'partial' →
  # the key ceremony re-runs). Pre-fix: age-keygen refused to overwrite the key, `2>/dev/null` hid it,
  # set -e aborted → silent exit 1, permanent onboarding lockout.
  rm -f "$AGENT_SECRETS_HOME/.config/secrets/age.pub" "$AGENT_SECRETS_HOME/bin/claude-agent"
  run bash -c "printf '%s' v2 | AGENT_SECRETS_UNATTENDED=1 bash '$REPO_ROOT/bin/agent-secrets' setup"
  [ "$status" -eq 0 ]
  [ "$(cat "$AGENT_SECRETS_HOME/.config/secrets/age.key")" = "$key1" ]   # same private key kept, not re-minted
  [ "$(cat "$AGENT_SECRETS_HOME/.config/secrets/age.pub")" = "$pub1" ]   # public recipient re-derived, identical
}

@test "run without -- errors" {
  setup_store
  run agsec run printenv PATH
  [ "$status" -ne 0 ]
  [[ "$output" == *"--"* ]]
}

@test "cursor-agent single-instance guard blocks when Cursor is running" {
  setup_store
  install -m0755 "$REPO_ROOT/bin/cursor-agent" "$AGENT_SECRETS_HOME/cursor-agent"
  run env AGENT_SECRETS_MOCK_CURSOR_RUNNING=1 AGENT_SECRETS_ROOT="$REPO_ROOT" bash "$REPO_ROOT/bin/cursor-agent"
  [ "$status" -ne 0 ]
  [[ "$output" == *"quit"* ]] || [[ "$output" == *"running"* ]] || [[ "$output" == *"Cursor"* ]]
}

@test "restore drill: returning-user check + restore_flow decrypts via the saved key" {
  setup_store   # creates a store + writes the age.key
  export AGENT_SECRETS_LIB="$REPO_ROOT/lib"
  # shellcheck source=/dev/null
  . "$REPO_ROOT/lib/common.sh"; . "$REPO_ROOT/lib/keychain.sh"; . "$REPO_ROOT/lib/store.sh"; . "$REPO_ROOT/lib/ui.sh"; . "$REPO_ROOT/lib/restore.sh"
  run restore_returning_user_check
  [ "$output" = "installed" ] || [ "$output" = "partial" ]
  # Save the key, wipe custody, restore from the saved key alone -> store still decrypts.
  local saved; saved=$(cat "$(agsec_age_key_file)")
  rm -f "$(agsec_age_key_file)"
  run bash -c "printf '%s' '$saved' | { . '$REPO_ROOT/lib/common.sh'; . '$REPO_ROOT/lib/keychain.sh'; . '$REPO_ROOT/lib/store.sh'; . '$REPO_ROOT/lib/ui.sh'; . '$REPO_ROOT/lib/restore.sh'; restore_flow; }"
  [ "$status" -eq 0 ]
  [[ "$output" == *"verified"* ]] || [[ "$output" == *"decrypt"* ]]
}

@test "setup --restore recovers via the CLI: paste the saved key over a restored store -> decrypts" {
  setup_store
  export AGENT_SECRETS_LIB="$REPO_ROOT/lib"
  . "$REPO_ROOT/lib/common.sh"; . "$REPO_ROOT/lib/keychain.sh"; . "$REPO_ROOT/lib/store.sh"
  local saved; saved=$(cat "$(agsec_age_key_file)")
  rm -f "$(agsec_age_key_file)"                 # wipe local key custody; the encrypted store copy remains
  run bash -c "printf '%s' '$saved' | env -u CLAUDECODE -u CLAUDE_CODE -u CURSOR_AGENT -u CURSOR_TRACE_ID -u TERM_PROGRAM bash '$REPO_ROOT/bin/agent-secrets' setup --restore"
  [ "$status" -eq 0 ]
  [[ "$output" == *"verified"* ]] || [[ "$output" == *"decrypt"* ]]
  run store_extract "$AGENT_SECRETS_CANARY_NAME"   # store decryptable again after the CLI restore
  [ "$status" -eq 0 ]
}

@test "setup refuses to mint a new key over an existing store — sends you to --restore (no strand)" {
  setup_store
  export AGENT_SECRETS_LIB="$REPO_ROOT/lib"
  . "$REPO_ROOT/lib/common.sh"
  rm -f "$(agsec_age_key_file)"                 # store present, key gone: the strand scenario
  # Wipe the wizard state so restore_returning_user_check can't short-circuit to a health check.
  rm -f "$(agsec_wizard_state)" "$AGENT_SECRETS_HOME/bin/claude-agent"
  run bash -c "printf '%s' x | env -u CLAUDECODE -u CLAUDE_CODE -u CURSOR_AGENT -u CURSOR_TRACE_ID -u TERM_PROGRAM AGENT_SECRETS_UNATTENDED=1 bash '$REPO_ROOT/bin/agent-secrets' setup"
  [ "$status" -ne 0 ]
  [[ "$output" == *"--restore"* ]]              # directed to the restore path, not a silent strand
}
