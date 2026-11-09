#!/usr/bin/env bats
# tests/dispatcher.bats — dispatcher behavior; these lock the routing contract so it
# can't silently regress.
bats_require_minimum_version 1.5.0
load test_helper

@test "version prints a semver line" {
  run agsec --version
  [ "$status" -eq 0 ]
  [[ "$output" == "agent-secrets "*.*.* ]] || return 1
}

@test "help lists the core verbs" {
  run agsec help
  [ "$status" -eq 0 ]
  [[ "$output" == *"setup"* ]] || return 1
  [[ "$output" == *"doctor"* ]] || return 1
  [[ "$output" == *"uninstall"* ]] || return 1
}

@test "no args shows help" {
  run agsec
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage:"* ]] || return 1
}

@test "unknown verb exits 2" {
  run agsec frobnicate
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown command"* ]] || return 1
}

@test "reserved verb rotate is refused with a v0.2 note (no bypass)" {
  run agsec rotate
  [ "$status" -eq 2 ]
  [[ "$output" == *"v0.2"* ]] || return 1
}

@test "reserved verb demo is refused with a v0.2 note" {
  run agsec demo
  [ "$status" -eq 2 ]
  [[ "$output" == *"v0.2"* ]] || return 1
}

@test "--plain is accepted as a leading global flag" {
  run agsec --plain --version
  [ "$status" -eq 0 ]
  [[ "$output" == "agent-secrets "* ]] || return 1
}

@test "smoke is a hidden dispatcher verb — the launchd weekly job routes to smoke.sh (never unknown-command)" {
  setup_store
  run agsec smoke
  [ "$status" -ne 2 ]                          # NOT the unknown-command arm (the launchd job would exit 2 forever)
  [[ "$output" != *"unknown command"* ]] || return 1
  [[ "$output" == *"keychain read"* ]] || return 1         # it actually ran the maintenance checks
}

@test "ls is a documented alias for list (help --json advertises it; help ls renders list)" {
  setup_store
  printf 'x' | store_add DOC_ALIAS_CHECK
  run agsec ls                                 # the alias routes to the list verb
  [ "$status" -eq 0 ]
  [[ "$output" == *"DOC_ALIAS_CHECK"* ]] || return 1
  run agsec help ls                            # help for the alias renders list's help (no error)
  [ "$status" -eq 0 ]
  [[ "$output" == *"agent-secrets list"* ]] || return 1
}

@test "the redundant 'version' subcommand is gone; -V still works as a deprecated alias of --version" {
  run agsec version                            # removed → falls through to unknown-command (exit 2)
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown command"* ]] || return 1
  run agsec -V                                 # hidden alias: version line first, then the deprecation
  [ "$status" -eq 0 ]
  [[ "$output" == "agent-secrets "* ]] || return 1
  run --separate-stderr bash "$REPO_ROOT/bin/agent-secrets" -V
  [ "$output" = "agent-secrets $(cat "$REPO_ROOT/VERSION")" ]
  [[ "$stderr" == *"-V is deprecated; use --version."* ]] || return 1
}

@test "a global flag AFTER the verb is consumed by the dispatcher, not handed to the cmd script" {
  run agsec doctor --plain                     # was: exit 2, "doctor: unknown flag: --plain"
  [ "$status" -ne 2 ]                          # 0/1 = doctor ran and reported; 2 = the usage-error arm
  [[ "$output" != *"unknown flag"* ]] || return 1
  [[ "$output" != *"nknown option"* ]] || return 1
  run agsec list --no-color                    # was: exit 2, list's usage error
  [ "$status" -eq 0 ]
  [[ "$output" != *"unknown flag"* ]] || return 1
  [[ "$output" != *"nknown option"* ]] || return 1
}

@test "smoke --help prints usage and does no work" {
  run agsec smoke --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: agent-secrets smoke"* ]] || return 1
  [[ "$output" != *"keychain read"* ]] || return 1
}

@test "smoke bogus exits 2" {
  run agsec smoke bogus
  [ "$status" -eq 2 ]
  [[ "$output" == *"takes no arguments"* ]] || return 1
  [[ "$output" != *"keychain read"* ]] || return 1
}

@test "help --json still omits smoke" {
  run bash -c "bash '$REPO_ROOT/bin/agent-secrets' help --json | jq -e '[.commands[].name] | index(\"smoke\") == null'"
  [ "$status" -eq 0 ]
}

@test "list --version and -v print the version" {
  v="agent-secrets $(cat "$REPO_ROOT/VERSION")"
  run agsec list --version
  [ "$status" -eq 0 ]
  [ "$output" = "$v" ]
  run agsec list -v
  [ "$status" -eq 0 ]
  [ "$output" = "$v" ]
  run agsec list --help --version              # help wins
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage:"* ]] || return 1
}

@test "run -- sh -c 'echo \$1' sh --version hands --version to the child" {
  setup_store
  # shellcheck disable=SC2016  # $1 is the child shell's
  run agsec run -- sh -c 'echo "$1"' sh --version
  [ "$status" -eq 0 ]
  [ "$output" = "--version" ]
}

@test "--version --json prints {version}" {
  run --separate-stderr bash "$REPO_ROOT/bin/agent-secrets" --version --json
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  printf '%s\n' "$output" | jq -e --arg v "$(cat "$REPO_ROOT/VERSION")" '. == {version: $v}'
  run --separate-stderr bash "$REPO_ROOT/bin/agent-secrets" -V --json
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]                             # JSON mode: the deprecation is in the document
  printf '%s\n' "$output" | jq -e '.warnings[0].reason == "deprecated" and (.version | length > 0)'
}

@test "--non-interactive after the verb is accepted and not forwarded" {
  setup_store
  unset AGENT_SECRETS_NONINTERACTIVE
  run agsec run -- printenv AGENT_SECRETS_NONINTERACTIVE    # control: unset unless the flag asks
  [ "$status" -ne 0 ]
  run agsec run --non-interactive -- printenv AGENT_SECRETS_NONINTERACTIVE
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
  run agsec --non-interactive run -- printenv AGENT_SECRETS_NONINTERACTIVE
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
  run agsec doctor --non-interactive           # not forwarded: doctor would reject it with exit 2
  [ "$status" -ne 2 ]
  run agsec run -- echo --non-interactive      # past `--` it is the child's
  [ "$status" -eq 0 ]
  [ "$output" = "--non-interactive" ]
}

@test "uninstall --help --json prints one command object" {
  run bash -c "bash '$REPO_ROOT/bin/agent-secrets' uninstall --help --json | jq -e '.name==\"uninstall\" and has(\"flags\")'"
  [ "$status" -eq 0 ]
  run bash -c "bash '$REPO_ROOT/bin/agent-secrets' uninstall --help --json | wc -l"
  [ "$(printf '%s' "$output" | tr -d ' ')" = 1 ]
}

@test "smoke notifications pass text as osascript argv" {
  setup_store
  log="$AGENT_SECRETS_HOME/osascript.log"
  # The name regex captures no `"`, so the hostile characters it can carry are quotes, \ and &.
  printf '%s\n' '[[secret]]' "name = \"it's a \\ test & more\"" 'rotate_by = "2020-01-01"' \
    '[[secret]]' 'name = "SKIPPED"NAME"' 'rotate_by = "2020-01-01"' > "$(agsec_manifest_toml)"
  export AGSEC_OSASCRIPT_LOG="$log"
  run agsec smoke
  grep -Fxq 'display notification (item 2 of argv) with title (item 1 of argv)' "$log"
  grep -Fxq 'agent-secrets rotation' "$log"    # the title is its own item
  grep -Eq "^it's a \\\\ test & more overdue by [0-9]+d\$" "$log"   # the whole text is one item
  if grep -q 'display notification "' "$log"; then return 1; fi   # no text spliced into the script
  if grep -q 'SKIPPED' "$log"; then return 1; fi   # an unmatched name line is skipped, not used raw
}

@test "help --all --json and help --json --all print the same document as help --json" {
  want="$(bash "$REPO_ROOT/bin/agent-secrets" help --json | jq -S .)"
  a="$(bash "$REPO_ROOT/bin/agent-secrets" help --all --json | jq -S .)"
  b="$(bash "$REPO_ROOT/bin/agent-secrets" help --json --all | jq -S .)"
  [ -n "$want" ]
  [ "$a" = "$want" ]
  [ "$b" = "$want" ]
  run agsec help --all                         # the CLI is flat: --all alone is the top level
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage:"* ]] || return 1
}

@test "help search json lists list and doctor" {
  run agsec help search json
  [ "$status" -eq 0 ]
  [[ "$output" == *"  agent-secrets list  "* ]] || return 1
  [[ "$output" == *"  agent-secrets doctor  "* ]] || return 1
  [[ "$output" != *"agent-secrets smoke"* ]] || return 1
}

@test "help search zzz exits 0 with the no-match line" {
  run agsec help search zzz
  [ "$status" -eq 0 ]
  [ "$output" = 'No commands match "zzz"' ]
}

@test "help search --json key is valid JSON with .commands[].path" {
  run --separate-stderr bash "$REPO_ROOT/bin/agent-secrets" help search --json key
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -e '(.commands | length > 0) and all(.commands[]; (.path | startswith("agent-secrets ")) and (.summary | type == "string"))'
  run --separate-stderr bash "$REPO_ROOT/bin/agent-secrets" help search --json zzz
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -e '. == {commands: []}'
}

@test "help search with no query exits 2" {
  run agsec help search
  [ "$status" -eq 2 ]
  run --separate-stderr bash "$REPO_ROOT/bin/agent-secrets" help search --json
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  printf '%s\n' "$stderr" | jq -e '.reason == "usage"'
}

@test "a post-verb --plain/--no-color is EXPORTED, not merely dropped from argv" {
  setup_store
  # The harness pre-exports both (test_helper.bash:14) so suite output is deterministic. Clear them,
  # or the child inherits them and this test passes even with the dispatcher's export reverted.
  # (Asserting on colorless output can't prove the export either: bats captures stdout, so the
  # `[ ! -t 1 ]` arm of agsec_use_plain forces plain regardless of the flag.)
  unset AGENT_SECRETS_PLAIN NO_COLOR
  run agsec run -- printenv AGENT_SECRETS_PLAIN   # control: unset unless the flag asks for it
  [ "$status" -ne 0 ]
  run agsec run --plain -- printenv AGENT_SECRETS_PLAIN
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
  run agsec run --no-color -- printenv NO_COLOR
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "the flag scan stops at '--' — run's child keeps its own --plain" {
  setup_store
  # Same seam _wants_help honors: past `--` the args belong to the CHILD, so --plain is echo's here.
  run agsec run -- echo --plain
  [ "$status" -eq 0 ]
  [[ "$output" == *"--plain"* ]] || return 1   # empty ⇒ the dispatcher ate the child's flag
}
