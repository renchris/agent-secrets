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
  [[ "$output" == *"multi-line secrets are not supported"* ]] || return 1
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
  [[ "$output" != *"$secret"* ]] || return 1                             # the refusal message carries no value
  run grep -c "$secret" "$(agsec_store_file)"; [ "$output" -eq 0 ]   # nothing stored
}

@test "two concurrent store_add calls never silently lose a name" {
  setup_store
  local a b ra=0 rb=0 t="$BATS_TEST_TMPDIR"
  ( printf 'fake-a' | store_add LOCK_A ) 3>&- 2>"$t/a.err" & a=$!
  ( printf 'fake-b' | store_add LOCK_B ) 3>&- 2>"$t/b.err" & b=$!
  wait "$a" || ra=$?; wait "$b" || rb=$?
  # Each writer either stores its name or, when the 10 s lock wait runs out on a loaded machine, fails
  # loudly with the lock error. A writer that reports success must find its name in the store.
  [ "$ra" -eq 0 ] || [ "$rb" -eq 0 ]
  run store_names
  [ "$status" -eq 0 ]
  if [ "$ra" -eq 0 ]; then grep -qx LOCK_A <<<"$output" || return 1
  else grep -qF "Couldn't lock the store" "$t/a.err" || return 1; fi
  if [ "$rb" -eq 0 ]; then grep -qx LOCK_B <<<"$output" || return 1
  else grep -qF "Couldn't lock the store" "$t/b.err" || return 1; fi
  [ ! -e "$(agsec_config_dir)/.store.lock" ]                 # released
}

@test "store_names returns 2 with empty output when the store can't be decrypted" {
  setup_store
  rm -f "$(agsec_age_key_file)"
  age-keygen -o "$(agsec_age_key_file)" 2>/dev/null         # a key the store was never encrypted to
  run store_names
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  run store_has "$AGENT_SECRETS_CANARY_NAME"
  [ "$status" -eq 2 ]
  local before; before="$(cat "$(agsec_store_file)")"
  run store_canary_insert                                    # must not re-seed over the real store
  [ "$status" -eq 2 ]
  [ "$(cat "$(agsec_store_file)")" = "$before" ]
}

@test "store_names returns 1 when there is no store yet; store_has matches a name exactly" {
  export AGENT_SECRETS_LIB="$REPO_ROOT/lib"
  # shellcheck source=/dev/null
  . "$REPO_ROOT/lib/common.sh"; . "$REPO_ROOT/lib/store.sh"
  run store_names
  [ "$status" -eq 1 ]
  setup_store
  printf 'fake' | store_add MY_API_KEY
  store_has MY_API_KEY
  run store_has MY.API.KEY                                   # '.' is not a wildcard
  [ "$status" -eq 1 ]
  run store_has MY_API
  [ "$status" -eq 1 ]
}

@test "store_add drops one trailing CR from a CRLF line, keeps a CR at EOF" {
  setup_store
  printf 'v1\r\n' | store_add CR_LINE
  printf 'v1\r' | store_add CR_EOF
  run bash "$REPO_ROOT/bin/agent-secrets" run --no-egress -- sh -c 'printf %s "$CR_LINE" | wc -c'
  [ "$status" -eq 0 ]
  [ "$((output))" -eq 2 ]
  run bash "$REPO_ROOT/bin/agent-secrets" run --no-egress -- sh -c 'printf %s "$CR_EOF" | wc -c'
  [ "$status" -eq 0 ]
  [ "$((output))" -eq 3 ]
}

@test "store and key files are written with the right modes and leave no temp behind" {
  setup_store
  printf 'fake' | store_add MODE_K
  [ "$(stat -f %Lp "$(agsec_store_file)")" = 600 ]
  [ "$(stat -f %Lp "$(agsec_sops_config)")" = 600 ]
  [ "$(stat -f %Lp "$(age_key_cmd_path)")" = 700 ]
  printf 'AGE-SECRET-KEY-FAKE' | kc_add
  [ "$(stat -f %Lp "$(agsec_age_key_file)")" = 600 ]
  [ "$(cat "$(agsec_age_key_file)")" = AGE-SECRET-KEY-FAKE ]
  run find "$(agsec_config_dir)" -name '.secrets.env.*' -o -name '.agsec.*' -o -name '*.new' -o -name '.age.key.*'
  [ -z "$output" ]
}
