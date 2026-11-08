#!/usr/bin/env bats
# tests/backup.bats — `agent-secrets backup`: off-machine encrypted-store copy via gh.
# A local BARE repo (mock gh) stands in for the private GitHub repo. The load-bearing invariant:
# ciphertext + PUBLIC metadata leave; the age PRIVATE key never does.
bats_require_minimum_version 1.5.0
load test_helper
load mode_matrix

_mk_remote() { AGSEC_MOCK_GH_REMOTE="$(mktemp -d "${TMPDIR:-/tmp}/agsec-remote.XXXXXX")/store.git"; export AGSEC_MOCK_GH_REMOTE; }
_rm_remote() { [ -n "${AGSEC_MOCK_GH_REMOTE:-}" ] && rm -rf "$(dirname "$AGSEC_MOCK_GH_REMOTE")"; }

@test "backup pushes ciphertext + public metadata, NEVER the private age key" {
  setup_store
  _mk_remote
  run agsec backup --repo testuser/agent-secrets-store --yes
  [ "$status" -eq 0 ]
  [[ "$output" == *"backed up"* ]] || return 1

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
  [[ "$output" == *"off-machine backup"* ]] || return 1
  [[ "$output" == *"none"* ]] || return 1

  _mk_remote
  agsec backup --repo me/store --yes >/dev/null
  [ -f "$(agsec_config_dir 2>/dev/null || echo "$AGENT_SECRETS_HOME/.config/secrets")/backup-repo" ] || \
    [ -f "$AGENT_SECRETS_HOME/.config/secrets/backup-repo" ]

  run agsec doctor
  [[ "$output" == *"configured (me/store)"* ]] || return 1
  _rm_remote
}

@test "backup is idempotent: a second run with no changes reports 'already up to date'" {
  setup_store
  _mk_remote
  agsec backup --repo me/store --yes >/dev/null
  run agsec backup --repo me/store --yes
  [ "$status" -eq 0 ]
  [[ "$output" == *"already up to date"* ]] || return 1
  _rm_remote
}

@test "backup refuses without a store" {
  # no setup_store → no secrets.env
  _mk_remote
  run agsec backup --repo me/store --yes
  [ "$status" -ne 0 ]
  [[ "$output" == *"no store to back up"* ]] || return 1
  _rm_remote
}

@test "backup pushes to the repo's default branch (master), not a divergent main" {
  setup_store
  local dir; dir="$(mktemp -d "${TMPDIR:-/tmp}/agsec-remote.XXXXXX")"
  export AGSEC_MOCK_GH_REMOTE="$dir/store.git"
  git init --bare -q -b master "$AGSEC_MOCK_GH_REMOTE" 2>/dev/null \
    || { git init --bare -q "$AGSEC_MOCK_GH_REMOTE"; git -C "$AGSEC_MOCK_GH_REMOTE" symbolic-ref HEAD refs/heads/master; }
  agsec backup --repo me/store --yes >/dev/null
  git -C "$AGSEC_MOCK_GH_REMOTE" rev-parse --verify master >/dev/null 2>&1      # landed on master…
  ! git -C "$AGSEC_MOCK_GH_REMOTE" rev-parse --verify main >/dev/null 2>&1      # …not a new main
  run agsec backup --repo me/store --yes                                        # 2nd run: clean no-op, not a reject
  [ "$status" -eq 0 ]
  rm -rf "$dir"
}

@test "backup refuses a non-ciphertext secrets.env (defense in depth)" {
  setup_store
  local dir; dir="$(mktemp -d "${TMPDIR:-/tmp}/agsec-remote.XXXXXX")"
  export AGSEC_MOCK_GH_REMOTE="$dir/store.git"
  printf 'PLAINTEXT_KEY=oops-not-encrypted\n' >"$(agsec_config_dir)/secrets.env"  # simulate a broken/plaintext store
  run agsec backup --repo me/store --yes
  [ "$status" -ne 0 ]
  [[ "$output" == *"not sops ciphertext"* ]] || return 1
  rm -rf "$dir"
}

@test "backup drops ONLY its own marked egress proxy, never a bare loopback (corporate forwarder safe)" {
  # Regression guard for the fresh-scan finding: backup must key off AGENT_SECRETS_EGRESS_PROXY (the
  # exact URL egress_run stamped), NOT the broad *127.0.0.1* pattern that would nuke a corporate
  # loopback forwarder (Cntlm/px/ZTNA on 127.0.0.1:3128).
  grep -q 'AGENT_SECRETS_EGRESS_PROXY' "$REPO_ROOT/cmd/backup.sh"
  ! grep -qE 'case[^\n]*HTTPS_PROXY[^\n]*127\.0\.0\.1' "$REPO_ROOT/cmd/backup.sh"
  grep -q 'AGENT_SECRETS_EGRESS_PROXY="' "$REPO_ROOT/lib/egress.sh"   # egress_run stamps the marker
}

@test "backup drops its egress proxy BEFORE the first gh network call (auth preflight)" {
  # The unset MUST precede `gh auth status` — otherwise, inside an egress session where github.com
  # isn't allowlisted, the proxied preflight is refused and backup dies "not authenticated" first.
  local drop_line auth_line
  drop_line="$(grep -n '^  unset HTTPS_PROXY' "$REPO_ROOT/cmd/backup.sh" | head -1 | cut -d: -f1)"
  auth_line="$(grep -n '^gh auth status >/dev/null' "$REPO_ROOT/cmd/backup.sh" | head -1 | cut -d: -f1)"
  [ -n "$drop_line" ] && [ -n "$auth_line" ]
  [ "$drop_line" -lt "$auth_line" ]
}

@test "backup REFUSES an existing PUBLIC repo (the secret-name inventory must stay private)" {
  setup_store
  local dir; dir="$(mktemp -d "${TMPDIR:-/tmp}/agsec-remote.XXXXXX")"
  export AGSEC_MOCK_GH_REMOTE="$dir/store.git"
  git init --bare -q "$AGSEC_MOCK_GH_REMOTE"       # repo exists…
  export AGSEC_MOCK_GH_PRIVATE=false               # …and is PUBLIC
  run agsec backup --repo me/store --yes
  [ "$status" -ne 0 ]
  [[ "$output" == *"PUBLIC"* ]] || return 1
  unset AGSEC_MOCK_GH_PRIVATE; rm -rf "$dir"
}

@test "backup strips the colleague-share social graph from the pushed manifest" {
  setup_store
  printf 'x' | store_add SHARED_ONE
  store_manifest_set_sharing SHARED_ONE shared_with='sha256:deadbeef1234' direction='sent'
  _mk_remote
  agsec backup --repo me/store --yes >/dev/null
  local work; work="$(mktemp -d)"; git clone -q "$AGSEC_MOCK_GH_REMOTE" "$work"
  grep -q 'name = "SHARED_ONE"' "$work/manifest.toml"          # credential name kept
  ! grep -q '^shared_with = ' "$work/manifest.toml"            # social graph stripped
  ! grep -q '^direction = ' "$work/manifest.toml"
  rm -rf "$work"; _rm_remote
}

# ---- repo lookup fails closed (only GitHub's "not found" may lead to a create) ------------------

@test "backup fails closed when gh repo view fails for another reason" {
  setup_store
  _mk_remote
  export AGSEC_MOCK_GH_VIEW_FAIL=network
  run --separate-stderr agsec backup --repo me/store --yes
  [ "$status" -eq 1 ]
  [ -z "$output" ]                                   # nothing on stdout on a failure
  [[ "$stderr" == *"Couldn't look up me/store: error connecting to api.github.com."* ]] || return 1
  [[ "$stderr" == *"gh auth status"* ]] || return 1
  [ ! -e "$AGSEC_MOCK_GH_REMOTE" ]                   # nothing created
  [ ! -f "$AGENT_SECRETS_HOME/.config/secrets/backup-repo" ]
  unset AGSEC_MOCK_GH_VIEW_FAIL; _rm_remote
}

@test "backup refuses when isPrivate is unknown" {
  setup_store
  _mk_remote
  git init --bare -q "$AGSEC_MOCK_GH_REMOTE"         # the repo exists, but gh says nothing about privacy
  export AGSEC_MOCK_GH_PRIVATE=none
  run --separate-stderr agsec backup --repo me/store --yes
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [[ "$stderr" == *"Couldn't confirm me/store is private (gh returned '')."* ]] || return 1
  [ -z "$(git -C "$AGSEC_MOCK_GH_REMOTE" for-each-ref)" ]   # nothing pushed
  unset AGSEC_MOCK_GH_PRIVATE; _rm_remote
}

@test "backup without --yes and no terminal exits 2 naming --yes" {
  setup_store
  _mk_remote
  run --separate-stderr env -u AGENT_SECRETS_UNATTENDED bash "$REPO_ROOT/bin/agent-secrets" backup --repo me/store </dev/null
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  [[ "$stderr" == *"--yes"* ]] || return 1
  [[ "$stderr" == *"agent-secrets backup --repo me/store --yes"* ]] || return 1
  [[ "$stderr" != *"Create PRIVATE GitHub repo"* ]] || return 1   # no prompt
  [ ! -e "$AGSEC_MOCK_GH_REMOTE" ]
  _rm_remote
}

@test "backup prints only owner/name on stdout" {
  setup_store
  _mk_remote
  run --separate-stderr agsec backup --repo me/store --yes
  [ "$status" -eq 0 ]
  [ "$output" = "me/store" ]
  [[ "$stderr" == *"created private repo me/store"* ]] || return 1
  [[ "$stderr" == *"backed up to me/store"* ]] || return 1
  [ "$(cat "$AGENT_SECRETS_HOME/.config/secrets/backup-repo")" = "me/store" ]
  run --separate-stderr agsec backup --repo me/store --yes     # the no-op run too
  [ "$status" -eq 0 ]
  [ "$output" = "me/store" ]
  [[ "$stderr" == *"already up to date"* ]] || return 1
  _rm_remote
}

# ---- usage errors and the parse-only seam ----------------------------------------------------------

@test "backup usage errors name the flag but never a value or a stray argument" {
  run --separate-stderr agsec backup --bogus=not-a-flag-value
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"Unknown option '--bogus' for backup."* ]] || return 1
  [[ "$stderr" != *"not-a-flag-value"* ]] || return 1
  run --separate-stderr agsec backup stray-token
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"Unexpected argument for backup."* ]] || return 1
  [[ "$stderr" != *"stray-token"* ]] || return 1
}

@test "backup parse-only exits 0 before any gh call or write" {
  setup_store
  _mk_remote
  local log="$AGENT_SECRETS_HOME/gh.log"
  # A gh that records any call: the seam must come before the auth preflight.
  mkdir -p "$AGENT_SECRETS_HOME/ghlog"
  printf '#!/bin/sh\necho "$*" >>"%s"\nexit 0\n' "$log" >"$AGENT_SECRETS_HOME/ghlog/gh"
  chmod +x "$AGENT_SECRETS_HOME/ghlog/gh"
  PATH="$AGENT_SECRETS_HOME/ghlog:$PATH" AGSEC_PARSE_ONLY=1 run agsec backup --repo me/store --yes
  [ "$status" -eq 0 ]
  [ ! -e "$log" ]
  [ ! -e "$AGSEC_MOCK_GH_REMOTE" ]
  [ ! -f "$AGENT_SECRETS_HOME/.config/secrets/backup-repo" ]
  _rm_remote
}

# ---- mode matrix for the create-repo prompt ----------------------------------------------------------

_cli() { printf '%s\n' "$REPO_ROOT/bin/agent-secrets"; }

@test "backup create prompt: every non-interactive mode without --yes exits 2 naming --yes, no prompt, no repo" {
  setup_store
  local mode
  for mode in stdin-piped agent; do
    _mk_remote
    mm_run "$mode" -- bash "$(_cli)" backup --repo me/store
    [ "$mm_status" -eq 2 ] || { echo "$mode: status $mm_status"; return 1; }
    [ -z "$mm_stdout" ] || { echo "$mode: stdout [$mm_stdout]"; return 1; }
    [[ "$mm_stderr" == *"--yes"* ]] || { echo "$mode: stderr [$mm_stderr]"; return 1; }
    [[ "$mm_stderr" != *"Create PRIVATE GitHub repo"* ]] || { echo "$mode: prompted"; return 1; }
    [ ! -e "$AGSEC_MOCK_GH_REMOTE" ] || { echo "$mode: repo created"; return 1; }
    _rm_remote
  done
  for mode in ci-tty noninteractive-tty; do
    _mk_remote
    mm_run "$mode" -- bash "$(_cli)" backup --repo me/store
    [ "$mm_status" -eq 2 ] || { echo "$mode: status $mm_status"; return 1; }
    [[ "$mm_pty" == *"--yes"* ]] || { echo "$mode: pty [$mm_pty]"; return 1; }
    [[ "$mm_pty" != *"Create PRIVATE GitHub repo"* ]] || { echo "$mode: prompted"; return 1; }
    [ ! -e "$AGSEC_MOCK_GH_REMOTE" ] || { echo "$mode: repo created"; return 1; }
    _rm_remote
  done
  # backup has no --json: json-tty is a usage error, not a prompt.
  _mk_remote
  mm_run json-tty -- bash "$(_cli)" backup --repo me/store --json
  [ "$mm_status" -eq 2 ]
  [[ "$mm_pty" == *"Unknown option '--json' for backup."* ]] || return 1
  [[ "$mm_pty" != *"Create PRIVATE GitHub repo"* ]] || return 1
  [ ! -e "$AGSEC_MOCK_GH_REMOTE" ]
  _rm_remote
}

@test "backup create prompt: a terminal prompts, and EOF at the prompt cancels with 130, nothing created" {
  setup_store
  _mk_remote
  mm_run stdout-redirected -- bash "$(_cli)" backup --repo me/store
  [ "$mm_status" -eq 130 ]
  [ -z "$mm_stdout" ]
  [[ "$mm_pty" == *"Create PRIVATE GitHub repo me/store"* ]] || return 1
  [[ "$mm_pty" == *"nothing was created"* ]] || return 1
  [ ! -e "$AGSEC_MOCK_GH_REMOTE" ]
  _rm_remote
}

@test "backup create prompt: with --yes every mode proceeds without a prompt (json-tty stays a usage error)" {
  setup_store
  local mode
  for mode in tty stdout-redirected stdin-piped noninteractive-tty ci-tty agent; do
    _mk_remote
    mm_run "$mode" -- bash "$(_cli)" backup --repo me/store --yes
    [ "$mm_status" -eq 0 ] || { echo "$mode: status $mm_status [$mm_stderr$mm_pty]"; return 1; }
    case "$mode" in
      stdout-redirected|stdin-piped|agent)
        [ "$mm_stdout" = "me/store" ] || { echo "$mode: stdout [$mm_stdout]"; return 1; } ;;
    esac
    [[ "$mm_stderr$mm_pty" == *"backed up to me/store"* ]] || { echo "$mode: no receipt"; return 1; }
    [[ "$mm_stderr$mm_pty" != *"Create PRIVATE GitHub repo"* ]] || { echo "$mode: prompted"; return 1; }
    git -C "$AGSEC_MOCK_GH_REMOTE" rev-parse --verify -q main >/dev/null || { echo "$mode: nothing pushed"; return 1; }
    _rm_remote
  done
  _mk_remote
  mm_run json-tty -- bash "$(_cli)" backup --repo me/store --yes --json
  [ "$mm_status" -eq 2 ]
  [ ! -e "$AGSEC_MOCK_GH_REMOTE" ]
  _rm_remote
}

# Answers the create prompt on a real pty. The drive bounds follow tests/wizard_interactive.bats.
_drive_create() {  # ANSWER
  local exp="$AGENT_SECRETS_HOME/drive.exp"
  printf '%s\n' \
    'set timeout -1' \
    'after 900000 { puts "\nDESYNC-TIMEOUT"; exit 90 }' \
    'spawn env -u CLAUDECODE -u CLAUDE_CODE -u CURSOR_AGENT -u CURSOR_TRACE_ID -u TERM_PROGRAM -u CI -u AGENT_SECRETS_NONINTERACTIVE -u AGENT_SECRETS_UNATTENDED -u AGSEC_TEST_CONFIRM bash $env(REPO_ROOT)/bin/agent-secrets backup --repo me/store' \
    'expect "Create PRIVATE GitHub repo me/store for your encrypted-store backup?" { send "'"$1"'\r" }' \
    'expect eof { }' \
    'catch wait result' \
    'if {[llength $result] > 4} { puts "\nBACKUP-KILLED $result"; exit 92 }' \
    'exit [lindex $result 3]' >"$exp"
  expect "$exp"
}

@test "backup create prompt on a terminal: y creates the repo and backs up" {
  command -v expect >/dev/null 2>&1 || skip "expect not available"
  setup_store
  _mk_remote
  run _drive_create y
  [ "$status" -eq 0 ]
  [[ "$output" == *"created private repo me/store"* ]] || return 1
  [[ "$output" == *"backed up to me/store"* ]] || return 1
  git -C "$AGSEC_MOCK_GH_REMOTE" rev-parse --verify -q main >/dev/null
  _rm_remote
}

@test "backup create prompt on a terminal: n cancels with 130 and creates nothing" {
  command -v expect >/dev/null 2>&1 || skip "expect not available"
  setup_store
  _mk_remote
  run _drive_create n
  [ "$status" -eq 130 ]
  [[ "$output" == *"backup cancelled — nothing was created (pass --yes to skip this prompt)"* ]] || return 1
  [ ! -e "$AGSEC_MOCK_GH_REMOTE" ]
  _rm_remote
}
