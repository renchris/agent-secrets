#!/usr/bin/env bats
# tests/help.bats — CLI self-documentation for agents: every verb self-documents, help is
# side-effect-free (esp. uninstall), and `help --json` is a valid machine-readable manifest.
load test_helper

@test "top-level help lists every command" {
  run agsec help
  [ "$status" -eq 0 ]
  for v in setup add list run doctor uninstall; do [[ "$output" == *"$v"* ]]; done
}

@test "every verb --help exits 0 and prints its synopsis" {
  for v in setup add list run doctor uninstall; do
    run agsec "$v" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"agent-secrets $v"* ]]
    [[ "$output" == *"Usage:"* ]]
  done
}

@test "-h is an alias for --help" {
  run agsec doctor -h
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage:"* ]]
}

@test "help <verb> matches <verb> --help" {
  run agsec help run
  [ "$status" -eq 0 ]
  [[ "$output" == *"agent-secrets run"* ]]
  [[ "$output" == *"separator is REQUIRED"* ]]
}

@test "uninstall --help is side-effect-free: a store survives and it does not hang" {
  setup_store
  [ -f "$AGENT_SECRETS_HOME/.config/secrets/secrets.env" ]
  run bash -c "bash '$REPO_ROOT/bin/agent-secrets' uninstall --help </dev/null"
  [ "$status" -eq 0 ]
  [ -f "$AGENT_SECRETS_HOME/.config/secrets/secrets.env" ]   # store untouched
  [[ "$output" == *"Usage:"* ]]
}

@test "run -- <cmd> --help runs the child, does NOT show run's help" {
  setup_store
  # --help here belongs to the child command (echo), not to run
  run agsec run -- echo --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--help"* ]]
  [[ "$output" != *"separator is REQUIRED"* ]]   # did not fall into run's help
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
  [[ "$output" != *"invalid name"* ]]
  [[ "$output" == *"agent-secrets add"* ]]
}

@test "direct cmd invocation honors --help (defense in depth)" {
  run env AGENT_SECRETS_LIB="$REPO_ROOT/lib" bash "$REPO_ROOT/cmd/uninstall.sh" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"agent-secrets uninstall"* ]]
}

@test "setup help documents the --keychain re-run path (human + json)" {
  run agsec help setup
  [ "$status" -eq 0 ]
  [[ "$output" == *"--keychain"* ]]
  run bash -c "bash '$REPO_ROOT/bin/agent-secrets' help --json | jq -e '.commands[] | select(.name==\"setup\") | .flags | map(.flag) | index(\"--keychain\") != null'"
  [ "$status" -eq 0 ]
}

@test "top-level help renders flag NAMES, env NAMES, exit CODES, and the seealso URL (renderer key-drop regression)" {
  run agsec help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--plain"* ]]                 # flag name, not just its description
  [[ "$output" == *"--no-color"* ]]
  [[ "$output" == *"AGENT_SECRETS_HOME"* ]]       # env name
  [[ "$output" == *"0=success"* ]]                # exit code number
  [[ "$output" == *"https://github.com/renchris/agent-secrets"* ]]   # seealso URL
}
