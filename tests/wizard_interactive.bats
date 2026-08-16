#!/usr/bin/env bats
# tests/wizard_interactive.bats — regression locks for the INTERACTIVE wizard paths, from the
# 2026-08-16 failed first-run (docs/plans/ONBOARDING_UX_REBUILD.md). F3 = the [4/7] abort;
# F2 = the unverified recovery-key delete. The screen functions are sourced directly (setup.sh's
# execute-only guard) and driven with canned stdin — deterministic, no PTY. Synthetic-HOME only.
load test_helper

# Source the wizard's screen functions and run ONE of them with canned stdin.
# $1 = printf-format canned input; rest = function + args.
_wiz() {
  local input="$1"; shift
  printf '%b' "$input" | bash -c '. "$REPO_ROOT/cmd/setup.sh"; "$@"' _ "$@"
}

setup_file() { :; }

# ---- F3: [4/7] must never abort the wizard -----------------------------------------------------

@test "F3: empty value at the custom-secret prompt SKIPS after one retry — no abort (the author's crash)" {
  export AGENT_SECRETS_LIB="$REPO_ROOT/lib"
  # menu 3 (custom) → name → empty value → empty again ⇒ skip. Pre-fix: store_add's fail-closed
  # die killed the whole wizard here (set -e), stranding screens 5–7.
  run _wiz '3\nCODA_API_TOKEN\n\n\n' _first_secret
  [ "$status" -eq 0 ]
  [[ "$output" == *"clipboard may be empty"* ]] || return 1     # names the real cause
  [[ "$output" == *"agent-secrets add CODA_API_TOKEN"* ]] || return 1  # hands over the later path
  [[ "$output" != *"ERROR"* ]] || return 1                      # no store_add die reached the user
}

@test "F3: empty once then a real value on the retry stores it (value never surfaced)" {
  setup_store
  run _wiz '3\nCODA_API_TOKEN\n\nval-regression-f3\n' _first_secret
  [ "$status" -eq 0 ]
  [[ "$output" == *"stored CODA_API_TOKEN"* ]] || return 1
  [[ "$output" != *"val-regression-f3"* ]] || return 1
  run bash -c '. "$REPO_ROOT/lib/common.sh"; . "$REPO_ROOT/lib/keychain.sh"; . "$REPO_ROOT/lib/store.sh"; store_has CODA_API_TOKEN'
  [ "$status" -eq 0 ]
}

@test "F3: the menu offers an explicit skip — finishing setup without a first secret is a supported path" {
  export AGENT_SECRETS_LIB="$REPO_ROOT/lib"
  run _wiz '4\n' _first_secret
  [ "$status" -eq 0 ]
  [[ "$output" == *"skip for now"* ]] || return 1
  [[ "$output" == *"Skipped"* ]] || return 1
}

@test "F3: an invalid custom NAME re-prompts instead of reaching store_add's fatal die" {
  setup_store
  run _wiz '3\nBAD-NAME\nGOOD_NAME\nval-regression-name\n' _first_secret
  [ "$status" -eq 0 ]
  [[ "$output" == *"invalid name 'BAD-NAME'"* ]] || return 1
  [[ "$output" == *"stored GOOD_NAME"* ]] || return 1
}

@test "F3: an empty canary-token paste skips the arming — never aborts [4/7]" {
  setup_store
  run _wiz 'y\n\n\n' _arm_canary
  [ "$status" -eq 0 ]
  [[ "$output" == *"skipped"* ]] || return 1
  [[ "$output" != *"ERROR"* ]] || return 1
}
