#!/usr/bin/env bats
# tests/store.bats — store round-trip + the NAMES-ONLY invariant (the security backbone).
# All under synthetic AGENT_SECRETS_HOME with fake names. Real Keychain never touched (mock on PATH).
bats_require_minimum_version 1.5.0
load test_helper
load mode_matrix

FAKE_NAME=FAKE_API_TOKEN
FAKE_VALUE=fakevalue_ROUNDTRIP_123

@test "add via stdin then list shows the name (never the value)" {
  setup_store
  printf '%s' "$FAKE_VALUE" | agsec add "$FAKE_NAME"
  run agsec list
  [ "$status" -eq 0 ]
  [[ "$output" == *"$FAKE_NAME"* ]] || return 1
  [[ "$output" != *"$FAKE_VALUE"* ]] || return 1
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
  [[ "$output" == *"AWS_BACKUP_ACCESS_KEY_ID"* ]] || return 1
}

@test "list --format=json is valid and value-free" {
  setup_store
  printf '%s' "$FAKE_VALUE" | agsec add "$FAKE_NAME"
  run bash -c "bash '$REPO_ROOT/bin/agent-secrets' list --format=json | jq -e '.[].name' >/dev/null && echo VALID"
  [[ "$output" == *"VALID"* ]] || return 1
  run bash -c "bash '$REPO_ROOT/bin/agent-secrets' list --format=json | grep -c '$FAKE_VALUE'"
  [ "$output" -eq 0 ]
}

@test "add rejects an invalid NAME" {
  setup_store
  run bash -c "printf x | bash '$REPO_ROOT/bin/agent-secrets' add '1bad-name'"
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid name"* ]] || return 1
}

@test "list (text) survives a missing manifest row without truncating under set -e" {
  setup_store
  printf x | store_add ORPHAN_TOKEN
  rm -f "$(agsec_manifest_toml)"                 # no manifest → _rotate_of's grep fails (exit non-zero)
  run bash "$REPO_ROOT/bin/agent-secrets" list
  [ "$status" -eq 0 ]                            # pre-fix: bare r=$(...) aborts under set -e after the header
  [[ "$output" == *"ORPHAN_TOKEN"* ]] || return 1            # every name is listed, not truncated away
  [[ "$output" == *"$AGENT_SECRETS_CANARY_NAME"* ]] || return 1
}

@test "run -- with no command gives run's usage (exit 2), not an internal helper message" {
  setup_store
  run bash "$REPO_ROOT/bin/agent-secrets" run --
  [ "$status" -eq 2 ]
  [[ "$output" == *"agent-secrets run"* ]] || return 1   # run's user-facing usage…
  [[ "$output" == *"-- <cmd>"* ]] || return 1            # …not the internal store_exec helper string
}

@test "static: no secret value passed to a logging/status helper (transcript-leak guard)" {
  # The real leak risk is a value var reaching stderr/stdout via a log or status line (it lands in
  # ~/.claude transcripts). The sanctioned value sinks — a 0600 temp file redirect in
  # store.sh and ui_read_secret's pipe output — are NOT logging calls, so this precise check passes
  # them while catching a genuine `agsec_warn "...$value"` style leak.
  run bash -c "grep -rnE '(agsec_log|agsec_note|agsec_warn|agsec_die|agsec_ok|agsec_attn|agsec_bad|agsec_receipt|agsec_receipt_attn|agsec_receipt_bad|agsec_plan|agsec_fail|agsec_canceled|ui_say|ui_ok|ui_warn|ui_bad|echo)[^\n]*\\\$(value|val|secret|apikey)([^A-Za-z_]|\$)' '$REPO_ROOT/lib' '$REPO_ROOT/cmd' || true"
  [ -z "$output" ]
}

@test "add fails CLOSED on a multi-line value (no silent first-line truncation)" {
  setup_store
  run bash -c "printf 'line-one\nline-two\n' | bash '$REPO_ROOT/bin/agent-secrets' add MULTI_ADD"
  [ "$status" -ne 0 ]
  [[ "$output" == *"SINGLE-LINE"* ]] || return 1
  # nothing stored under that name
  run bash "$REPO_ROOT/bin/agent-secrets" list
  [[ "$output" != *"MULTI_ADD"* ]] || return 1
}

@test "store_add_multiline is a fail-closed stub (multi-line unsupported in v0.1)" {
  setup_store
  export AGENT_SECRETS_LIB="$REPO_ROOT/lib"
  # shellcheck source=/dev/null
  . "$REPO_ROOT/lib/common.sh"; . "$REPO_ROOT/lib/keychain.sh"; . "$REPO_ROOT/lib/store.sh"
  run store_add_multiline PEM_KEY
  [ "$status" -eq 2 ]
  [[ "$output" == *"not supported"* ]] || return 1
  ! store_has PEM_KEY
}

@test "add rejects an EMPTY value (fail-closed — the curl|bash empty-secret bug)" {
  setup_store
  # Pin the NON-agent diagnosis: the bats harness may itself run inside an agent session, which
  # would otherwise route to the F7 in-session message below.
  run bash -c "printf '' | env -u CLAUDECODE -u CLAUDE_CODE -u CURSOR_AGENT -u CURSOR_TRACE_ID -u TERM_PROGRAM bash '$REPO_ROOT/bin/agent-secrets' add EMPTY_ONE"
  [ "$status" -eq 2 ]
  [[ "$output" == *"NON-EMPTY"* ]] || return 1
  run agsec list
  [[ "$output" != *"EMPTY_ONE"* ]] || return 1     # never stored
}

@test "F7: the empty-STDIN refusal inside an AGENT session names the real remedy (a real terminal), still exit 2" {
  setup_store
  run bash -c "printf '' | env CLAUDECODE=1 bash '$REPO_ROOT/bin/agent-secrets' add EMPTY_TWO"
  [ "$status" -eq 2 ]                              # the refusal GATING is unchanged (F7 is copy-only)
  [[ "$output" == *"real terminal"* ]] || return 1                 # the remedy is in the LOUD line
  [[ "$output" == *"EXISTING variable"* ]] || return 1             # the safe piping path is named
  run agsec list
  [[ "$output" != *"EMPTY_TWO"* ]] || return 1     # never stored
}

# ---- add / list stream and usage contract ----------------------------------------------------------

# A key the store was never encrypted to: the store exists but cannot be decrypted.
_swap_age_key() {
  rm -f "$(agsec_age_key_file)"
  age-keygen -o "$(agsec_age_key_file)" 2>/dev/null
}

@test "add prints only NAME on stdout; the receipt goes to stderr" {
  setup_store
  run --separate-stderr bash -c "printf %s fake-placeholder | bash '$REPO_ROOT/bin/agent-secrets' add MY_KEY"
  [ "$status" -eq 0 ]
  [ "$output" = MY_KEY ]
  [[ "$stderr" == *"stored MY_KEY"* ]] || return 1
  [[ "$stderr$output" != *fake-placeholder* ]] || return 1
}

@test "add NAME junk exits 2 and stores nothing" {
  setup_store
  run --separate-stderr bash -c "printf %s fake-placeholder | bash '$REPO_ROOT/bin/agent-secrets' add JUNK_KEY sk-fake-junk"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  [[ "$stderr" == *"Unexpected argument for add."* ]] || return 1
  [[ "$stderr" != *sk-fake-junk* ]] || return 1          # a surplus token may be a value: never echoed
  run --separate-stderr bash -c "printf %s fake-placeholder | bash '$REPO_ROOT/bin/agent-secrets' add --bogus=sk-fake-flag JUNK_KEY"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  [[ "$stderr" == *"Unknown option '--bogus' for add."* ]] || return 1
  [[ "$stderr" != *sk-fake-flag* ]] || return 1
  run agsec list
  [[ "$output" != *JUNK_KEY* ]] || return 1
}

@test "add with a two-line or an empty value exits 2 with empty stdout" {
  setup_store
  run --separate-stderr bash -c "printf 'fake-one\nfake-two\n' | bash '$REPO_ROOT/bin/agent-secrets' add TWO_LINE"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  run --separate-stderr bash -c "printf '' | bash '$REPO_ROOT/bin/agent-secrets' add EMPTY_THREE"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
}

@test "add, list: AGSEC_PARSE_ONLY exits after parsing, before the store is read" {
  # No setup_store: a store read would exit 1.
  run env AGSEC_PARSE_ONLY=1 bash "$REPO_ROOT/bin/agent-secrets" add MY_KEY </dev/null
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run env AGSEC_PARSE_ONLY=1 bash "$REPO_ROOT/bin/agent-secrets" add MY_KEY extra </dev/null
  [ "$status" -eq 2 ]
  run env AGSEC_PARSE_ONLY=1 bash "$REPO_ROOT/bin/agent-secrets" list --json
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run env AGSEC_PARSE_ONLY=1 bash "$REPO_ROOT/bin/agent-secrets" list --bogus
  [ "$status" -eq 2 ]
}

@test "list --json is compact when piped and leaves stderr empty" {
  setup_store
  printf %s fake-placeholder | agsec add "$FAKE_NAME" >/dev/null 2>&1
  run --separate-stderr agsec list --json
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  jq -e 'type=="array" and (map(.name) | index("'"$FAKE_NAME"'") != null)' <<<"$output" >/dev/null
  [ -z "$stderr" ]
}

@test "list --format json (space form) still exits 2" {
  setup_store
  run --separate-stderr agsec list --format json
  [ "$status" -eq 2 ]
  [ -z "$output" ]
}

@test "list --format=json still works, leaves stderr empty, and matches list --json" {
  setup_store
  run --separate-stderr agsec list --json
  [ "$status" -eq 0 ]
  local want="$output"
  run --separate-stderr agsec list --format=json
  [ "$status" -eq 0 ]
  [ "$output" = "$want" ]
  [ -z "$stderr" ]                                      # the deprecation is queued, not printed, in JSON mode
  # The text alias still works and says once, on stderr, that it is deprecated.
  run --separate-stderr agsec list --format=text
  [ "$status" -eq 0 ]
  [[ "$output" == *"$AGENT_SECRETS_CANARY_NAME"* ]] || return 1
  [ "$(printf '%s\n' "$stderr" | grep -c deprecated)" -eq 1 ]
}

@test "list --format=json --bogus: exit 2, empty stdout, one JSON error line with reason usage" {
  setup_store
  run --separate-stderr agsec list --format=json --bogus
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  [ "$(printf '%s\n' "$stderr" | wc -l | tr -d ' ')" -eq 1 ]
  jq -e '.reason=="usage"' <<<"$stderr" >/dev/null
}

@test "list on an undecryptable store exits 1 with nothing on stdout (text and --json)" {
  setup_store
  _swap_age_key
  run --separate-stderr agsec list
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [[ "$stderr" == *"Couldn't decrypt the store"* ]] || return 1
  run --separate-stderr agsec list --json
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [ "$(printf '%s\n' "$stderr" | wc -l | tr -d ' ')" -eq 1 ]
  jq -e '.reason=="undecryptable"' <<<"$stderr" >/dev/null
}

@test "add in every mode: hidden prompt whenever stdin is a terminal, NAME alone on stdout" {
  setup_store
  local m cmd=(bash "$REPO_ROOT/bin/agent-secrets" add MM_ADD)
  # A terminal stdin gets the hidden prompt even under CI=1 or AGENT_SECRETS_NONINTERACTIVE=1; the pty
  # answers with EOF, so the empty value is refused.
  for m in tty noninteractive-tty ci-tty; do
    mm_run "$m" -- "${cmd[@]}"
    [ "$mm_status" -eq 2 ] || { echo "mode $m: status $mm_status"; return 1; }
    [[ "$mm_pty" == *"Value for MM_ADD"* ]] || { echo "mode $m: $mm_pty"; return 1; }
    [[ "$mm_pty" == *"NON-EMPTY"* ]] || { echo "mode $m: $mm_pty"; return 1; }
  done
  mm_run stdout-redirected -- "${cmd[@]}"
  [ "$mm_status" -eq 2 ]
  [ -z "$mm_stdout" ]
  [[ "$mm_pty" == *"Value for MM_ADD"* ]] || return 1
  MM_INPUT=fake-placeholder mm_run stdin-piped -- "${cmd[@]}"
  [ "$mm_status" -eq 0 ]
  [ "$mm_stdout" = MM_ADD ]
  [[ "$mm_stderr" == *"stored MM_ADD"* ]] || return 1
  [[ "$mm_stderr" != *"Value for"* ]] || return 1
  [[ "$mm_stderr$mm_stdout" != *fake-placeholder* ]] || return 1
  mm_run agent -- bash "$REPO_ROOT/bin/agent-secrets" add MM_AGENT
  [ "$mm_status" -eq 2 ]
  [ -z "$mm_stdout" ]
  [[ "$mm_stderr" != *"Value for"* ]] || return 1
  [[ "$mm_stderr" == *"EXISTING variable"* ]] || return 1          # the in-session empty-value refusal
  # add has no --json, so json-tty is a usage error.
  mm_run json-tty -- bash "$REPO_ROOT/bin/agent-secrets" add --json MM_JSON
  [ "$mm_status" -eq 2 ]
  [[ "$mm_pty" == *"Unknown option '--json' for add."* ]] || return 1
  [[ "$mm_pty" != *"Value for"* ]] || return 1
}

@test "list in every mode: names on stdout, nothing on stderr, pretty JSON on a terminal" {
  setup_store
  local m cmd=(bash "$REPO_ROOT/bin/agent-secrets" list)
  for m in tty noninteractive-tty ci-tty; do
    mm_run "$m" -- "${cmd[@]}"
    [ "$mm_status" -eq 0 ] || { echo "mode $m: status $mm_status"; return 1; }
    [[ "$mm_pty" == *"Secrets (names only"* ]] || { echo "mode $m: $mm_pty"; return 1; }
    [[ "$mm_pty" == *"$AGENT_SECRETS_CANARY_NAME"* ]] || { echo "mode $m: $mm_pty"; return 1; }
  done
  mm_run stdout-redirected -- "${cmd[@]}"
  [ "$mm_status" -eq 0 ]
  [[ "$mm_stdout" == *"$AGENT_SECRETS_CANARY_NAME"* ]] || return 1
  [[ "$mm_pty" != *"$AGENT_SECRETS_CANARY_NAME"* ]] || return 1
  for m in stdin-piped agent; do
    mm_run "$m" -- "${cmd[@]}"
    [ "$mm_status" -eq 0 ] || { echo "mode $m: status $mm_status"; return 1; }
    [[ "$mm_stdout" == *"$AGENT_SECRETS_CANARY_NAME"* ]] || { echo "mode $m: $mm_stdout"; return 1; }
    [ -z "$mm_stderr" ] || { echo "mode $m: $mm_stderr"; return 1; }
  done
  mm_run json-tty -- bash "$REPO_ROOT/bin/agent-secrets" list --json
  [ "$mm_status" -eq 0 ]
  # jq's pretty spacing; an older jq colors a terminal even under NO_COLOR, so strip SGR first.
  [[ "$(printf '%s' "$mm_pty" | perl -pe 's/\e\[[0-9;]*m//g')" == *"\"name\": \"$AGENT_SECRETS_CANARY_NAME\""* ]] || return 1
}
