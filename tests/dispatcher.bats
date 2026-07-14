#!/usr/bin/env bats
# tests/dispatcher.bats — dispatcher behavior; these lock the routing contract so it
# can't silently regress.
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

@test "the redundant 'version' subcommand is gone; -V/--version is the documented route" {
  run agsec version                            # removed → falls through to unknown-command (exit 2)
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown command"* ]] || return 1
  run agsec -V                                 # the documented flag still prints the version
  [ "$status" -eq 0 ]
  [[ "$output" == "agent-secrets "* ]] || return 1
}

@test "a global flag AFTER the verb is consumed by the dispatcher, not handed to the cmd script" {
  run agsec doctor --plain                     # was: exit 2, "doctor: unknown flag: --plain"
  [ "$status" -ne 2 ]                          # 0/1 = doctor ran and reported; 2 = the usage-error arm
  [[ "$output" != *"unknown flag"* ]] || return 1
  run agsec list --no-color                    # was: exit 2, list's usage error
  [ "$status" -eq 0 ]
  [[ "$output" != *"unknown flag"* ]] || return 1
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
