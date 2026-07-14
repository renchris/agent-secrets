#!/usr/bin/env bats
# tests/pubkey.bats — the `pubkey` verb: prints the PUBLIC age recipient + fingerprint.
# A public key carries no secret, so pubkey is NOT gated: it must work inside an agent
# session (CLAUDECODE=1). All under synthetic AGENT_SECRETS_HOME (mocks on PATH).
load test_helper

@test "pubkey prints the age1… recipient string and a sha256: fingerprint" {
  setup_store
  run agsec pubkey
  [ "$status" -eq 0 ]
  [[ "$output" == *"age1"* ]] || return 1
  [[ "$output" == *"sha256:"* ]] || return 1
}

@test "pubkey recipient string matches the age.pub on disk" {
  setup_store
  want="$(tr -d '[:space:]' < "$(agsec_age_pub_file)")"
  run agsec pubkey
  [ "$status" -eq 0 ]
  [[ "$output" == *"$want"* ]] || return 1
}

@test "pubkey works inside a simulated agent session (CLAUDECODE=1) — not gated" {
  setup_store
  CLAUDECODE=1 run agsec pubkey
  [ "$status" -eq 0 ]
  [[ "$output" == *"age1"* ]] || return 1
  [[ "$output" == *"sha256:"* ]] || return 1
}

@test "pubkey --copy invokes pbcopy and notes the clipboard (mock exits 0)" {
  setup_store
  run agsec pubkey --copy
  [ "$status" -eq 0 ]
  [[ "$output" == *"age1"* ]] || return 1
  [[ "$output" == *"clipboard"* ]] || return 1
}

@test "pubkey before setup fails with a setup hint" {
  # No setup_store: no public key on disk yet.
  run agsec pubkey
  [ "$status" -ne 0 ]
  [[ "$output" == *"setup"* ]] || return 1
}

@test "an unknown pubkey flag is a usage error (exit 2, per the documented convention)" {
  setup_store
  run agsec pubkey --bogus
  [ "$status" -eq 2 ]
}
