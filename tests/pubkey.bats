#!/usr/bin/env bats
# tests/pubkey.bats — the `pubkey` verb: prints the PUBLIC age recipient + fingerprint.
# A public key carries no secret, so pubkey is NOT gated: it must work inside an agent
# session (CLAUDECODE=1). All under synthetic AGENT_SECRETS_HOME (mocks on PATH).
bats_require_minimum_version 1.5.0
load test_helper
load mode_matrix

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
  [[ "$output" == *"Unknown option '--bogus' for pubkey."* ]] || return 1
}

@test "pubkey prints exactly the recipient on stdout" {
  setup_store
  run --separate-stderr agsec pubkey
  [ "$status" -eq 0 ]
  [ "$output" = "$(tr -d '[:space:]' <"$(agsec_age_pub_file)")" ]
  [[ "$stderr" == *"fingerprint: sha256:"* ]] || return 1
  [[ "$stderr" == *"Your age recipient"* ]] || return 1
}

@test "pubkey --copy junk exits 2" {
  setup_store
  run --separate-stderr agsec pubkey --copy junk
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  [[ "$stderr" == *"Unexpected argument for pubkey."* ]] || return 1
}

@test "pubkey's '-' is accepted with one deprecation warning, even when repeated" {
  setup_store
  run --separate-stderr agsec pubkey - -
  [ "$status" -eq 0 ]
  [ "$output" = "$(tr -d '[:space:]' <"$(agsec_age_pub_file)")" ]
  [ "$(printf '%s\n' "$stderr" | grep -c "'-' is ignored")" -eq 1 ]
}

@test "pubkey: AGSEC_PARSE_ONLY exits after parsing, before the key file is read" {
  # No setup_store: reading the key would exit 1.
  run env AGSEC_PARSE_ONLY=1 bash "$REPO_ROOT/bin/agent-secrets" pubkey --copy
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run env AGSEC_PARSE_ONLY=1 bash "$REPO_ROOT/bin/agent-secrets" pubkey --bogus
  [ "$status" -eq 2 ]
}

@test "pubkey in every mode: the recipient alone on stdout, heading and fingerprint on stderr" {
  setup_store
  local m want cmd=(bash "$REPO_ROOT/bin/agent-secrets" pubkey)
  want="$(tr -d '[:space:]' <"$(agsec_age_pub_file)")"
  for m in tty noninteractive-tty ci-tty; do
    mm_run "$m" -- "${cmd[@]}"
    [ "$mm_status" -eq 0 ] || { echo "mode $m: status $mm_status"; return 1; }
    [[ "$mm_pty" == *"$want"* ]] || { echo "mode $m: $mm_pty"; return 1; }
    [[ "$mm_pty" == *"fingerprint: sha256:"* ]] || { echo "mode $m: $mm_pty"; return 1; }
  done
  mm_run stdout-redirected -- "${cmd[@]}"
  [ "$mm_status" -eq 0 ]
  [ "$mm_stdout" = "$want" ]
  [[ "$mm_pty" == *"fingerprint: sha256:"* ]] || return 1
  for m in stdin-piped agent; do
    mm_run "$m" -- "${cmd[@]}"
    [ "$mm_status" -eq 0 ] || { echo "mode $m: status $mm_status"; return 1; }
    [ "$mm_stdout" = "$want" ] || { echo "mode $m: $mm_stdout"; return 1; }
    [[ "$mm_stderr" == *"fingerprint: sha256:"* ]] || { echo "mode $m: $mm_stderr"; return 1; }
  done
  # pubkey has no --json, so json-tty is a usage error.
  mm_run json-tty -- bash "$REPO_ROOT/bin/agent-secrets" pubkey --json
  [ "$mm_status" -eq 2 ]
  [[ "$mm_pty" == *"Unknown option '--json' for pubkey."* ]] || return 1
}
