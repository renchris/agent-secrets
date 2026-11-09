#!/usr/bin/env bats
# tests/help.bats — CLI self-documentation for agents: every verb self-documents, help is
# side-effect-free (esp. uninstall), and `help --json` is a valid machine-readable manifest.
load test_helper
load mode_matrix

@test "top-level help lists every command" {
  run agsec help
  [ "$status" -eq 0 ]
  for v in setup add list run doctor uninstall; do [[ "$output" == *"$v"* ]]; done
}

@test "every verb --help exits 0 and prints its synopsis" {
  for v in setup add list run doctor uninstall; do
    run agsec "$v" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"agent-secrets $v"* ]] || return 1
    [[ "$output" == *"Usage:"* ]] || return 1
  done
}

@test "-h is an alias for --help" {
  run agsec doctor -h
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage:"* ]] || return 1
}

@test "help <verb> matches <verb> --help" {
  run agsec help run
  [ "$status" -eq 0 ]
  [[ "$output" == *"agent-secrets run"* ]] || return 1
  [[ "$output" == *"separator is REQUIRED"* ]] || return 1
}

@test "uninstall --help is side-effect-free: a store survives and it does not hang" {
  setup_store
  [ -f "$AGENT_SECRETS_HOME/.config/secrets/secrets.env" ]
  run bash -c "bash '$REPO_ROOT/bin/agent-secrets' uninstall --help </dev/null"
  [ "$status" -eq 0 ]
  [ -f "$AGENT_SECRETS_HOME/.config/secrets/secrets.env" ]   # store untouched
  [[ "$output" == *"Usage:"* ]] || return 1
}

@test "run -- <cmd> --help runs the child, does NOT show run's help" {
  setup_store
  # --help here belongs to the child command (echo), not to run
  run agsec run -- echo --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--help"* ]] || return 1
  [[ "$output" != *"separator is REQUIRED"* ]] || return 1   # did not fall into run's help
}

@test "help --json is a valid manifest with all 11 commands" {
  # top-level "agent-secrets" + 10 verbs (setup add list run doctor uninstall share receive pubkey backup)
  run bash -c "bash '$REPO_ROOT/bin/agent-secrets' help --json | jq -e '.tool==\"agent-secrets\" and (.commands|length==11)'"
  [ "$status" -eq 0 ]
}

@test "help --json exposes structured facts an agent needs" {
  run bash -c "bash '$REPO_ROOT/bin/agent-secrets' help --json | jq -e '
    (.commands[] | select(.name==\"add\") | .examples[0].command | test(\"STDIN|printf|\\\\|\")) and
    (.commands[] | select(.name==\"doctor\") | .exit_codes | map(.code) | contains([0,1])) and
    (.commands[] | select(.name==\"backup\") | .names_only | test(\"private key\")) and
    (.commands[] | select(.name==\"run\") | .synopsis | test(\"--\"))'"
  [ "$status" -eq 0 ]
}

@test "bare --json also emits the manifest" {
  run bash -c "bash '$REPO_ROOT/bin/agent-secrets' --json | jq -e '.tool'"
  [ "$status" -eq 0 ]
}

@test "add --help does not treat --help as a NAME (regression)" {
  run agsec add --help
  [ "$status" -eq 0 ]
  [[ "$output" != *"invalid name"* ]] || return 1
  [[ "$output" == *"agent-secrets add"* ]] || return 1
}

@test "direct cmd invocation honors --help (defense in depth)" {
  run env AGENT_SECRETS_LIB="$REPO_ROOT/lib" bash "$REPO_ROOT/cmd/uninstall.sh" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"agent-secrets uninstall"* ]] || return 1
}

@test "setup help documents the --keychain re-run path (human + json)" {
  run agsec help setup
  [ "$status" -eq 0 ]
  [[ "$output" == *"--keychain"* ]] || return 1
  run bash -c "bash '$REPO_ROOT/bin/agent-secrets' help --json | jq -e '.commands[] | select(.name==\"setup\") | .flags | map(.flag) | index(\"--keychain\") != null'"
  [ "$status" -eq 0 ]
}

@test "top-level help renders flag NAMES, env NAMES, exit CODES, and the seealso URL (renderer key-drop regression)" {
  run agsec help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--plain"* ]] || return 1                 # flag name, not just its description
  [[ "$output" == *"--no-color"* ]] || return 1
  [[ "$output" == *"AGENT_SECRETS_HOME"* ]] || return 1       # env name
  printf '%s\n' "$output" | grep -qE '^  0 +success$' || return 1   # exit code number
  [[ "$output" == *"https://github.com/renchris/agent-secrets"* ]] || return 1   # seealso URL
}

# Split an example into the dispatcher's argv: drop anything before `agent-secrets` (VAR=value words, a
# producer pipe) and after a following `|`, and give every <PLACEHOLDER> a synthetic word.
_example_argv() {
  printf '%s\n' "$1" | sed -E 's/^.*agent-secrets//; s/\|.*$//; s/<[A-Z_]+>/WORD/g'
}
_parses() {  # COMMAND — run it through the AGSEC_PARSE_ONLY seam
  local words; words="$(_example_argv "$1")"
  set -f; set -- $words; set +f   # word-split on purpose; no globbing
  run env AGSEC_PARSE_ONLY=1 bash "$REPO_ROOT/bin/agent-secrets" "$@" </dev/null
}

@test "every help example parses, as do setup's replay line and the top-level synopsis" {
  . "$REPO_ROOT/lib/help.sh"
  local n=0 cmd
  while IFS= read -r cmd; do
    [ -n "$cmd" ] || continue
    n=$((n + 1))
    _parses "$cmd"
    [ "$status" -eq 0 ] || { echo "example does not parse (exit $status): $cmd"; echo "$output"; return 1; }
  done <<EOF
$(agsec_help_spec | awk -F'\t' '$2=="example"{print $3}')
EOF
  [ "$n" -gt 0 ]
  cmd="$(AGENT_SECRETS_LIB="$REPO_ROOT/lib" bash -c '. "$REPO_ROOT/cmd/setup.sh"; _replay_cmd ANTHROPIC_API_KEY')"
  [[ "$cmd" == "agent-secrets setup "* ]] || return 1
  _parses "$cmd"
  [ "$status" -eq 0 ] || { echo "replay does not parse: $cmd"; echo "$output"; return 1; }
  cmd="$(agsec_help_spec | awk -F'\t' '$1=="" && $2=="synopsis"{print $3}' | sed -E 's/[][]//g; s/<command>/list/; s/ args$//')"
  _parses "$cmd"
  [ "$status" -eq 0 ] || { echo "synopsis does not parse: $cmd"; echo "$output"; return 1; }
}

@test "the parse-only seam sits after validation: a bad option still exits 2" {
  _parses "agent-secrets list --bogus"
  [ "$status" -eq 2 ]
  [[ "$output" == *"Unknown option '--bogus'"* ]] || return 1
}

@test "no rendered help line exceeds 80 columns" {
  . "$REPO_ROOT/lib/help.sh"
  local v
  for v in "" $AGSEC_VERBS; do
    run bash -c "set -o pipefail; bash '$REPO_ROOT/bin/agent-secrets' help $v | LC_ALL=en_US.UTF-8 awk 'length>80'"
    [ "$status" -eq 0 ] || { echo "help $v exited $status"; return 1; }
    [ -z "$output" ] || { echo "help $v: $output"; return 1; }
  done
}

@test "uninstall --help lists exit 0 for nothing to roll back and exit 1 for a partial rollback" {
  run agsec uninstall --help
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qE '^    0 .*nothing to roll back' || return 1
  printf '%s\n' "$output" | grep -qE '^    1 +partial rollback' || return 1
}

@test "help --json flags carry type, value_hint and default (and keep flag + description)" {
  run bash -c "bash '$REPO_ROOT/bin/agent-secrets' help --json | jq -e '
    ([.commands[].flags[] | has(\"flag\") and has(\"description\") and has(\"type\") and has(\"value_hint\")
       and has(\"default\") and has(\"choices\")] | all) and
    (.commands[] | select(.name==\"setup\") | .flags[] | select(.flag|startswith(\"--import-env\"))
       | .type==\"string\" and .value_hint==\"<NAME>[,<NAME>…]\") and
    (.commands[] | select(.name==\"setup\") | .flags[] | select(.flag==\"--headless\")
       | .type==\"boolean\" and .value_hint==null and .default==false)'"
  [ "$status" -eq 0 ]
}

@test "top-level help groups every command exactly once and marks help as the default" {
  . "$REPO_ROOT/lib/help.sh"
  run agsec help
  [ "$status" -eq 0 ]
  local cmds v
  cmds="$(printf '%s\n' "$output" | sed -n '/^Commands:/,/^$/p')"
  for v in $AGSEC_VERBS; do
    [ "$(printf '%s\n' "$cmds" | grep -cE "^    $v(,| |\$)")" -eq 1 ] || { echo "not listed once: $v"; return 1; }
  done
  printf '%s\n' "$cmds" | grep -qE '^    list, ls ' || return 1
  printf '%s\n' "$cmds" | grep -qE '^    help \(default\) ' || return 1
  printf '%s\n' "$cmds" | grep -qE '^    help search <TEXT> ' || return 1
  printf '%s\n' "$cmds" | grep -qE '^    help --all --json ' || return 1
  printf '%s\n' "$output" | grep -qE '^  130 +canceled' || return 1
}

@test "verb help: sections in order, -v listed and -V not, no list --format alias" {
  . "$REPO_ROOT/lib/help.sh"
  local v heads rank last h
  for v in $AGSEC_VERBS; do
    run agsec "$v" --help
    [ "$status" -eq 0 ] || return 1
    heads="$(printf '%s\n' "$output" | grep -oE '^(Usage|Arguments|Options|Global Options|Environment|Examples|Notes):')"
    [ "$(printf '%s\n' "$heads" | head -1)" = "Usage:" ] || { echo "$v: Usage is not first"; return 1; }
    last=0
    while IFS= read -r h; do
      case "$h" in
        Usage:) rank=1 ;; Arguments:) rank=2 ;; Options:) rank=3 ;; "Global Options:") rank=4 ;;
        Environment:) rank=5 ;; Examples:) rank=6 ;; Notes:) rank=7 ;;
      esac
      [ "$rank" -gt "$last" ] || { echo "$v: $h out of order"; return 1; }
      last=$rank
    done <<EOF
$heads
EOF
    printf '%s\n' "$heads" | grep -qx 'Global Options:' || { echo "$v: no Global Options"; return 1; }
    printf '%s\n' "$heads" | grep -qx 'Notes:' || { echo "$v: no Notes"; return 1; }
    printf '%s\n' "$output" | grep -qE '^  -v, --version ' || { echo "$v: no -v, --version"; return 1; }
    [[ "$output" != *"-V"* ]] || { echo "$v: lists -V"; return 1; }
  done
  run agsec list --help
  [[ "$output" != *"--format"* ]] || return 1
}

@test "help documents exit 130 wherever a confirmation can be declined" {
  local v
  for v in share receive backup; do
    run agsec "$v" --help
    [ "$status" -eq 0 ] || return 1
    printf '%s\n' "$output" | grep -qE '^    130 +canceled' || { echo "$v: no exit 130"; return 1; }
  done
}

@test "colored help is the plain render plus color: --no-color, NO_COLOR and TERM=dumb match; --json has no ESC" {
  . "$REPO_ROOT/lib/help.sh"
  local v c
  # FORCE_COLOR must actually color, or the comparisons below compare plain with plain.
  run env -u AGENT_SECRETS_PLAIN -u NO_COLOR -u CLAUDECODE -u CLAUDE_CODE -u CURSOR_AGENT -u CURSOR_TRACE_ID \
    -u TERM_PROGRAM FORCE_COLOR=1 bash "$REPO_ROOT/bin/agent-secrets" help
  [[ "$output" == *$'\033['* ]] || return 1
  for v in --help $AGSEC_VERBS; do
    [ "$v" = --help ] || v="$v --help"
    mm_styles env COLUMNS=80 bash "$REPO_ROOT/bin/agent-secrets" $v || { echo "styles differ: $v"; return 1; }
  done
  for c in 40 120; do
    mm_styles env COLUMNS=$c bash "$REPO_ROOT/bin/agent-secrets" --help || { echo "styles differ at $c"; return 1; }
  done
}
