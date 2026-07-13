#!/usr/bin/env bats
# tests/doctor.bats — health-check robustness + gates. Names-only, never crashes on missing setup.
load test_helper

@test "doctor on a bare HOME: all checks names-only, exit 1, no crash, no value" {
  run agsec doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"[custody]"* ]]
  [[ "$output" == *"[store]"* ]]
  [[ "$output" == *"[injection]"* ]]
}

@test "doctor with a store present: store category goes green" {
  setup_store
  run agsec doctor
  [[ "$output" == *"store"* ]]
  [[ "$output" == *"present"* ]]
}

@test "doctor --format=json is valid JSON with no value" {
  setup_store
  run bash -c "bash '$REPO_ROOT/bin/agent-secrets' doctor --format=json | jq -e . >/dev/null && echo VALID"
  [[ "$output" == *"VALID"* ]]
}

@test "doctor --format=json is the documented OBJECT schema {checks:[{category,status,check,detail}],exit}" {
  setup_store
  # The exact shape lib/help.sh + AGENTS.md promise: an object with a checks[] array + an exit int,
  # each row carrying category/status/check/detail, status ∈ ok|attn|bad. The AGENTS.md recipe
  # (.checks[] | select(.status=="bad")) must be well-typed against it.
  run bash -c "bash '$REPO_ROOT/bin/agent-secrets' doctor --format=json | jq -e '
    (.checks | type == \"array\") and (.exit | type == \"number\") and
    (.checks[0] | has(\"category\") and has(\"status\") and has(\"check\") and has(\"detail\")) and
    ([.checks[].status] | all(. as \$s | [\"ok\",\"attn\",\"bad\"] | index(\$s) != null)) and
    ([.checks[] | select(.status==\"bad\")] | type == \"array\")'"
  [ "$status" -eq 0 ]
}

@test "doctor rejects an unknown flag with a usage error (exit 2)" {
  run bash "$REPO_ROOT/bin/agent-secrets" doctor --bogus
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown flag"* ]]
}

@test "doctor flags the unarmed canary as inert, then green once armed" {
  setup_store                                   # seeds the INERT placeholder canary
  run agsec doctor
  [[ "$output" == *"INERT"* ]]                  # honest: no false 'active honeytoken' assurance
  printf 'real-tripwire-token-xyz' | store_add "$AGENT_SECRETS_CANARY_NAME"   # arm it
  run agsec doctor
  [[ "$output" == *"armed"* ]]
  [[ "$output" != *"INERT"* ]]
}

@test "doctor --gates runs and reports the c/d/e gates" {
  setup_store
  run agsec doctor --gates
  [ "$status" -eq 0 ] || [ "$status" -eq 1 ]   # gate outcomes are informational, not a hard fail
  [[ "$output" == *"gate"* ]] || [[ "$output" == *"Keychain"* ]] || [[ "$output" == *"exec-env"* ]]
}
