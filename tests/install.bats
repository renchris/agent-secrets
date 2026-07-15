#!/usr/bin/env bats
# tests/install.bats — install.sh bootstrap: dry-run fidelity + the baked-SHA integrity gate.
# The FIRST tests to exercise install-from-tarball (the audit flagged this coverage gap). Fully
# synthetic-HOME + mocked (curl/brew/launchctl/security/osascript) — no network, no real Keychain.
load test_helper

# Build a real runtime tarball into a mock "mirror" dir the curl mock serves (AGSEC_MOCK_DL_DIR).
# Exports: TAG, PKG (basename), MIRROR (dir). SHA of the built tarball → $BUILT_SHA.
_build_mirror() {
  TAG="v0.1.1"; PKG="agent-secrets-${TAG}.tar.gz"
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
  [[ "$output" == *"agent-secrets, claude-agent, cursor-agent, apiKeyHelper"* ]] || return 1
  [[ "$output" == *"back up an existing ~/.claude/settings.json"* ]] || return 1
  [[ "$output" == *"weekly launchd smoke job"* ]] || return 1
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
  [[ "$output" == *"no baked release digest"* ]] || return 1
  [ ! -d "$AGENT_SECRETS_HOME/.agent-secrets" ]   # nothing unpacked
}

@test "dev-mirror install rejects a tampered tarball (SHA-256 mismatch)" {
  _build_mirror
  # Corrupt the served .sha256 so got != expect on the dev-mirror path (BASE_URL set).
  printf '%s  %s\n' "0000000000000000000000000000000000000000000000000000000000000000" "$PKG" >"$MIRROR/$PKG.sha256"
  run bash -c "printf '\n' | AGENT_SECRETS_BASE_URL='https://mirror.example' AGENT_SECRETS_HOME='$AGENT_SECRETS_HOME' bash '$REPO_ROOT/install.sh'"
  [ "$status" -ne 0 ]
  [[ "$output" == *"SHA-256 mismatch"* ]] || return 1
  [ ! -d "$AGENT_SECRETS_HOME/.agent-secrets" ]
}

@test "baked-digest production install verifies, unpacks, and passes the layout guard" {
  _build_mirror
  # Simulate the released install.sh: bake the real tarball digest in (git-ref channel), production URL.
  local baked="$MIRROR/install.sh"
  sed "s/EXPECTED_SHA256=\"[a-f0-9]*\"/EXPECTED_SHA256=\"$BUILT_SHA\"/" "$REPO_ROOT/install.sh" >"$baked"
  run bash -c "printf '\nfake-value\n' | AGENT_SECRETS_UNATTENDED=1 AGENT_SECRETS_HOME='$AGENT_SECRETS_HOME' bash '$baked'"
  [[ "$output" == *"SHA-256 verified"* ]] || return 1
  # Baked gate passed → the tool unpacked with the expected single-prefix layout, dispatcher symlinked.
  [ -f "$AGENT_SECRETS_HOME/.agent-secrets/lib/common.sh" ]
  [ -L "$AGENT_SECRETS_HOME/bin/agent-secrets" ]
}

@test "install under /bin/sh completes a REAL install — re-execs out of POSIX mode, past manifest.sh (feedback BLOCKER #1)" {
  _build_mirror
  local baked="$MIRROR/install.sh"
  sed "s/EXPECTED_SHA256=\"[a-f0-9]*\"/EXPECTED_SHA256=\"$BUILT_SHA\"/" "$REPO_ROOT/install.sh" >"$baked"
  # macOS /bin/sh IS bash-3.2 in POSIX mode and SETS BASH_VERSION, so a BASH_VERSION-only guard would
  # skip the re-exec and die on lib/manifest.sh's process substitution. Drive a REAL (non-dry-run)
  # install via /bin/sh: it must re-exec and run to completion (past manifest_init + symlink wiring),
  # not merely render --dry-run (which returns before manifest.sh is ever sourced — false confidence).
  run bash -c "printf 'fake-value\n' | AGENT_SECRETS_UNATTENDED=1 AGENT_SECRETS_HOME='$AGENT_SECRETS_HOME' /bin/sh '$baked'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"SHA-256 verified"* ]] || return 1
  [ -L "$AGENT_SECRETS_HOME/bin/agent-secrets" ]                                 # wrappers wired ⇒ got past manifest.sh
  [ -f "$AGENT_SECRETS_HOME/.local/state/agent-secrets/install-manifest.json" ]  # manifest_init ran
}

@test "install in an agent session with CLOSED stdin defers the key ceremony, exit 0 (feedback BLOCKER #2)" {
  _build_mirror
  local baked="$MIRROR/install.sh"
  sed "s/EXPECTED_SHA256=\"[a-f0-9]*\"/EXPECTED_SHA256=\"$BUILT_SHA\"/" "$REPO_ROOT/install.sh" >"$baked"
  # A real Cursor/Claude-Code session has NON-tty stdin (often /dev/null). The feedback saw "Installed."
  # then exit 1; a naive fix still aborts at the consent `read` (EOF under set -e) before the deferral.
  # With no stdin piped, the tool install must SUCCEED (exit 0) and route the human to a real terminal.
  run bash -c "CLAUDECODE=1 AGENT_SECRETS_HOME='$AGENT_SECRETS_HOME' bash '$baked' </dev/null"
  [ "$status" -eq 0 ]
  [[ "$output" == *"real terminal"* ]] || return 1
  [[ "$output" == *"agent-secrets setup"* ]] || return 1
  [ -f "$AGENT_SECRETS_HOME/.agent-secrets/lib/common.sh" ]     # tool unpacked
  [ -L "$AGENT_SECRETS_HOME/bin/agent-secrets" ]                # wired onto PATH
  [ ! -f "$AGENT_SECRETS_HOME/.config/secrets/secrets.env" ]    # key ceremony correctly SKIPPED
}

@test "a required-dependency failure removes the unpacked tool — no unrecorded residue (cleanup trap)" {
  _build_mirror
  local baked="$MIRROR/install.sh"
  sed "s/EXPECTED_SHA256=\"[a-f0-9]*\"/EXPECTED_SHA256=\"$BUILT_SHA\"/" "$REPO_ROOT/install.sh" >"$baked"
  # The corporate failure: no age/sops/gum on PATH, no Homebrew, dep downloads blocked (age is not in the
  # mock mirror). deps_ensure aborts on the REQUIRED age AFTER the tool is unpacked. The cleanup trap must
  # remove ~/.agent-secrets so `agent-secrets uninstall` is never left with un-rollback-able residue.
  run bash -c "PATH='$BATS_TEST_DIRNAME/mocks:/usr/bin:/bin:/usr/sbin:/sbin' AGSEC_MOCK_DL_DIR='$MIRROR' AGENT_SECRETS_DEPS_NO_BREW=1 AGENT_SECRETS_HOME='$AGENT_SECRETS_HOME' bash '$baked' </dev/null"
  [ "$status" -ne 0 ]                                           # required dep unresolved → abort
  [ ! -d "$AGENT_SECRETS_HOME/.agent-secrets" ]                 # trap removed the unpacked tool
  [ ! -e "$AGENT_SECRETS_HOME/bin/agent-secrets" ]             # nothing left wired
}

@test "cleanup trap survives a shell metacharacter (single quote) in the install home (%q quoting)" {
  _build_mirror
  local baked="$MIRROR/install.sh"
  sed "s/EXPECTED_SHA256=\"[a-f0-9]*\"/EXPECTED_SHA256=\"$BUILT_SHA\"/" "$REPO_ROOT/install.sh" >"$baked"
  # An install path with a single quote (e.g. an exotic AGENT_SECRETS_HOME) must not break the cleanup
  # trap's stored command — expand-now single-quoting would abort with an unmatched-quote parse error and
  # leave residue. Force the required-dep failure and assert the tool is still removed.
  local qhome; qhome="$(mktemp -d)/o'brien"; mkdir -p "$qhome"
  run env "PATH=$BATS_TEST_DIRNAME/mocks:/usr/bin:/bin:/usr/sbin:/sbin" "AGSEC_MOCK_DL_DIR=$MIRROR" \
      AGENT_SECRETS_DEPS_NO_BREW=1 "AGENT_SECRETS_HOME=$qhome" bash "$baked" </dev/null
  [ "$status" -ne 0 ]
  [ ! -d "$qhome/.agent-secrets" ]                              # trap ran cleanly despite the quote
  rm -rf "$(dirname "$qhome")"
}
