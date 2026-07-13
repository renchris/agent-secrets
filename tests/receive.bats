#!/usr/bin/env bats
# tests/receive.bats — the `receive` verb: tty-gated ingest, local digest, canary + collision guards,
# dual byte caps, multi-line safety, value-never-in-argv. Blobs are built INLINE (no dependency on the
# `share` verb) by encrypting a test value to the recipient's OWN age key (setup_store writes age.pub).
load test_helper

# Build a valid v1 envelope on STDOUT: encrypt VALUE to the local age.pub, wrap with the exact headers
# and the LOCALLY-correct digest (over base64-decoded ciphertext bytes) — same computation receive does.
make_blob() {
  local name="$1" value="$2" armor body dg
  armor="$(printf '%s' "$value" | age -r "$(cat "$(agsec_age_pub_file)")" -a)"
  body="$(printf '%s\n' "$armor" | sed '1d;$d')"
  dg="$(printf '%s\n' "$body" | base64 -D | agsec_digest)"
  printf -- '-----BEGIN AGENT-SECRETS SHARE v1-----\n'
  printf 'name: %s\n' "$name"
  printf 'direction: sent\n'
  printf 'digest: %s\n' "$dg"
  printf '%s\n' "$armor"
  printf -- '-----END AGENT-SECRETS SHARE v1-----\n'
}

# Like make_blob but with an arbitrary version token (for the unknown-version test).
make_blob_ver() {
  local name="$1" value="$2" ver="$3" armor
  armor="$(printf '%s' "$value" | age -r "$(cat "$(agsec_age_pub_file)")" -a)"
  printf -- '-----BEGIN AGENT-SECRETS SHARE %s-----\n' "$ver"
  printf 'name: %s\ndirection: sent\ndigest: sha256:deadbeef0000\n' "$name"
  printf '%s\n' "$armor"
  printf -- '-----END AGENT-SECRETS SHARE %s-----\n' "$ver"
}

receive_bin() { printf '%s\n' "$REPO_ROOT/bin/agent-secrets"; }

@test "round-trip: single-line value ingests from STDIN and stores names-only" {
  setup_store
  make_blob MY_TOKEN 'sk-secret-abc123' > "$BATS_TEST_TMPDIR/blob"
  printf 'y\n' > "$BATS_TEST_TMPDIR/confirm"
  run env AGSEC_CONFIRM_SRC="$BATS_TEST_TMPDIR/confirm" bash "$(receive_bin)" receive < "$BATS_TEST_TMPDIR/blob"
  [ "$status" -eq 0 ]
  [[ "$output" == *"received MY_TOKEN"* ]]
  [[ "$output" != *"sk-secret-abc123"* ]]     # value never surfaced
  run store_extract MY_TOKEN
  [ "$output" = "sk-secret-abc123" ]
}

@test "hard-refuse when the confirm source is unreadable and --yes-i-reviewed absent" {
  setup_store
  make_blob MY_TOKEN 'v' > "$BATS_TEST_TMPDIR/blob"
  run env AGSEC_CONFIRM_SRC="$BATS_TEST_TMPDIR/does-not-exist" bash "$(receive_bin)" receive < "$BATS_TEST_TMPDIR/blob"
  [ "$status" -ne 0 ]
  [[ "$output" == *"controlling terminal"* ]]
  run store_has MY_TOKEN
  [ "$status" -ne 0 ]                          # nothing stored
}

@test "--yes-i-reviewed ingests with no usable tty (fresh name)" {
  setup_store
  make_blob CI_TOKEN 'ci-value-1' > "$BATS_TEST_TMPDIR/blob"
  run env AGSEC_CONFIRM_SRC="$BATS_TEST_TMPDIR/does-not-exist" bash "$(receive_bin)" receive --yes-i-reviewed < "$BATS_TEST_TMPDIR/blob"
  [ "$status" -eq 0 ]
  run store_extract CI_TOKEN
  [ "$output" = "ci-value-1" ]
}

@test "--yes-i-reviewed still hard-errors on the canary name" {
  setup_store
  make_blob "$AGENT_SECRETS_CANARY_NAME" 'x' > "$BATS_TEST_TMPDIR/blob"
  run env AGSEC_CONFIRM_SRC="$BATS_TEST_TMPDIR/does-not-exist" bash "$(receive_bin)" receive --yes-i-reviewed < "$BATS_TEST_TMPDIR/blob"
  [ "$status" -ne 0 ]
  [[ "$output" == *"canary"* ]]
}

@test "--yes-i-reviewed treats a NAME collision as a HARD error (never a silent overwrite)" {
  setup_store
  printf 'original-value' | store_add COLLIDE
  make_blob COLLIDE 'attacker-value' > "$BATS_TEST_TMPDIR/blob"
  run env AGSEC_CONFIRM_SRC="$BATS_TEST_TMPDIR/does-not-exist" bash "$(receive_bin)" receive --yes-i-reviewed < "$BATS_TEST_TMPDIR/blob"
  [ "$status" -ne 0 ]
  [[ "$output" == *"already exists"* ]]
  run store_extract COLLIDE
  [ "$output" = "original-value" ]            # untouched
}

@test "an unknown receive flag is a usage error (exit 2, per the documented convention)" {
  setup_store
  run bash "$(receive_bin)" receive --bogus </dev/null
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown flag"* ]]
}

@test "unknown envelope version is rejected" {
  setup_store
  make_blob_ver MY_TOKEN 'v' v9 > "$BATS_TEST_TMPDIR/blob"
  printf 'y\n' > "$BATS_TEST_TMPDIR/confirm"
  run env AGSEC_CONFIRM_SRC="$BATS_TEST_TMPDIR/confirm" bash "$(receive_bin)" receive < "$BATS_TEST_TMPDIR/blob"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown or unsupported share envelope"* ]]
}

@test "existing-NAME hard-stop: confirm honored (a 'no' aborts, value unchanged)" {
  setup_store
  printf 'keep-me' | store_add DUPE
  make_blob DUPE 'incoming' > "$BATS_TEST_TMPDIR/blob"
  printf 'n\n' > "$BATS_TEST_TMPDIR/confirm"
  run env AGSEC_CONFIRM_SRC="$BATS_TEST_TMPDIR/confirm" bash "$(receive_bin)" receive < "$BATS_TEST_TMPDIR/blob"
  [ "$status" -ne 0 ]
  [[ "$output" == *"aborted"* ]]
  run store_extract DUPE
  [ "$output" = "keep-me" ]                    # confirm was HONORED, not defaulted to yes
}

@test "existing-NAME hard-stop: confirm 'y' overwrites" {
  setup_store
  printf 'keep-me' | store_add DUPE
  make_blob DUPE 'incoming-new' > "$BATS_TEST_TMPDIR/blob"
  printf 'y\n' > "$BATS_TEST_TMPDIR/confirm"
  run env AGSEC_CONFIRM_SRC="$BATS_TEST_TMPDIR/confirm" bash "$(receive_bin)" receive < "$BATS_TEST_TMPDIR/blob"
  [ "$status" -eq 0 ]
  run store_extract DUPE
  [ "$output" = "incoming-new" ]
}

@test "--rename stores under the new name and dodges the collision" {
  setup_store
  printf 'orig' | store_add TAKEN
  make_blob TAKEN 'renamed-value' > "$BATS_TEST_TMPDIR/blob"
  printf 'y\n' > "$BATS_TEST_TMPDIR/confirm"
  run env AGSEC_CONFIRM_SRC="$BATS_TEST_TMPDIR/confirm" bash "$(receive_bin)" receive --rename FRESH < "$BATS_TEST_TMPDIR/blob"
  [ "$status" -eq 0 ]
  run store_extract FRESH
  [ "$output" = "renamed-value" ]
  run store_extract TAKEN
  [ "$output" = "orig" ]                       # original left intact
}

@test "canary name is refused (no confirm, interactive path)" {
  setup_store
  make_blob "$AGENT_SECRETS_CANARY_NAME" 'x' > "$BATS_TEST_TMPDIR/blob"
  printf 'y\n' > "$BATS_TEST_TMPDIR/confirm"
  run env AGSEC_CONFIRM_SRC="$BATS_TEST_TMPDIR/confirm" bash "$(receive_bin)" receive < "$BATS_TEST_TMPDIR/blob"
  [ "$status" -ne 0 ]
  [[ "$output" == *"canary"* ]]
}

@test "receive REFUSES a multi-line value (v0.1 stores single-line only)" {
  setup_store
  local pem
  pem="$(printf -- '-----BEGIN PRIVATE KEY-----\nAAAA1111\nBBBB2222\n-----END PRIVATE KEY-----')"
  make_blob MY_PEM "$pem" > "$BATS_TEST_TMPDIR/blob"
  printf 'y\n' > "$BATS_TEST_TMPDIR/confirm"
  run env AGSEC_CONFIRM_SRC="$BATS_TEST_TMPDIR/confirm" bash "$(receive_bin)" receive < "$BATS_TEST_TMPDIR/blob"
  [ "$status" -eq 2 ]                         # refused (multi-line unsupported in v0.1)
  [[ "$output" == *"MULTI-LINE"* || "$output" == *"single-line"* ]]
  [[ "$output" != *"AAAA1111"* ]]            # the refusal never echoes the value
  ! store_has MY_PEM                          # nothing stored
}

@test "value never appears in argv (age shim records \$@)" {
  setup_store
  local real_age shim="$BATS_TEST_TMPDIR/shim" log="$BATS_TEST_TMPDIR/age-argv.log"
  real_age="$(command -v age)"
  mkdir -p "$shim"
  { printf '#!/usr/bin/env bash\n'
    printf 'printf "%%s\\n" "$*" >> "%s"\n' "$log"
    printf 'exec "%s" "$@"\n' "$real_age"; } > "$shim/age"
  chmod +x "$shim/age"
  make_blob ARGV_TOKEN 'super-secret-argv-value' > "$BATS_TEST_TMPDIR/blob"
  printf 'y\n' > "$BATS_TEST_TMPDIR/confirm"
  run env PATH="$shim:$PATH" AGSEC_CONFIRM_SRC="$BATS_TEST_TMPDIR/confirm" bash "$(receive_bin)" receive < "$BATS_TEST_TMPDIR/blob"
  [ "$status" -eq 0 ]
  [ -f "$log" ]
  run cat "$log"
  [[ "$output" != *"super-secret-argv-value"* ]]
}

@test "oversized raw envelope is rejected BEFORE decode" {
  setup_store
  make_blob BIG 'v' > "$BATS_TEST_TMPDIR/blob"
  head -c 70000 /dev/zero | tr '\0' 'A' >> "$BATS_TEST_TMPDIR/blob"   # pad past 65536 bytes
  printf 'y\n' > "$BATS_TEST_TMPDIR/confirm"
  run env AGSEC_CONFIRM_SRC="$BATS_TEST_TMPDIR/confirm" bash "$(receive_bin)" receive < "$BATS_TEST_TMPDIR/blob"
  [ "$status" -ne 0 ]
  [[ "$output" == *"too large"* ]]
  [[ "$output" == *"before decode"* ]]
}

@test "oversized decoded ciphertext is rejected BEFORE decrypt (raw under the first cap)" {
  setup_store
  local big
  big="$(head -c 40000 /dev/zero | tr '\0' 'Z')"   # ~40KB plaintext → decoded ciphertext > 32768
  make_blob BIGCT "$big" > "$BATS_TEST_TMPDIR/blob"
  [ "$(wc -c < "$BATS_TEST_TMPDIR/blob")" -le 65536 ]   # still under the raw cap
  printf 'y\n' > "$BATS_TEST_TMPDIR/confirm"
  run env AGSEC_CONFIRM_SRC="$BATS_TEST_TMPDIR/confirm" bash "$(receive_bin)" receive < "$BATS_TEST_TMPDIR/blob"
  [ "$status" -ne 0 ]
  [[ "$output" == *"too large"* ]]
  [[ "$output" == *"before decrypt"* ]]
}

@test "unsigned blob proceeds with a loud 'sender unverified' warning" {
  setup_store
  make_blob UNS 'unsigned-val' > "$BATS_TEST_TMPDIR/blob"
  printf 'y\n' > "$BATS_TEST_TMPDIR/confirm"
  run env AGSEC_CONFIRM_SRC="$BATS_TEST_TMPDIR/confirm" bash "$(receive_bin)" receive < "$BATS_TEST_TMPDIR/blob"
  [ "$status" -eq 0 ]
  [[ "$output" == *"sender unverified"* ]]
}

@test "the locally-recomputed digest is displayed, pointed at the in-band 'digest:' line" {
  setup_store
  make_blob DIG 'digest-me' > "$BATS_TEST_TMPDIR/blob"
  # what receive should recompute, independently:
  local expect
  expect="$(sed '1,4d;$d' "$BATS_TEST_TMPDIR/blob" | sed '1d;$d' | base64 -D | agsec_digest)"
  printf 'y\n' > "$BATS_TEST_TMPDIR/confirm"
  run env AGSEC_CONFIRM_SRC="$BATS_TEST_TMPDIR/confirm" bash "$(receive_bin)" receive < "$BATS_TEST_TMPDIR/blob"
  [ "$status" -eq 0 ]
  [[ "$output" == *"digest $expect"* ]]                 # the recomputed value is shown …
  [[ "$output" == *"matches the 'digest:' line"* ]]     # … and coherently framed (not the recipient-key fingerprint)
}

@test "chat-mangled armor (a non-base64 byte) fails closed with the curated message, never a silent abort" {
  setup_store
  # A marker-valid v1 envelope whose AGE body carries a non-ASCII byte (NBSP), exactly as a rich-text
  # chat client can inject. base64 -D rejects it; receive must reach the curated 'could not decrypt',
  # not a diagnostic-free set -e crash (the bare-assignment pipefail hazard).
  {
    printf -- '-----BEGIN AGENT-SECRETS SHARE v1-----\n'
    printf 'name: MANGLED\ndirection: sent\ndigest: sha256:deadbeef0000\n'
    printf -- '-----BEGIN AGE ENCRYPTED FILE-----\n'
    printf 'AAAA\xc2\xa0BBBB\n'
    printf -- '-----END AGE ENCRYPTED FILE-----\n'
    printf -- '-----END AGENT-SECRETS SHARE v1-----\n'
  } > "$BATS_TEST_TMPDIR/blob"
  printf 'y\n' > "$BATS_TEST_TMPDIR/confirm"
  run env AGSEC_CONFIRM_SRC="$BATS_TEST_TMPDIR/confirm" bash "$(receive_bin)" receive < "$BATS_TEST_TMPDIR/blob"
  [ "$status" -ne 0 ]
  [ -n "$output" ]                                       # NOT a silent zero-output abort
  [[ "$output" == *"could not decrypt"* ]]
  run store_has MANGLED
  [ "$status" -ne 0 ]                                    # nothing stored
}

@test "a store-write failure AFTER decrypt leaves no plaintext temp behind (EXIT trap shreds it)" {
  setup_store
  make_blob TRAPPED 'plaintext-must-not-persist-9x' > "$BATS_TEST_TMPDIR/blob"
  printf 'y\n' > "$BATS_TEST_TMPDIR/confirm"
  # Shadow sops so the store write fails AFTER receive has already decrypted the value into its temp.
  local shim="$BATS_TEST_TMPDIR/shim"; mkdir -p "$shim"
  printf '#!/usr/bin/env bash\nexit 7\n' > "$shim/sops"; chmod +x "$shim/sops"
  run env PATH="$shim:$PATH" AGSEC_CONFIRM_SRC="$BATS_TEST_TMPDIR/confirm" bash "$(receive_bin)" receive < "$BATS_TEST_TMPDIR/blob"
  [ "$status" -ne 0 ]                                    # store write failed
  # The decrypted VALUE must NOT survive as a stray temp in the config dir.
  run grep -rl 'plaintext-must-not-persist-9x' "$AGENT_SECRETS_HOME/.config/secrets"
  [ "$status" -ne 0 ]                                    # grep -l found nothing → the plaintext was shredded
}

@test "blob not encrypted to our key fails closed with a curated message and no age stderr fragment" {
  setup_store
  # Encrypt to a DIFFERENT (throwaway) recipient → our identity can't decrypt.
  local otherpub armor
  age-keygen -o "$BATS_TEST_TMPDIR/other.key" 2>/dev/null
  otherpub="$(age-keygen -y "$BATS_TEST_TMPDIR/other.key")"
  armor="$(printf '%s' 'unreachable' | age -r "$otherpub" -a)"
  {
    printf -- '-----BEGIN AGENT-SECRETS SHARE v1-----\n'
    printf 'name: WRONGKEY\ndirection: sent\ndigest: sha256:aaaaaaaaaaaa\n'
    printf '%s\n' "$armor"
    printf -- '-----END AGENT-SECRETS SHARE v1-----\n'
  } > "$BATS_TEST_TMPDIR/blob"
  printf 'y\n' > "$BATS_TEST_TMPDIR/confirm"
  run env AGSEC_CONFIRM_SRC="$BATS_TEST_TMPDIR/confirm" bash "$(receive_bin)" receive < "$BATS_TEST_TMPDIR/blob"
  [ "$status" -ne 0 ]
  [[ "$output" == *"could not decrypt"* ]]
  [[ "$output" != *"age:"* ]]                 # no raw age diagnostic leaked
  [[ "$output" != *"no identity matched"* ]]
}
