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
  [[ "$output" == *"degraded (file custody)"* ]]
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
