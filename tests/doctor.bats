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

@test "doctor does NOT crash on a broken sops (D1: unguarded version capture under set -e)" {
  setup_store
  # A present-but-nonfunctional sops (EDR-blocked / wrong-arch / shim) exits nonzero on --version.
  shim="$AGENT_SECRETS_HOME/brokenbin"; mkdir -p "$shim"
  printf '#!/bin/sh\nexit 3\n' > "$shim/sops"; chmod +x "$shim/sops"
  run env PATH="$shim:$PATH" bash "$REPO_ROOT/bin/agent-secrets" doctor --format=json
  # Must still emit valid JSON (not an empty/crashed output) and flag sops bad.
  echo "$output" | tail -1 | jq -e '.checks | map(select(.category=="toolchain" and .check=="sops")) | .[0].status=="bad"' >/dev/null
}

@test "doctor injection verifies settings.json is wired to our apiKeyHelper (RT5b)" {
  setup_store
  bd="$AGENT_SECRETS_HOME/bin"; mkdir -p "$bd"
  ln -sf "$REPO_ROOT/bin/apiKeyHelper" "$bd/apiKeyHelper"
  ln -sf "$REPO_ROOT/bin/claude-agent" "$bd/claude-agent"
  ln -sf "$REPO_ROOT/bin/cursor-agent" "$bd/cursor-agent"
  printf '%s' 'sk-ant-x' | agsec add ANTHROPIC_API_KEY
  mkdir -p "$AGENT_SECRETS_HOME/.claude"
  # unwired settings.json → the new row must report "not wired"
  printf '{}\n' > "$AGENT_SECRETS_HOME/.claude/settings.json"
  run agsec doctor
  [[ "$output" == *"settings.json apiKeyHelper"* ]]
  [[ "$output" == *"not wired"* ]]
  # wired → reports "wired"
  jq -n --arg h "$bd/apiKeyHelper" '{apiKeyHelper:$h}' > "$AGENT_SECRETS_HOME/.claude/settings.json"
  run agsec doctor
  [[ "$output" == *"settings.json apiKeyHelper — wired"* ]]
}
