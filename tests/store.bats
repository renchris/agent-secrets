#!/usr/bin/env bats
# tests/store.bats — store round-trip + the NAMES-ONLY invariant (the security backbone).
# All under synthetic AGENT_SECRETS_HOME with fake names. Real Keychain never touched (mock on PATH).
load test_helper

FAKE_NAME=FAKE_API_TOKEN
FAKE_VALUE=fakevalue_ROUNDTRIP_123

@test "add via stdin then list shows the name (never the value)" {
  setup_store
  printf '%s' "$FAKE_VALUE" | agsec add "$FAKE_NAME"
  run agsec list
  [ "$status" -eq 0 ]
  [[ "$output" == *"$FAKE_NAME"* ]]
  [[ "$output" != *"$FAKE_VALUE"* ]]
}

@test "run injects the value (length only; tool never displays it)" {
  setup_store
  printf '%s' "$FAKE_VALUE" | agsec add "$FAKE_NAME"
  run bash -c "bash '$REPO_ROOT/bin/agent-secrets' run -- printenv $FAKE_NAME | wc -c"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | tr -d ' ')" -gt 1 ]
}

@test "the store file on disk contains NO plaintext value" {
  setup_store
  printf '%s' "$FAKE_VALUE" | agsec add "$FAKE_NAME"
  run grep -c "$FAKE_VALUE" "$AGENT_SECRETS_HOME/.config/secrets/secrets.env"
  [ "$output" -eq 0 ]
}

@test "NAMES-ONLY: list + doctor never emit the value" {
  setup_store
  printf '%s' "$FAKE_VALUE" | agsec add "$FAKE_NAME"
  run bash -c "{ bash '$REPO_ROOT/bin/agent-secrets' list; bash '$REPO_ROOT/bin/agent-secrets' doctor; } 2>&1 | grep -c '$FAKE_VALUE'"
  [ "$output" -eq 0 ]
}

@test "the in-store canary is present after init" {
  setup_store
  run agsec list
  [[ "$output" == *"AWS_BACKUP_ACCESS_KEY_ID"* ]]
}

@test "list --format=json is valid and value-free" {
  setup_store
  printf '%s' "$FAKE_VALUE" | agsec add "$FAKE_NAME"
  run bash -c "bash '$REPO_ROOT/bin/agent-secrets' list --format=json | jq -e '.[].name' >/dev/null && echo VALID"
  [[ "$output" == *"VALID"* ]]
  run bash -c "bash '$REPO_ROOT/bin/agent-secrets' list --format=json | grep -c '$FAKE_VALUE'"
  [ "$output" -eq 0 ]
}

@test "add rejects an invalid NAME" {
  setup_store
  run bash -c "printf x | bash '$REPO_ROOT/bin/agent-secrets' add '1bad-name'"
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid name"* ]]
}

@test "list (text) survives a missing manifest row without truncating under set -e" {
  setup_store
  printf x | store_add ORPHAN_TOKEN
  rm -f "$(agsec_manifest_toml)"                 # no manifest → _rotate_of's grep fails (exit non-zero)
  run bash "$REPO_ROOT/bin/agent-secrets" list
  [ "$status" -eq 0 ]                            # pre-fix: bare r=$(...) aborts under set -e after the header
  [[ "$output" == *"ORPHAN_TOKEN"* ]]            # every name is listed, not truncated away
  [[ "$output" == *"$AGENT_SECRETS_CANARY_NAME"* ]]
}

@test "run -- with no command gives run's usage (exit 2), not an internal helper message" {
  setup_store
  run bash "$REPO_ROOT/bin/agent-secrets" run --
  [ "$status" -eq 2 ]
  [[ "$output" == *"agent-secrets run"* ]]   # run's user-facing usage…
  [[ "$output" == *"-- <cmd>"* ]]            # …not the internal store_exec helper string
}

@test "static: no secret value passed to a logging/status helper (transcript-leak guard)" {
  # The real leak risk is a value var reaching stderr/stdout via a log or status line (it lands in
  # ~/.claude transcripts). The sanctioned value sinks — a 0600 temp file redirect in
  # store.sh and ui_read_secret's pipe output — are NOT logging calls, so this precise check passes
  # them while catching a genuine `agsec_warn "...$value"` style leak.
  run bash -c "grep -rnE '(agsec_log|agsec_note|agsec_warn|agsec_die|agsec_ok|agsec_attn|agsec_bad|ui_say|ui_ok|ui_warn|ui_bad|echo)[^\n]*\\\$(value|val|secret|apikey)([^A-Za-z_]|\$)' '$REPO_ROOT/lib' '$REPO_ROOT/cmd' || true"
  [ -z "$output" ]
}

@test "add fails CLOSED on a multi-line value (no silent first-line truncation)" {
  setup_store
  run bash -c "printf 'line-one\nline-two\n' | bash '$REPO_ROOT/bin/agent-secrets' add MULTI_ADD"
  [ "$status" -ne 0 ]
  [[ "$output" == *"SINGLE-LINE"* ]]
  # nothing stored under that name
  run bash "$REPO_ROOT/bin/agent-secrets" list
  [[ "$output" != *"MULTI_ADD"* ]]
}

@test "store_add_multiline is a fail-closed stub (multi-line unsupported in v0.1)" {
  setup_store
  export AGENT_SECRETS_LIB="$REPO_ROOT/lib"
  # shellcheck source=/dev/null
  . "$REPO_ROOT/lib/common.sh"; . "$REPO_ROOT/lib/keychain.sh"; . "$REPO_ROOT/lib/store.sh"
  run store_add_multiline PEM_KEY
  [ "$status" -eq 2 ]
  [[ "$output" == *"not supported"* ]]
  ! store_has PEM_KEY
}
