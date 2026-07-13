#!/usr/bin/env bats
# tests/backup.bats — `agent-secrets backup`: off-machine encrypted-store copy via gh.
# A local BARE repo (mock gh) stands in for the private GitHub repo. The load-bearing invariant:
# ciphertext + PUBLIC metadata leave; the age PRIVATE key never does.
load test_helper

_mk_remote() { AGSEC_MOCK_GH_REMOTE="$(mktemp -d "${TMPDIR:-/tmp}/agsec-remote.XXXXXX")/store.git"; export AGSEC_MOCK_GH_REMOTE; }
_rm_remote() { [ -n "${AGSEC_MOCK_GH_REMOTE:-}" ] && rm -rf "$(dirname "$AGSEC_MOCK_GH_REMOTE")"; }

@test "backup pushes ciphertext + public metadata, NEVER the private age key" {
  setup_store
  _mk_remote
  run agsec backup --repo testuser/agent-secrets-store --yes
  [ "$status" -eq 0 ]
  [[ "$output" == *"backed up"* ]]

  # Inspect exactly what landed in the remote.
  local work; work="$(mktemp -d)"; git clone -q "$AGSEC_MOCK_GH_REMOTE" "$work"
  [ -f "$work/secrets.env" ]        # the encrypted store
  [ -f "$work/age.pub" ]            # public recipient (safe)
  [ -f "$work/manifest.toml" ]      # values-free metadata
  [ ! -f "$work/age.key" ]          # PRIVATE key must NEVER be pushed
  [ ! -f "$work/recovery.key" ]
  grep -q 'ENC\[' "$work/secrets.env"   # what shipped is sops ciphertext, not plaintext

  rm -rf "$work"; _rm_remote
}

@test "backup records the target so doctor flips from 'none' to 'configured'" {
  setup_store
  run agsec doctor
  [[ "$output" == *"off-machine backup"* ]]
  [[ "$output" == *"none"* ]]

  _mk_remote
  agsec backup --repo me/store --yes >/dev/null
  [ -f "$(agsec_config_dir 2>/dev/null || echo "$AGENT_SECRETS_HOME/.config/secrets")/backup-repo" ] || \
    [ -f "$AGENT_SECRETS_HOME/.config/secrets/backup-repo" ]

  run agsec doctor
  [[ "$output" == *"configured (me/store)"* ]]
  _rm_remote
}

@test "backup is idempotent: a second run with no changes reports 'already up to date'" {
  setup_store
  _mk_remote
  agsec backup --repo me/store --yes >/dev/null
  run agsec backup --repo me/store --yes
  [ "$status" -eq 0 ]
  [[ "$output" == *"already up to date"* ]]
  _rm_remote
}

@test "backup refuses without a store" {
  # no setup_store → no secrets.env
  _mk_remote
  run agsec backup --repo me/store --yes
  [ "$status" -ne 0 ]
  [[ "$output" == *"no store to back up"* ]]
  _rm_remote
}
