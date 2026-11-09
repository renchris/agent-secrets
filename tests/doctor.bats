#!/usr/bin/env bats
# tests/doctor.bats — health-check robustness + gates. Names-only, never crashes on missing setup.
bats_require_minimum_version 1.5.0
load test_helper
load mode_matrix

@test "doctor on a bare HOME: all checks names-only, exit 1, no crash, no value" {
  run agsec doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"[custody]"* ]] || return 1
  [[ "$output" == *"[store]"* ]] || return 1
  [[ "$output" == *"[injection]"* ]] || return 1
}

@test "doctor with a store present: store category goes green" {
  setup_store
  run agsec doctor
  [[ "$output" == *"store"* ]] || return 1
  [[ "$output" == *"present"* ]] || return 1
}

@test "doctor --format=json is valid JSON with no value" {
  setup_store
  run bash -c "bash '$REPO_ROOT/bin/agent-secrets' doctor --format=json | jq -e . >/dev/null && echo VALID"
  [[ "$output" == *"VALID"* ]] || return 1
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
  [[ "$output" == *"Unknown option"* ]] || return 1
}

@test "doctor --json stays valid JSON when the backup marker holds a newline and a tab" {
  setup_store
  printf 'repo\tone\nsecond line\n' > "$(agsec_config_dir)/backup-repo"
  run bash -c "bash '$REPO_ROOT/bin/agent-secrets' doctor --json 2>/dev/null"
  printf '%s\n' "$output" | jq -e '.checks[] | select(.check=="off-machine backup") | .detail == "configured (repoone)"'
}

@test "doctor --json equals doctor --format=json" {
  setup_store
  run --separate-stderr bash "$REPO_ROOT/bin/agent-secrets" doctor --json
  [ -z "$stderr" ]
  printf '%s\n' "$output" | jq -e 'has("warnings") | not'
  new="$(printf '%s\n' "$output" | jq -S .)"
  run --separate-stderr bash "$REPO_ROOT/bin/agent-secrets" doctor --format=json
  [ -z "$stderr" ]                               # JSON mode: the deprecation rides in the document
  printf '%s\n' "$output" | jq -e '.warnings | length == 1 and .[0].reason == "deprecated"'
  old="$(printf '%s\n' "$output" | jq -S 'del(.warnings)')"
  [ "$new" = "$old" ]
}

@test "doctor --format=text warns once on stderr and keeps stdout text" {
  run --separate-stderr bash "$REPO_ROOT/bin/agent-secrets" doctor --format=text
  [[ "$output" == *"[custody]"* ]] || return 1
  [ "$(printf '%s\n' "$stderr" | grep -c 'deprecated')" -eq 1 ]
}

@test "doctor --json --bogus: exit 2, empty stdout, one JSON error line" {
  run --separate-stderr bash "$REPO_ROOT/bin/agent-secrets" doctor --json --bogus
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  [ "$(printf '%s\n' "$stderr" | wc -l | tr -d ' ')" -eq 1 ]
  printf '%s\n' "$stderr" | jq -e '.reason == "usage" and (.message | test("Unknown option"))'
}

@test "doctor shows a ✗ store row when the store can't be decrypted" {
  setup_store
  # A different key in the custody file: the store is present but no longer decrypts.
  age-keygen -o "$(agsec_age_key_file).new" 2>/dev/null
  mv -f "$(agsec_age_key_file).new" "$(agsec_age_key_file)"
  run agsec doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"✗ [store] store readable — decrypt failed — check key custody"* ]] || return 1
  [[ "$output" == *"→ agent-secrets doctor --gates"* ]] || return 1
  [[ "$output" != *"no ANTHROPIC_API_KEY stored (optional)"* ]] || return 1
  [[ "$output" != *"nothing to wire until ANTHROPIC_API_KEY is stored"* ]] || return 1
}

@test "doctor's not-installed agent-rules row names setup --discovery" {
  run bash -c "bash '$REPO_ROOT/bin/agent-secrets' doctor --json 2>/dev/null"
  printf '%s\n' "$output" | jq -e '[.checks[] | select(.category=="discovery" and (.detail | startswith("not installed (opt-in")))]
    | length > 0 and all(.detail | endswith("add them with: agent-secrets setup --discovery"))'
}

@test "doctor --json, sent TERM mid-run, writes one canceled error line and exits 143" {
  shim="$AGENT_SECRETS_HOME/holdbin"; mkdir -p "$shim"
  # A security shim that announces itself, then holds until released (bounded at 120 s).
  printf '%s\n' '#!/bin/sh' ': > "$AGSEC_HOLD_DIR/held"' \
    'i=0; while [ ! -f "$AGSEC_HOLD_DIR/release" ] && [ "$i" -lt 1200 ]; do sleep 0.1; i=$((i+1)); done' \
    'exit 44' > "$shim/security"
  chmod +x "$shim/security"
  export AGSEC_HOLD_DIR="$AGENT_SECRETS_HOME"
  PATH="$shim:$PATH" bash "$REPO_ROOT/bin/agent-secrets" doctor --json \
    >"$AGENT_SECRETS_HOME/out" 2>"$AGENT_SECRETS_HOME/err" &
  pid=$!
  i=0; while [ ! -f "$AGENT_SECRETS_HOME/held" ] && [ "$i" -lt 1200 ]; do sleep 0.1; i=$((i+1)); done
  [ -f "$AGENT_SECRETS_HOME/held" ]
  kill -TERM "$pid"
  : > "$AGENT_SECRETS_HOME/release"
  rc=0; wait "$pid" || rc=$?
  [ "$rc" -eq 143 ]
  [ ! -s "$AGENT_SECRETS_HOME/out" ]
  [ "$(wc -l < "$AGENT_SECRETS_HOME/err" | tr -d ' ')" -eq 1 ]
  jq -e '.reason == "canceled"' "$AGENT_SECRETS_HOME/err"
}

@test "doctor in each of the 7 modes: no prompt, rows on stdout, exit 1 on a bare HOME" {
  d=(bash "$REPO_ROOT/bin/agent-secrets" doctor)
  for mode in tty noninteractive-tty ci-tty; do
    mm_run "$mode" -- "${d[@]}"
    [ "$mm_status" -eq 1 ] || { echo "$mode: status $mm_status"; return 1; }
    [[ "$mm_pty" == *"[custody]"* ]] || { echo "$mode: no rows"; return 1; }
  done
  mm_run stdout-redirected -- "${d[@]}"
  [ "$mm_status" -eq 1 ]
  [[ "$mm_stdout" == *"[custody]"* ]] || return 1
  [[ "$mm_pty" != *"[custody]"* ]] || return 1    # the rows are stdout, not the terminal's stderr
  for mode in stdin-piped agent; do
    mm_run "$mode" -- "${d[@]}"
    [ "$mm_status" -eq 1 ] || { echo "$mode: status $mm_status"; return 1; }
    [[ "$mm_stdout" == *"[custody]"* ]] || { echo "$mode: no rows"; return 1; }
    [ -z "$mm_stderr" ] || { echo "$mode: stderr: $mm_stderr"; return 1; }
  done
  mm_run json-tty -- "${d[@]}" --json
  [ "$mm_status" -eq 1 ]
  [[ "$mm_pty" == *'"checks": ['* ]] || return 1  # pretty-printed on a terminal (jq present)
}

@test "doctor flags the unarmed canary as inert, then green once armed" {
  setup_store                                   # seeds the INERT placeholder canary
  run agsec doctor
  [[ "$output" == *"INERT"* ]] || return 1                  # honest: no false 'active honeytoken' assurance
  printf 'real-tripwire-token-xyz' | store_add "$AGENT_SECRETS_CANARY_NAME"   # arm it
  run agsec doctor
  [[ "$output" == *"armed"* ]] || return 1
  [[ "$output" != *"INERT"* ]] || return 1
}

@test "doctor --gates runs and reports the c/d/e gates" {
  setup_store
  run agsec doctor --gates
  [ "$status" -eq 0 ] || [ "$status" -eq 1 ]   # gate outcomes are informational, not a hard fail
  [[ "$output" == *"gate"* ]] || [[ "$output" == *"Keychain"* ]] || [[ "$output" == *"exec-env"* ]] || return 1
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
  [[ "$output" == *"settings.json apiKeyHelper"* ]] || return 1
  [[ "$output" == *"not wired"* ]] || return 1
  # wired → reports "wired"
  jq -n --arg h "$bd/apiKeyHelper" '{apiKeyHelper:$h}' > "$AGENT_SECRETS_HOME/.claude/settings.json"
  run agsec doctor
  [[ "$output" == *"settings.json apiKeyHelper — wired"* ]] || return 1
}
