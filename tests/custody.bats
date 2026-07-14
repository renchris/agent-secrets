#!/usr/bin/env bats
# tests/custody.bats — bootstrap-key custody: primary vs the degraded-custody drill.
load test_helper

@test "primary custody: Keychain mock succeeds -> kc_status primary" {
  export AGENT_SECRETS_LIB="$REPO_ROOT/lib"
  # shellcheck source=/dev/null
  . "$REPO_ROOT/lib/common.sh"; . "$REPO_ROOT/lib/keychain.sh"
  mkdir -p "$(agsec_config_dir)"
  printf 'AGE-SECRET-KEY-FAKE' | kc_add
  run kc_status
  [ "$status" -eq 0 ]
  [ "$output" = "primary" ]
}

@test "degraded custody drill: Keychain read fails -> falls through to file, doctor says degraded not fail" {
  setup_store
  # Simulate a Keychain read failure (post-upgrade regression class).
  export AGENT_SECRETS_MOCK_KC_FAIL=1
  run kc_status
  [ "$output" = "degraded (file custody)" ]
  # doctor must report degraded, NOT a hard failure that blocks.
  run agsec doctor
  [[ "$output" == *"degraded (file custody)"* ]] || return 1
}

@test "keychain-smoke: passes when the mock yields the key, fails cleanly when it doesn't" {
  export AGENT_SECRETS_LIB="$REPO_ROOT/lib"
  # shellcheck source=/dev/null
  . "$REPO_ROOT/lib/common.sh"; . "$REPO_ROOT/lib/keychain.sh"
  mkdir -p "$(agsec_config_dir)"; printf 'AGE-SECRET-KEY-FAKE' | kc_add
  run bash "$REPO_ROOT/scripts/keychain-smoke.sh"
  [ "$status" -eq 0 ]
  [ -z "$output" ]   # prints NOTHING — exit code is the whole result
  AGENT_SECRETS_MOCK_KC_FAIL=1 run bash "$REPO_ROOT/scripts/keychain-smoke.sh"
  [ "$status" -ne 0 ]
}

@test "setup --keychain restores primary custody from the file fallback (v2 feedback R2)" {
  setup_store                                  # file custody only — the mock Keychain has no record yet
  run kc_status
  [ "$output" = "degraded (file custody)" ]
  # UNATTENDED bypasses the agent-session refusal; the key is piped so the mock `security -w` reads it.
  run bash -c "cat '$AGENT_SECRETS_HOME/.config/secrets/age.key' | AGENT_SECRETS_UNATTENDED=1 bash '$REPO_ROOT/bin/agent-secrets' setup --keychain"
  [ "$status" -eq 0 ]
  [[ "$output" == *"primary"* ]] || return 1
  run kc_status
  [ "$output" = "primary" ]
}

@test "setup --keychain is idempotent: primary custody means nothing to do (exit 0)" {
  export AGENT_SECRETS_LIB="$REPO_ROOT/lib"
  # shellcheck source=/dev/null
  . "$REPO_ROOT/lib/common.sh"; . "$REPO_ROOT/lib/keychain.sh"
  mkdir -p "$(agsec_config_dir)"
  printf 'AGE-SECRET-KEY-FAKE' | kc_add       # populates BOTH sinks → primary
  run bash -c "AGENT_SECRETS_UNATTENDED=1 bash '$REPO_ROOT/bin/agent-secrets' setup --keychain </dev/null"
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing to do"* ]] || return 1
}

@test "setup --keychain with no key on the machine routes to setup (exit 1)" {
  run bash -c "AGENT_SECRETS_UNATTENDED=1 bash '$REPO_ROOT/bin/agent-secrets' setup --keychain </dev/null"
  [ "$status" -eq 1 ]
  [[ "$output" == *"agent-secrets setup"* ]] || return 1
}

@test "setup --keychain: write lands but read-back still files → honest note, exit 0 (three-way _kc_populate)" {
  setup_store
  # The Keychain WRITE succeeds (mock add stores) but every READ fails → custody never flips to primary.
  # _kc_populate must distinguish this (return 1) from an outright write failure (return 2): a soft note,
  # exit 0 — not the hard die. Locks the shared core the ceremony's _kc_offer also relies on.
  export AGENT_SECRETS_MOCK_KC_FAIL=1
  run bash -c "cat '$AGENT_SECRETS_HOME/.config/secrets/age.key' | AGENT_SECRETS_UNATTENDED=1 bash '$REPO_ROOT/bin/agent-secrets' setup --keychain"
  [ "$status" -eq 0 ]
  [[ "$output" == *"read-back still falls to the file"* ]] || return 1
}
