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
  [[ "$output" == *"not sops ciphertext"* ]]
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
  [[ "$output" == *"PUBLIC"* ]]
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
