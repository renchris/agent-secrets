#!/usr/bin/env bats
# tests/foundation.bats — colleague-sharing foundation: multi-line refusal + in-place manifest
# sharing edits, all under synthetic AGENT_SECRETS_HOME with fake names. NAMES-ONLY invariant holds:
# no test ever expects a secret VALUE outside the sops store. Real Keychain never touched (mock on PATH).
load test_helper

@test "store_add_multiline REFUSES a multi-line value (v0.1 stores single-line only)" {
  setup_store
  # The base64-round-trip workaround corrupted values across run/share (see re-audit) → v0.1 refuses.
  run store_add_multiline FAKE_PEM_KEY
  [ "$status" -eq 2 ]
  [[ "$output" == *"multi-line secrets are not supported"* ]]
  ! store_has FAKE_PEM_KEY                                    # nothing stored
}

@test "store_manifest_set_sharing adds sharing fields then updates in place (no dup lines)" {
  setup_store
  printf 'x' | store_add MY_SECRET
  store_manifest_set_sharing MY_SECRET shared_with='sha256:1a2b3c4d5e6f' shared_at='2026-07-11' direction='sent'
  run grep -c '^shared_with = "sha256:1a2b3c4d5e6f"' "$(agsec_manifest_toml)"
  [ "$output" -eq 1 ]
  run grep -c '^direction = "sent"' "$(agsec_manifest_toml)"
  [ "$output" -eq 1 ]
  # re-run with a changed direction → still exactly one direction line, updated in place
  store_manifest_set_sharing MY_SECRET direction='received'
  run grep -c '^direction = ' "$(agsec_manifest_toml)"
  [ "$output" -eq 1 ]
  run grep -c '^direction = "received"' "$(agsec_manifest_toml)"
  [ "$output" -eq 1 ]
  # shared_with untouched by the second call
  run grep -c '^shared_with = "sha256:1a2b3c4d5e6f"' "$(agsec_manifest_toml)"
  [ "$output" -eq 1 ]
}

@test "store_manifest_purge_sharing strips sharing lines, keeps name/rotate_by and plain source" {
  setup_store
  printf 'x' | store_add MY_SECRET
  store_manifest_set_sharing MY_SECRET shared_with='sha256:deadbeef1234' shared_at='2026-07-11' \
    direction='received' source='received:dana'
  store_manifest_purge_sharing
  run grep -c '^shared_with = ' "$(agsec_manifest_toml)"; [ "$output" -eq 0 ]
  run grep -c '^shared_at = ' "$(agsec_manifest_toml)"; [ "$output" -eq 0 ]
  run grep -c '^direction = ' "$(agsec_manifest_toml)"; [ "$output" -eq 0 ]
  run grep -c '^source = "received:' "$(agsec_manifest_toml)"; [ "$output" -eq 0 ]
  # non-sharing lines intact
  run grep -c 'name = "MY_SECRET"' "$(agsec_manifest_toml)"; [ "$output" -eq 1 ]
  run grep -c '^rotate_by = ' "$(agsec_manifest_toml)"; [ "$output" -gt 0 ]
  # the canary row's plain source = "sops:…" survives (only received:* is purged)
  run grep -c '^source = "sops:' "$(agsec_manifest_toml)"; [ "$output" -gt 0 ]
}

@test "value-leak guard: refusing a multi-line value never echoes the secret" {
  setup_store
  secret='SUPERSECRETLINE_zzz987'
  printf -- '-----BEGIN-----\n%s\n-----END-----\n' "$secret" > "$AGENT_SECRETS_HOME/v.in"
  run store_add_multiline LEAK_CHECK < "$AGENT_SECRETS_HOME/v.in"
  [ "$status" -eq 2 ]                                         # refused (stub never reads the value)
  [[ "$output" != *"$secret"* ]]                             # the refusal message carries no value
  run grep -c "$secret" "$(agsec_store_file)"; [ "$output" -eq 0 ]   # nothing stored
}
