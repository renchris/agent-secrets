# tests/test_helper.bash — shared bats setup. Synthetic-HOME isolation.
# Every .bats file: `load test_helper`. Never touches the real HOME, username, or login Keychain.
# this harness is the isolation contract — extend, do not weaken it.

setup() {
  # Throwaway HOME for this test; the tool resolves every path via agsec_home()→AGENT_SECRETS_HOME.
  AGENT_SECRETS_HOME="$(mktemp -d "${TMPDIR:-/tmp}/agsec-test.XXXXXX")"
  export AGENT_SECRETS_HOME
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export REPO_ROOT
  # Mocks (security/launchctl/brew/gh/pbcopy/pgrep) shadow the real binaries.
  export PATH="$BATS_TEST_DIRNAME/mocks:$PATH"
  # Deterministic, value-free output.
  export AGENT_SECRETS_PLAIN=1 NO_COLOR=1
}

teardown() {
  [ -n "${AGENT_SECRETS_HOME:-}" ] && [ -d "$AGENT_SECRETS_HOME" ] && rm -rf "$AGENT_SECRETS_HOME"
}

# Invoke the installed dispatcher (it self-resolves lib/ and cmd/).
agsec() { bash "$REPO_ROOT/bin/agent-secrets" "$@"; }
