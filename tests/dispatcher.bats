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
