#!/usr/bin/env bats
# tests/dispatcher.bats — dispatcher behavior; these lock the routing contract so it
# can't silently regress.
load test_helper

@test "version prints a semver line" {
  run agsec --version
  [ "$status" -eq 0 ]
  [[ "$output" == "agent-secrets "*.*.* ]]
}

@test "help lists the core verbs" {
  run agsec help
  [ "$status" -eq 0 ]
  [[ "$output" == *"setup"* ]]
  [[ "$output" == *"doctor"* ]]
  [[ "$output" == *"uninstall"* ]]
}

@test "no args shows help" {
  run agsec
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage:"* ]]
}

@test "unknown verb exits 2" {
  run agsec frobnicate
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown command"* ]]
}

@test "reserved verb rotate is refused with a v0.2 note (no bypass)" {
  run agsec rotate
  [ "$status" -eq 2 ]
  [[ "$output" == *"v0.2"* ]]
}

@test "reserved verb demo is refused with a v0.2 note" {
  run agsec demo
  [ "$status" -eq 2 ]
  [[ "$output" == *"v0.2"* ]]
}

@test "--plain is accepted as a leading global flag" {
  run agsec --plain --version
  [ "$status" -eq 0 ]
  [[ "$output" == "agent-secrets "* ]]
}

@test "smoke is a hidden dispatcher verb — the launchd weekly job routes to smoke.sh (never unknown-command)" {
  setup_store
  run agsec smoke
  [ "$status" -ne 2 ]                          # NOT the unknown-command arm (the launchd job would exit 2 forever)
  [[ "$output" != *"unknown command"* ]]
  [[ "$output" == *"keychain read"* ]]         # it actually ran the maintenance checks
}

@test "ls is a documented alias for list (help --json advertises it; help ls renders list)" {
  setup_store
  printf 'x' | store_add DOC_ALIAS_CHECK
  run agsec ls                                 # the alias routes to the list verb
  [ "$status" -eq 0 ]
  [[ "$output" == *"DOC_ALIAS_CHECK"* ]]
  run agsec help ls                            # help for the alias renders list's help (no error)
  [ "$status" -eq 0 ]
  [[ "$output" == *"agent-secrets list"* ]]
}

@test "the redundant 'version' subcommand is gone; -V/--version is the documented route" {
  run agsec version                            # removed → falls through to unknown-command (exit 2)
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown command"* ]]
  run agsec -V                                 # the documented flag still prints the version
  [ "$status" -eq 0 ]
  [[ "$output" == "agent-secrets "* ]]
}
