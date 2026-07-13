#!/usr/bin/env bats
# tests/install.bats — install.sh bootstrap: dry-run fidelity + the baked-SHA integrity gate.
# The FIRST tests to exercise install-from-tarball (the audit flagged this coverage gap). Fully
# synthetic-HOME + mocked (curl/brew/launchctl/security/osascript) — no network, no real Keychain.
load test_helper

# Build a real runtime tarball into a mock "mirror" dir the curl mock serves (AGSEC_MOCK_DL_DIR).
# Exports: TAG, PKG (basename), MIRROR (dir). SHA of the built tarball → $BUILT_SHA.
_build_mirror() {
  TAG="v0.1.0"; PKG="agent-secrets-${TAG}.tar.gz"
  MIRROR="$(mktemp -d "${TMPDIR:-/tmp}/agsec-mirror.XXXXXX")"
  ( cd "$REPO_ROOT" && git archive --prefix="agent-secrets-${TAG}/" HEAD -o "$MIRROR/$PKG" )
  BUILT_SHA="$(shasum -a 256 "$MIRROR/$PKG" | awk '{print $1}')"
  printf '%s  %s\n' "$BUILT_SHA" "$PKG" >"$MIRROR/$PKG.sha256"
  export AGSEC_MOCK_DL_DIR="$MIRROR" TAG PKG MIRROR BUILT_SHA
}

teardown() {
  [ -n "${MIRROR:-}" ] && [ -d "$MIRROR" ] && rm -rf "$MIRROR"
  [ -n "${AGENT_SECRETS_HOME:-}" ] && [ -d "$AGENT_SECRETS_HOME" ] && rm -rf "$AGENT_SECRETS_HOME"
}

@test "install --dry-run renders the complete plan and mutates nothing" {
  run bash "$REPO_ROOT/install.sh" --dry-run
  [ "$status" -eq 0 ]
  # The plan must name every real change (the dry-run-fidelity finding): dispatcher + wrappers,
  # the settings.json backup, and the launchd job.
  [[ "$output" == *"agent-secrets, claude-agent, cursor-agent, apiKeyHelper"* ]]
  [[ "$output" == *"back up an existing ~/.claude/settings.json"* ]]
  [[ "$output" == *"weekly launchd smoke job"* ]]
  # Zero mutation.
  [ ! -d "$AGENT_SECRETS_HOME/.agent-secrets" ]
  [ ! -e "$AGENT_SECRETS_HOME/bin/agent-secrets" ]
}

@test "default production URL REFUSES to install with no baked digest (supply-chain gate)" {
  _build_mirror
  # No AGENT_SECRETS_BASE_URL → default production URL; install.sh on main carries an empty
  # EXPECTED_SHA256 → it must DIE rather than trust a same-origin sibling .sha256.
  run bash -c "printf '\n' | AGENT_SECRETS_HOME='$AGENT_SECRETS_HOME' bash '$REPO_ROOT/install.sh'"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no baked release digest"* ]]
  [ ! -d "$AGENT_SECRETS_HOME/.agent-secrets" ]   # nothing unpacked
}

@test "dev-mirror install rejects a tampered tarball (SHA-256 mismatch)" {
  _build_mirror
  # Corrupt the served .sha256 so got != expect on the dev-mirror path (BASE_URL set).
  printf '%s  %s\n' "0000000000000000000000000000000000000000000000000000000000000000" "$PKG" >"$MIRROR/$PKG.sha256"
  run bash -c "printf '\n' | AGENT_SECRETS_BASE_URL='https://mirror.example' AGENT_SECRETS_HOME='$AGENT_SECRETS_HOME' bash '$REPO_ROOT/install.sh'"
  [ "$status" -ne 0 ]
  [[ "$output" == *"SHA-256 mismatch"* ]]
  [ ! -d "$AGENT_SECRETS_HOME/.agent-secrets" ]
}

@test "baked-digest production install verifies, unpacks, and passes the layout guard" {
  _build_mirror
  # Simulate the released install.sh: bake the real tarball digest in (git-ref channel), production URL.
  local baked="$MIRROR/install.sh"
  sed "s/EXPECTED_SHA256=\"[a-f0-9]*\"/EXPECTED_SHA256=\"$BUILT_SHA\"/" "$REPO_ROOT/install.sh" >"$baked"
  run bash -c "printf '\nfake-value\n' | AGENT_SECRETS_UNATTENDED=1 AGENT_SECRETS_HOME='$AGENT_SECRETS_HOME' bash '$baked'"
  [[ "$output" == *"SHA-256 verified"* ]]
  # Baked gate passed → the tool unpacked with the expected single-prefix layout, dispatcher symlinked.
  [ -f "$AGENT_SECRETS_HOME/.agent-secrets/lib/common.sh" ]
  [ -L "$AGENT_SECRETS_HOME/bin/agent-secrets" ]
}
