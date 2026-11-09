#!/usr/bin/env bats
# tests/receive.bats — the `receive` verb: tty-gated ingest, local digest, canary + collision guards,
# dual byte caps, multi-line safety, value-never-in-argv. Blobs are built INLINE (no dependency on the
# `share` verb) by encrypting a test value to the recipient's OWN age key (setup_store writes age.pub).
bats_require_minimum_version 1.5.0
load test_helper
load mode_matrix

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

# _drive PASTE-FILE PROMPT ANSWER SHELL-CMD: run SHELL-CMD on a fresh pty with the file confirm seam off,
# paste PASTE-FILE at the envelope prompt and end it with Ctrl-D, answer PROMPT with ANSWER, and set
# $output to the pty transcript and $status to the command's exit.
_drive() {
  command -v expect >/dev/null 2>&1 || skip "expect not available"
  cat >"$BATS_TEST_TMPDIR/drive.exp" <<'EOF'
# One wall-clock bound and no per-expect timeout: see tests/wizard_interactive.bats.
set timeout -1
after 900000 { puts "\nDESYNC-TIMEOUT"; exit 90 }
spawn env -u CLAUDECODE -u CLAUDE_CODE -u CURSOR_AGENT -u CURSOR_TRACE_ID -u TERM_PROGRAM -u CI -u AGENT_SECRETS_NONINTERACTIVE -u AGSEC_TEST_CONFIRM -u AGSEC_CONFIRM_SRC bash -c $env(DRIVE_SH)
expect -ex "Paste the share envelope"
set fh [open $env(DRIVE_PASTE) r]
while {[gets $fh l] >= 0} { send -- "$l\r" }
close $fh
send "\004"
expect -ex $env(DRIVE_PROMPT) { send -- "$env(DRIVE_ANSWER)\r" }
expect eof { }
catch wait result
if {[llength $result] > 4} { puts "\nDRIVE-KILLED $result"; exit 92 }
exit [lindex $result 3]
EOF
  run env DRIVE_PASTE="$1" DRIVE_PROMPT="$2" DRIVE_ANSWER="$3" DRIVE_SH="$4" expect "$BATS_TEST_TMPDIR/drive.exp"
}

@test "round-trip: single-line value ingests from STDIN and stores names-only" {
  setup_store
  make_blob MY_TOKEN 'sk-secret-abc123' > "$BATS_TEST_TMPDIR/blob"
  printf 'y\n' > "$BATS_TEST_TMPDIR/confirm"
  run env AGSEC_CONFIRM_SRC="$BATS_TEST_TMPDIR/confirm" bash "$(receive_bin)" receive < "$BATS_TEST_TMPDIR/blob"
  [ "$status" -eq 0 ]
  [[ "$output" == *"received MY_TOKEN"* ]] || return 1
  [[ "$output" != *"sk-secret-abc123"* ]] || return 1     # value never surfaced
  run store_extract MY_TOKEN
  [ "$output" = "sk-secret-abc123" ]
}

@test "hard-refuse when the confirm source is unreadable and --yes-i-reviewed absent" {
  setup_store
  make_blob MY_TOKEN 'v' > "$BATS_TEST_TMPDIR/blob"
  run env AGSEC_CONFIRM_SRC="$BATS_TEST_TMPDIR/does-not-exist" bash "$(receive_bin)" receive < "$BATS_TEST_TMPDIR/blob"
  [ "$status" -eq 2 ]
  [[ "$output" == *"controlling terminal"* ]] || return 1
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

@test "-y and --yes are aliases of --yes-i-reviewed: each ingests with no usable tty" {
  setup_store
  local flag n=0
  for flag in -y --yes; do
    n=$((n + 1))
    make_blob "CI_ALIAS_$n" "ci-alias-$n" > "$BATS_TEST_TMPDIR/blob"
    run env AGSEC_CONFIRM_SRC="$BATS_TEST_TMPDIR/does-not-exist" bash "$(receive_bin)" receive "$flag" < "$BATS_TEST_TMPDIR/blob"
    [ "$status" -eq 0 ] || { echo "$flag: exit $status"; return 1; }
    [[ "$output" != *"deprecated"* ]] || return 1
    run store_extract "CI_ALIAS_$n"
    [ "$output" = "ci-alias-$n" ] || { echo "$flag: not stored"; return 1; }
  done
}

@test "--yes keeps the collision hard error, and a near-miss flag is still a usage error" {
  setup_store
  make_blob CI_TOKEN 'ci-value-1' > "$BATS_TEST_TMPDIR/blob"
  env AGSEC_CONFIRM_SRC="$BATS_TEST_TMPDIR/does-not-exist" bash "$(receive_bin)" receive --yes < "$BATS_TEST_TMPDIR/blob" >/dev/null 2>&1
  run env AGSEC_CONFIRM_SRC="$BATS_TEST_TMPDIR/does-not-exist" bash "$(receive_bin)" receive --yes < "$BATS_TEST_TMPDIR/blob"
  [ "$status" -eq 1 ]
  [[ "$output" == *"already exists"* ]] || return 1
  run env AGSEC_CONFIRM_SRC="$BATS_TEST_TMPDIR/does-not-exist" bash "$(receive_bin)" receive --yess < "$BATS_TEST_TMPDIR/blob"
  [ "$status" -eq 2 ]
}

@test "--yes-i-reviewed still hard-errors on the canary name" {
  setup_store
  make_blob "$AGENT_SECRETS_CANARY_NAME" 'x' > "$BATS_TEST_TMPDIR/blob"
  run env AGSEC_CONFIRM_SRC="$BATS_TEST_TMPDIR/does-not-exist" bash "$(receive_bin)" receive --yes-i-reviewed < "$BATS_TEST_TMPDIR/blob"
  [ "$status" -ne 0 ]
  [[ "$output" == *"canary"* ]] || return 1
}

@test "--yes-i-reviewed treats a NAME collision as a HARD error (never a silent overwrite)" {
  setup_store
  printf 'original-value' | store_add COLLIDE
  make_blob COLLIDE 'attacker-value' > "$BATS_TEST_TMPDIR/blob"
  run env AGSEC_CONFIRM_SRC="$BATS_TEST_TMPDIR/does-not-exist" bash "$(receive_bin)" receive --yes-i-reviewed < "$BATS_TEST_TMPDIR/blob"
  [ "$status" -ne 0 ]
  [[ "$output" == *"already exists"* ]] || return 1
  run store_extract COLLIDE
  [ "$output" = "original-value" ]            # untouched
}

@test "an unknown receive flag is a usage error (exit 2, per the documented convention)" {
  setup_store
  run bash "$(receive_bin)" receive --bogus </dev/null
  [ "$status" -eq 2 ]
  [[ "$output" == *"Unknown option"* ]] || return 1
}

@test "unknown envelope version is rejected" {
  setup_store
  make_blob_ver MY_TOKEN 'v' v9 > "$BATS_TEST_TMPDIR/blob"
  printf 'y\n' > "$BATS_TEST_TMPDIR/confirm"
  run env AGSEC_CONFIRM_SRC="$BATS_TEST_TMPDIR/confirm" bash "$(receive_bin)" receive < "$BATS_TEST_TMPDIR/blob"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown or unsupported share envelope"* ]] || return 1
}

@test "existing-NAME hard-stop: confirm honored (a 'no' aborts, value unchanged)" {
  setup_store
  printf 'keep-me' | store_add DUPE
  make_blob DUPE 'incoming' > "$BATS_TEST_TMPDIR/blob"
  printf 'n\n' > "$BATS_TEST_TMPDIR/confirm"
  run env AGSEC_CONFIRM_SRC="$BATS_TEST_TMPDIR/confirm" bash "$(receive_bin)" receive < "$BATS_TEST_TMPDIR/blob"
  [ "$status" -eq 130 ]
  [[ "$output" == *"aborted"* ]] || return 1
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
  [[ "$output" == *"canary"* ]] || return 1
}

@test "receive REFUSES a multi-line value (v0.1 stores single-line only)" {
  setup_store
  local pem
  pem="$(printf -- '-----BEGIN PRIVATE KEY-----\nAAAA1111\nBBBB2222\n-----END PRIVATE KEY-----')"
  make_blob MY_PEM "$pem" > "$BATS_TEST_TMPDIR/blob"
  printf 'y\n' > "$BATS_TEST_TMPDIR/confirm"
  run env AGSEC_CONFIRM_SRC="$BATS_TEST_TMPDIR/confirm" bash "$(receive_bin)" receive < "$BATS_TEST_TMPDIR/blob"
  [ "$status" -eq 2 ]                         # refused (multi-line unsupported in v0.1)
  [[ "$output" == *"MULTI-LINE"* || "$output" == *"single-line"* ]] || return 1
  [[ "$output" != *"AAAA1111"* ]] || return 1            # the refusal never echoes the value
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
  [[ "$output" != *"super-secret-argv-value"* ]] || return 1
}

@test "oversized raw envelope is rejected BEFORE decode" {
  setup_store
  make_blob BIG 'v' > "$BATS_TEST_TMPDIR/blob"
  head -c 70000 /dev/zero | tr '\0' 'A' >> "$BATS_TEST_TMPDIR/blob"   # pad past 65536 bytes
  printf 'y\n' > "$BATS_TEST_TMPDIR/confirm"
  run env AGSEC_CONFIRM_SRC="$BATS_TEST_TMPDIR/confirm" bash "$(receive_bin)" receive < "$BATS_TEST_TMPDIR/blob"
  [ "$status" -ne 0 ]
  [[ "$output" == *"too large"* ]] || return 1
  [[ "$output" == *"before decode"* ]] || return 1
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
  [[ "$output" == *"too large"* ]] || return 1
  [[ "$output" == *"before decrypt"* ]] || return 1
}

@test "unsigned blob proceeds with a loud 'sender unverified' warning" {
  setup_store
  make_blob UNS 'unsigned-val' > "$BATS_TEST_TMPDIR/blob"
  printf 'y\n' > "$BATS_TEST_TMPDIR/confirm"
  run env AGSEC_CONFIRM_SRC="$BATS_TEST_TMPDIR/confirm" bash "$(receive_bin)" receive < "$BATS_TEST_TMPDIR/blob"
  [ "$status" -eq 0 ]
  [[ "$output" == *"sender unverified"* ]] || return 1
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
  [[ "$output" == *"digest $expect"* ]] || return 1                 # the recomputed value is shown …
  [[ "$output" == *"matches the 'digest:' line"* ]] || return 1     # … and coherently framed (not the recipient-key fingerprint)
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
  [[ "$output" == *"could not decrypt"* ]] || return 1
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
  [[ "$output" == *"could not decrypt"* ]] || return 1
  [[ "$output" != *"age:"* ]] || return 1                 # no raw age diagnostic leaked
  [[ "$output" != *"no identity matched"* ]] || return 1
}

# --- streams, untrusted envelope text, read bound ------------------------------
@test "receive prints only NAME on stdout" {
  setup_store
  make_blob CI_TOKEN 'fake-placeholder' > "$BATS_TEST_TMPDIR/blob"
  run --separate-stderr bash "$(receive_bin)" receive --yes-i-reviewed < "$BATS_TEST_TMPDIR/blob"
  [ "$status" -eq 0 ]
  [ "$output" = CI_TOKEN ]
  [[ "$stderr" == *"received CI_TOKEN"* ]] || return 1
}

@test "receive on a malformed envelope exits non-zero with empty stdout" {
  setup_store
  printf 'not an envelope\n' > "$BATS_TEST_TMPDIR/blob"
  run --separate-stderr bash "$(receive_bin)" receive --yes-i-reviewed < "$BATS_TEST_TMPDIR/blob"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  [[ "$stderr" == *"unknown or unsupported share envelope"* ]] || return 1
}

@test "receive never echoes an ESC from the envelope name or digest" {
  setup_store
  local esc=$'\e' blob
  make_blob "BAD${esc}[2JNAME" 'fake-placeholder' > "$BATS_TEST_TMPDIR/blob"
  run bash "$(receive_bin)" receive --yes-i-reviewed < "$BATS_TEST_TMPDIR/blob"
  [ "$status" -ne 0 ]
  [[ "$output" == *"--rename NEW"* ]] || return 1
  [[ "$output" != *$'\e'* ]] || return 1
  blob="$(make_blob DIGEST_ESC 'fake-placeholder')"
  printf '%s\n' "${blob/digest: sha256:/digest: sha256:${esc}[2J}" > "$BATS_TEST_TMPDIR/blob"
  run bash "$(receive_bin)" receive --yes-i-reviewed < "$BATS_TEST_TMPDIR/blob"
  [ "$status" -eq 0 ]
  [[ "$output" == *"'digest:' line is malformed"* ]] || return 1
  [[ "$output" != *$'\e'* ]] || return 1
}

@test "receive refuses an endless stream without buffering it" {
  setup_store
  run bash -c 'head -c 200000 /dev/zero | tr "\0" A | bash "$1" receive --yes-i-reviewed' _ "$(receive_bin)"
  [ "$status" -eq 1 ]
  [[ "$output" == *"too large"* ]] || return 1
  [[ "$output" == *"before decode"* ]] || return 1
}

@test "receive on an undecryptable store stops before age decrypt" {
  setup_store
  make_blob UNREADABLE 'fake-placeholder' > "$BATS_TEST_TMPDIR/blob"
  printf 'NOT_A_SOPS_FILE=1\n' > "$(agsec_store_file)"
  local real_age shim="$BATS_TEST_TMPDIR/shim" log="$BATS_TEST_TMPDIR/age-argv.log"
  real_age="$(command -v age)"
  mkdir -p "$shim"
  { printf '#!/usr/bin/env bash\n'
    printf 'printf "%%s\\n" "$*" >> "%s"\n' "$log"
    printf 'exec "%s" "$@"\n' "$real_age"; } > "$shim/age"
  chmod +x "$shim/age"
  run env PATH="$shim:$PATH" bash "$(receive_bin)" receive --yes-i-reviewed < "$BATS_TEST_TMPDIR/blob"
  [ "$status" -ne 0 ]
  [[ "$output" == *"decrypt the store"* ]] || return 1
  [ ! -s "$log" ]                                        # age -d never ran
}

@test "AGSEC_PARSE_ONLY stops receive after parsing, before the store and terminal checks" {
  run env AGSEC_PARSE_ONLY=1 bash "$(receive_bin)" receive --rename NEW_NAME </dev/null
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- mode matrix around the overwrite prompt ---------------------------------------
@test "receive overwrite prompt, mode matrix: only a real terminal is asked; every other mode refuses" {
  setup_store
  printf 'keep-me' | store_add DUPE
  make_blob DUPE 'fake-incoming' > "$BATS_TEST_TMPDIR/blob"
  local sh="exec bash \"\$REPO_ROOT/bin/agent-secrets\" receive"
  local out="$BATS_TEST_TMPDIR/receive.out"

  _drive "$BATS_TEST_TMPDIR/blob" 'overwrite?' y "$sh"        # tty, answered y
  [ "$status" -eq 0 ]
  [[ "$output" == *"DUPE already exists in your store — overwrite?"* ]] || return 1
  run store_extract DUPE
  [ "$output" = fake-incoming ]

  printf 'keep-me' | store_add DUPE
  _drive "$BATS_TEST_TMPDIR/blob" 'overwrite?' y "$sh >\"$out\""   # stdout-redirected, answered y
  [ "$status" -eq 0 ]
  [[ "$output" == *"overwrite?"* ]] || return 1
  [ "$(cat "$out")" = DUPE ]
  run store_extract DUPE
  [ "$output" = fake-incoming ]

  printf 'keep-me' | store_add DUPE
  local cmd=(bash "$REPO_ROOT/bin/agent-secrets" receive) mode
  # receive is not env-gated (design §3.10), so the agent row refuses at the terminal gate: exit 2.
  for mode in stdin-piped ci-tty noninteractive-tty agent; do
    MM_INPUT="$(cat "$BATS_TEST_TMPDIR/blob")" mm_run "$mode" -- "${cmd[@]}"
    [ "$mm_status" -eq 2 ] || { echo "$mode: status $mm_status"; return 1; }
    [[ "$mm_pty$mm_stderr" == *"receive needs a controlling terminal"* ]] || { echo "$mode: no refusal"; return 1; }
    [[ "$mm_pty$mm_stdout$mm_stderr" != *"overwrite?"* ]] || { echo "$mode: prompted"; return 1; }
    [ -z "$mm_stdout" ] || { echo "$mode: stdout not empty"; return 1; }
  done

  mm_run json-tty -- "${cmd[@]}" --json
  [ "$mm_status" -eq 2 ]
  [[ "$mm_pty" != *"overwrite?"* ]] || return 1
  run store_extract DUPE
  [ "$output" = keep-me ]
}
