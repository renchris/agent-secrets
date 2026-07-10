# tests/test_helper.bash — shared bats setup. Synthetic-HOME isolation.
# Every .bats file: `load test_helper`. Never touches the real HOME, username, or login Keychain.
# This harness is the isolation contract — extend, do not weaken it.

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

# Stand up a REAL sops+age store under the synthetic HOME (throwaway keys, file custody, fake canary).
# Used by suites that need an initialized store. Never touches the real Keychain (mock is on PATH).
setup_store() {
  export AGENT_SECRETS_LIB="$REPO_ROOT/lib"
  # shellcheck source=/dev/null
  . "$REPO_ROOT/lib/common.sh"; . "$REPO_ROOT/lib/keychain.sh"; . "$REPO_ROOT/lib/store.sh"
  mkdir -p "$(agsec_config_dir)"
  age-keygen -o "$(agsec_age_key_file)" 2>/dev/null; chmod 600 "$(agsec_age_key_file)"
  age-keygen -y "$(agsec_age_key_file)" > "$(agsec_age_pub_file)"
  age-keygen -o "$(agsec_config_dir)/recovery.key" 2>/dev/null
  age-keygen -y "$(agsec_config_dir)/recovery.key" > "$(agsec_config_dir)/recovery.pub"
  rm -f "$(agsec_config_dir)/recovery.key"
  kc_write_selector
  store_init >/dev/null 2>&1
}
