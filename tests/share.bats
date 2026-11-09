#!/usr/bin/env bats
# tests/share.bats — the `share` verb + the don't-share ladder (design §3.4-3.10, §6).
# Names-only: every assertion checks NAMES/metadata/ciphertext; a secret VALUE must never surface.
bats_require_minimum_version 1.5.0
load test_helper
load mode_matrix

# The bats runner may itself be inside an agent session (CLAUDECODE set), which share correctly
# refuses. Strip the agent-session env for the ordinary-terminal cases; the CLAUDECODE-refusal test
# re-adds it explicitly. Per-test env (AGSEC_CONFIRM_SRC, AGSEC_MOCK_KEYS, …) is exported by the test
# and passes straight through this `env` (it only unsets the agent markers).
_sh() {  # _sh <share args…>  → sets $status/$output via `run`
  run env -u CLAUDECODE -u CLAUDE_CODE -u CURSOR_AGENT -u CURSOR_TRACE_ID -u TERM_PROGRAM \
    bash "$REPO_ROOT/bin/agent-secrets" share "$@"
}
_sh_sep() {  # like _sh, with stdout in $output and stderr in $stderr
  run --separate-stderr env -u CLAUDECODE -u CLAUDE_CODE -u CURSOR_AGENT -u CURSOR_TRACE_ID -u TERM_PROGRAM \
    bash "$REPO_ROOT/bin/agent-secrets" share "$@"
}

# _drive PROMPT ANSWER SHELL-CMD: run SHELL-CMD on a fresh pty with the file confirm seam off, answer the
# first PROMPT with ANSWER, and set $output to the pty transcript and $status to the command's exit.
_drive() {
  command -v expect >/dev/null 2>&1 || skip "expect not available"
  cat >"$BATS_TEST_TMPDIR/drive.exp" <<'EOF'
# One wall-clock bound and no per-expect timeout: see tests/wizard_interactive.bats.
set timeout -1
after 900000 { puts "\nDESYNC-TIMEOUT"; exit 90 }
spawn env -u CLAUDECODE -u CLAUDE_CODE -u CURSOR_AGENT -u CURSOR_TRACE_ID -u TERM_PROGRAM -u CI -u AGENT_SECRETS_NONINTERACTIVE -u AGSEC_TEST_CONFIRM -u AGSEC_CONFIRM_SRC bash -c $env(DRIVE_SH)
expect -ex $env(DRIVE_PROMPT) { send -- "$env(DRIVE_ANSWER)\r" }
expect eof { }
catch wait result
if {[llength $result] > 4} { puts "\nDRIVE-KILLED $result"; exit 92 }
exit [lindex $result 3]
EOF
  run env DRIVE_PROMPT="$1" DRIVE_ANSWER="$2" DRIVE_SH="$3" expect "$BATS_TEST_TMPDIR/drive.exp"
}

# Generate a fresh age recipient; echo its age1… recipient string. Identity file at $1.
_gen_recip() { age-keygen -o "$1" 2>/dev/null; age-keygen -y "$1"; }

# Point AGSEC_CONFIRM_SRC at a file carrying the answer $1 (y / n).
_confirm() { local f="$AGENT_SECRETS_HOME/confirm.$RANDOM"; printf '%s\n' "$1" >"$f"; export AGSEC_CONFIRM_SRC="$f"; }

# Stand up a store + a couple of secrets + a recipient key. Sets $RECIP.
_share_fixture() {
  setup_store
  printf '%s' 'sk-ant-SECRETVALUE-do-not-leak-42' | agsec add ANTHROPIC_API_KEY
  printf '%s' 'whsec_SECRETVALUE-webhook-99'       | agsec add TEAM_WEBHOOK_SECRET
  RECIP="$(_gen_recip "$AGENT_SECRETS_HOME/recip.key")"
}

# --- ladder -------------------------------------------------------------------
@test "ladder refuses a per-person-mintable name without --singleton (prints R2 recipe, exit≠0)" {
  _share_fixture; _confirm y
  _sh ANTHROPIC_API_KEY --to "$RECIP"
  [ "$status" -ne 0 ]
  [[ "$output" == *"mint their own"* ]] || return 1
  [[ "$output" == *"--singleton"* ]] || return 1
  [[ "$output" == *"Anthropic"* ]] || return 1
  [[ "$output" != *"BEGIN AGE ENCRYPTED FILE"* ]] || return 1
}

@test "--singleton bypasses the R2 rung and proceeds to emit an envelope" {
  _share_fixture; _confirm y
  _sh ANTHROPIC_API_KEY --to "$RECIP" --singleton
  [ "$status" -eq 0 ]
  [[ "$output" == *"BEGIN AGENT-SECRETS SHARE v1"* ]] || return 1
}

@test "a symmetric-by-construction (WEBHOOK) name takes R3 and proceeds without --singleton" {
  _share_fixture; _confirm y
  _sh TEAM_WEBHOOK_SECRET --to "$RECIP"
  [ "$status" -eq 0 ]
  [[ "$output" == *"BEGIN AGENT-SECRETS SHARE v1"* ]] || return 1
}

# --- self (R0) ----------------------------------------------------------------
@test "--to self takes R0: no manifest sharing row is written" {
  _share_fixture; _confirm y
  _sh ANTHROPIC_API_KEY --to self
  [ "$status" -eq 0 ]
  [[ "$output" == *"BEGIN AGENT-SECRETS SHARE v1"* ]] || return 1
  run grep -c 'shared_with' "$AGENT_SECRETS_HOME/.config/secrets/manifest.toml"
  [ "$output" -eq 0 ]
}

# --- the ONE confirm ----------------------------------------------------------
@test "the confirm is read from AGSEC_CONFIRM_SRC; 'n' aborts with nothing shared" {
  _share_fixture; _confirm n
  _sh ANTHROPIC_API_KEY --to "$RECIP" --singleton
  [ "$status" -eq 130 ]
  [[ "$output" == *"aborted"* ]] || return 1
  [[ "$output" != *"BEGIN AGE ENCRYPTED FILE"* ]] || return 1
}

@test "the confirm prompt leads with the VALUE of NAME + recipient fingerprint" {
  _share_fixture; _confirm y
  _sh ANTHROPIC_API_KEY --to "$RECIP" --singleton
  [ "$status" -eq 0 ]
  [[ "$output" == *"Share the VALUE of ANTHROPIC_API_KEY"* ]] || return 1
  [[ "$output" == *"sha256:"* ]] || return 1
}

# --- value-in-argv guard (croc CVE-2023-43621) --------------------------------
@test "the secret VALUE never reaches age's argv (STDIN-only)" {
  _share_fixture; _confirm y
  local mockdir="$AGENT_SECRETS_HOME/mockbin"; mkdir -p "$mockdir"
  local realage; realage="$(command -v age)"
  cat >"$mockdir/age" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" >>"$AGENT_SECRETS_HOME/age-argv.log"
exec "$realage" "\$@"
EOF
  chmod +x "$mockdir/age"
  PATH="$mockdir:$PATH" _sh ANTHROPIC_API_KEY --to "$RECIP" --singleton
  [ "$status" -eq 0 ]
  grep -q -- '-r' "$AGENT_SECRETS_HOME/age-argv.log"
  run grep -F 'sk-ant-SECRETVALUE' "$AGENT_SECRETS_HOME/age-argv.log"
  [ "$status" -ne 0 ]
}

# --- envelope shape -----------------------------------------------------------
@test "the blob is code-fenced and the envelope carries name / direction: sent / digest:" {
  _share_fixture; _confirm y
  _sh ANTHROPIC_API_KEY --to "$RECIP" --singleton
  [ "$status" -eq 0 ]
  [[ "$output" == *'```'* ]] || return 1
  [[ "$output" == *"name: ANTHROPIC_API_KEY"* ]] || return 1
  [[ "$output" == *"direction: sent"* ]] || return 1
  [[ "$output" == *"digest: sha256:"* ]] || return 1
  [[ "$output" == *"-----END AGENT-SECRETS SHARE v1-----"* ]] || return 1
}

@test "--rename relabels the envelope name field" {
  _share_fixture; _confirm y
  _sh ANTHROPIC_API_KEY --to "$RECIP" --singleton --rename DANA_ANTHROPIC
  [ "$status" -eq 0 ]
  [[ "$output" == *"name: DANA_ANTHROPIC"* ]] || return 1
}

# --- digest stability across a benign armor reflow ----------------------------
@test "the digest is stable across a benign base64 reflow of the armor" {
  _share_fixture; _confirm y
  _sh ANTHROPIC_API_KEY --to "$RECIP" --singleton
  [ "$status" -eq 0 ]
  local emb body d1 d2
  emb="$(printf '%s\n' "$output" | sed -n 's/^digest: //p')"
  body="$(printf '%s\n' "$output" | sed -n '/-----BEGIN AGE ENCRYPTED FILE-----/,/-----END AGE ENCRYPTED FILE-----/p' | sed '1d;$d')"
  d1="$(printf '%s\n' "$body" | base64 -D | agsec_digest)"
  d2="$(printf '%s\n' "$body" | base64 -D | base64 | fold -w 24 | base64 -D | agsec_digest)"
  [ "$d1" = "$d2" ]
  [ "$emb" = "$d1" ]
}

# --- argument-parse + NAME-grammar guards -------------------------------------
@test "a trailing --to with no value fails with the usage error (exit 2), not a silent set -e abort" {
  _share_fixture; _confirm y
  _sh ANTHROPIC_API_KEY --to
  [ "$status" -eq 2 ]
  [[ "$output" == *"--to <recipient> is required"* ]] || return 1
}

@test "a NAME with regex metacharacters fails fast as 'no such secret', not a raw sops/age error" {
  _share_fixture; _confirm y
  _sh "ANTHROPIC.API.KEY" --to "$RECIP" --singleton     # '.' would wildcard-match ANTHROPIC_API_KEY in store_has's grep
  [ "$status" -ne 0 ]
  [[ "$output" == *"no such secret"* ]] || return 1
  [[ "$output" != *"encryption failed"* ]] || return 1
  [[ "$output" != *"BEGIN AGE ENCRYPTED FILE"* ]] || return 1
}

# --- store_extract | age, NOT sops -e (static) --------------------------------
@test "share uses store_extract piped into age -r, never sops -e" {
  grep -q 'store_extract "\$name" | age' "$REPO_ROOT/cmd/share.sh"
  run grep -F 'sops -e' "$REPO_ROOT/cmd/share.sh"
  [ "$status" -ne 0 ]
}

# --- github:user recipient path -----------------------------------------------
@test "github:user writes .keys to a temp file and encrypts to a usable recipient" {
  _share_fixture; _confirm y
  local other; other="$(_gen_recip "$AGENT_SECRETS_HOME/dana.key")"
  AGSEC_MOCK_KEYS="$other" _sh TEAM_WEBHOOK_SECRET --to github:dana
  [ "$status" -eq 0 ]
  [[ "$output" == *"BEGIN AGENT-SECRETS SHARE v1"* ]] || return 1
  [[ "$output" == *'name: TEAM_WEBHOOK_SECRET'* ]] || return 1
}

@test "an empty .keys from github fails loud (never a zero-recipient encrypt)" {
  _share_fixture; _confirm y
  AGSEC_MOCK_KEYS="" _sh TEAM_WEBHOOK_SECRET --to github:ghost
  [ "$status" -ne 0 ]
  [[ "$output" == *"no age-usable public keys"* ]] || return 1
  [[ "$output" != *"BEGIN AGE ENCRYPTED FILE"* ]] || return 1
}

# --- SSH cert / sk-FIDO2 rejection --------------------------------------------
@test "an sk-FIDO2 recipient is rejected at input with the reason" {
  _share_fixture; _confirm y
  _sh TEAM_WEBHOOK_SECRET --to "sk-ssh-ed25519@openssh.com"
  [ "$status" -ne 0 ]
  [[ "$output" == *"sk-FIDO2"* ]] || return 1
}

# --- manifest row for a real recipient ----------------------------------------
@test "a real-recipient share records the manifest sharing row (direction=sent)" {
  _share_fixture; _confirm y
  _sh ANTHROPIC_API_KEY --to "$RECIP" --singleton
  [ "$status" -eq 0 ]
  local man="$AGENT_SECRETS_HOME/.config/secrets/manifest.toml"
  grep -q 'shared_with = "sha256:' "$man"
  grep -q 'direction = "sent"' "$man"
}

# --- agent-session + no-tty refusals ------------------------------------------
@test "share refuses inside a simulated agent session (CLAUDECODE=1)" {
  _share_fixture; _confirm y
  run env -u CLAUDE_CODE -u CURSOR_AGENT -u CURSOR_TRACE_ID -u TERM_PROGRAM CLAUDECODE=1 \
    bash "$REPO_ROOT/bin/agent-secrets" share ANTHROPIC_API_KEY --to "$RECIP" --singleton
  [ "$status" -ne 0 ]
  [[ "$output" == *"agent session"* ]] || return 1
  [[ "$output" != *"BEGIN AGE ENCRYPTED FILE"* ]] || return 1
}

@test "share refuses with no readable confirm source and no unattended flag" {
  _share_fixture
  export AGSEC_CONFIRM_SRC="$AGENT_SECRETS_HOME/nope/missing"
  _sh ANTHROPIC_API_KEY --to "$RECIP" --singleton
  [ "$status" -eq 2 ]
  [[ "$output" == *"interactive terminal"* ]] || return 1
}

@test "the canary name is hard-refused for share (no confirm)" {
  _share_fixture; _confirm y
  _sh AWS_BACKUP_ACCESS_KEY_ID --to "$RECIP" --singleton
  [ "$status" -ne 0 ]
  [[ "$output" == *"canary"* ]] || return 1
}

# --- AGENT_SECRETS_UNATTENDED auto-answers the confirm, but never bypasses the tty gate ---
@test "AGENT_SECRETS_UNATTENDED=1 auto-answers the confirm (openable terminal) and emits the envelope" {
  _share_fixture; _confirm y            # openable confirm source (the tty gate passes)
  export AGENT_SECRETS_UNATTENDED=1
  _sh ANTHROPIC_API_KEY --to "$RECIP" --singleton
  [ "$status" -eq 0 ]
  [[ "$output" == *"BEGIN AGENT-SECRETS SHARE v1"* ]] || return 1
}

@test "AGENT_SECRETS_UNATTENDED=1 does NOT bypass the interactive-terminal gate (agent-exfil boundary)" {
  _share_fixture
  export AGSEC_CONFIRM_SRC="$AGENT_SECRETS_HOME/nope/missing" AGENT_SECRETS_UNATTENDED=1
  _sh ANTHROPIC_API_KEY --to "$RECIP" --singleton
  [ "$status" -eq 2 ]
  [[ "$output" == *"interactive terminal"* ]] || return 1
  [[ "$output" != *"BEGIN AGE ENCRYPTED FILE"* ]] || return 1     # nothing shared with no controlling tty
}

# --- SH1: the confirm gate requires a REAL tty, not a mere openable file ---------
@test "share REFUSES a regular-file confirm source in production (no AGSEC_TEST_CONFIRM) — the exfil block" {
  _share_fixture
  # Reproduce the exfil chain: env stripped, confirm pointed at a 'y' file, unattended + singleton.
  # Without the test seam the tty gate must refuse (a regular file is not a controlling terminal).
  printf 'y\n' > "$AGENT_SECRETS_HOME/y"
  run env -u CLAUDECODE -u CLAUDE_CODE -u CURSOR_AGENT -u CURSOR_TRACE_ID -u TERM_PROGRAM -u AGSEC_TEST_CONFIRM \
    AGSEC_CONFIRM_SRC="$AGENT_SECRETS_HOME/y" AGENT_SECRETS_UNATTENDED=1 \
    bash "$REPO_ROOT/bin/agent-secrets" share ANTHROPIC_API_KEY --to "$RECIP" --singleton
  [ "$status" -eq 2 ]
  [[ "$output" == *"interactive terminal"* ]] || return 1
  [[ "$output" != *"BEGIN AGE ENCRYPTED FILE"* ]] || return 1   # no ciphertext exfiltrated
}

@test "share still works with the file-based confirm seam UNDER AGSEC_TEST_CONFIRM=1 (test harness)" {
  _share_fixture; _confirm y                        # test_helper exports AGSEC_TEST_CONFIRM=1
  _sh ANTHROPIC_API_KEY --to "$RECIP" --singleton
  [ "$status" -eq 0 ]
  [[ "$output" == *"BEGIN AGENT-SECRETS SHARE v1"* ]] || return 1
}

# --- SH4: --rename is grammar-checked at parse (fail-fast, not fail-late at recipient) ---
@test "share --rename with an invalid NAME fails fast with a clear error, emits nothing" {
  _share_fixture; _confirm y
  _sh ANTHROPIC_API_KEY --to "$RECIP" --singleton --rename 'bad-name.oops'
  [ "$status" -ne 0 ]
  [[ "$output" == *"not a valid name"* ]] || return 1
  [[ "$output" != *"BEGIN AGE ENCRYPTED FILE"* ]] || return 1
}

# --- streams, exit codes and usage wording -------------------------------------
@test "share stdout is only the fenced envelope" {
  _share_fixture; _confirm y
  _sh_sep TEAM_WEBHOOK_SECRET --to "$RECIP"
  [ "$status" -eq 0 ]
  [[ "$output" != *"✓"* ]] || return 1
  [ "$(printf '%s\n' "$output" | head -1)" = '```' ]
  [ "$(printf '%s\n' "$output" | tail -1)" = '```' ]
  [[ "$output" != *"Share the VALUE"* ]] || return 1
  [[ "$stderr" == *"encrypted "* ]] || return 1
}

@test "share --verify asks whether the recipient confirmed the digest" {
  _share_fixture; _confirm y
  _sh_sep TEAM_WEBHOOK_SECRET --to "$RECIP" --verify
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"Did the recipient confirm this digest matches? [y/N]"* ]] || return 1
  [[ "$stderr" != *"Proceed?"* ]] || return 1
}

@test "share --to github:a/b exits 2 and never fetches" {
  _share_fixture; _confirm y
  local log="$AGENT_SECRETS_HOME/curl.log"
  AGSEC_MOCK_CURL_LOG="$log" _sh TEAM_WEBHOOK_SECRET --to 'github:a/b'
  [ "$status" -eq 2 ]
  [[ "$output" == *"is not a valid GitHub login"* ]] || return 1
  [ ! -s "$log" ]
}

@test "share on an undecryptable store says so, not 'no such secret'" {
  _share_fixture; _confirm y
  printf 'NOT_A_SOPS_FILE=1\n' >"$(agsec_store_file)"
  _sh TEAM_WEBHOOK_SECRET --to "$RECIP"
  [ "$status" -ne 0 ]
  [[ "$output" == *"decrypt the store"* ]] || return 1
  [[ "$output" != *"no such secret"* ]] || return 1
}

@test "share's usage errors name the option but never echo a surplus argument" {
  _share_fixture; _confirm y
  _sh TEAM_WEBHOOK_SECRET --to self --bogus=fake-placeholder
  [ "$status" -eq 2 ]
  [[ "$output" == *"Unknown option '--bogus' for share."* ]] || return 1
  [[ "$output" != *"fake-placeholder"* ]] || return 1
  _sh TEAM_WEBHOOK_SECRET fake-placeholder --to self
  [ "$status" -eq 2 ]
  [[ "$output" == *"Unexpected argument for share."* ]] || return 1
  [[ "$output" != *"fake-placeholder"* ]] || return 1
}

@test "AGSEC_PARSE_ONLY stops share after parsing, before the agent and terminal gates" {
  _share_fixture
  run env CLAUDECODE=1 AGSEC_PARSE_ONLY=1 bash "$REPO_ROOT/bin/agent-secrets" share TEAM_WEBHOOK_SECRET --to self
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- mode matrix around the share confirm ----------------------------------------
@test "share confirm, mode matrix: only a real terminal is asked; every other mode refuses" {
  _share_fixture
  unset AGSEC_CONFIRM_SRC
  local cmd=(bash "$REPO_ROOT/bin/agent-secrets" share TEAM_WEBHOOK_SECRET --to self)
  local out="$AGENT_SECRETS_HOME/envelope.out"
  local sh="exec bash \"\$REPO_ROOT/bin/agent-secrets\" share TEAM_WEBHOOK_SECRET --to self"

  _drive '[y/N]' y "$sh"                                  # tty, answered y
  [ "$status" -eq 0 ]
  [[ "$output" == *"Share the VALUE of TEAM_WEBHOOK_SECRET"* ]] || return 1
  [[ "$output" == *"BEGIN AGENT-SECRETS SHARE v1"* ]] || return 1

  _drive '[y/N]' y "$sh >\"$out\""                        # stdout-redirected, answered y
  [ "$status" -eq 0 ]
  [[ "$output" == *"Share the VALUE of TEAM_WEBHOOK_SECRET"* ]] || return 1
  [[ "$output" != *"BEGIN AGE ENCRYPTED FILE"* ]] || return 1
  grep -q 'BEGIN AGENT-SECRETS SHARE v1' "$out"
  if grep -q 'Share the VALUE' "$out"; then return 1; fi

  local mode
  for mode in stdin-piped ci-tty noninteractive-tty; do
    mm_run "$mode" -- "${cmd[@]}"
    [ "$mm_status" -eq 2 ] || { echo "$mode: status $mm_status"; return 1; }
    [[ "$mm_pty$mm_stderr" == *"share needs an interactive terminal"* ]] || { echo "$mode: no refusal"; return 1; }
    [[ "$mm_pty$mm_stdout$mm_stderr" != *"Share the VALUE"* ]] || { echo "$mode: prompted"; return 1; }
    [ -z "$mm_stdout" ] || { echo "$mode: stdout not empty"; return 1; }
  done

  mm_run agent -- "${cmd[@]}"
  [ "$mm_status" -eq 1 ]
  [[ "$mm_stderr" == *"agent session"* ]] || return 1
  [[ "$mm_stdout$mm_stderr" != *"Share the VALUE"* ]] || return 1
  [ -z "$mm_stdout" ]

  mm_run json-tty -- "${cmd[@]}" --json
  [ "$mm_status" -eq 2 ]
  [[ "$mm_pty" != *"Share the VALUE"* ]] || return 1
  [[ "$mm_pty" != *"BEGIN AGE ENCRYPTED FILE"* ]] || return 1
}
