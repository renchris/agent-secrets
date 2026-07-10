#!/usr/bin/env bats
# tests/uninstall.bats — install-manifest round-trip + total-rollback zero-residue.
load test_helper

@test "manifest round-trip: record -> list -> dry-run touches nothing -> rollback removes" {
  export AGENT_SECRETS_LIB="$REPO_ROOT/lib"
  # shellcheck source=/dev/null
  . "$REPO_ROOT/lib/common.sh"; . "$REPO_ROOT/lib/manifest.sh"
  manifest_init
  local f="$AGENT_SECRETS_HOME/fake-artifact"; echo hi >"$f"
  manifest_record_file "$f"
  run manifest_list file
  [[ "$output" == *"fake-artifact"* ]]
  # dry-run must not delete the file
  manifest_rollback --dry-run >/dev/null
  [ -f "$f" ]
  # real rollback removes it and empties the manifest
  manifest_rollback >/dev/null
  [ ! -f "$f" ]
  run cat "$(agsec_install_manifest)"
  [ "$output" = "[]" ]
}

@test "pathblock install then rollback strips only the block, preserving surrounding lines" {
  export AGENT_SECRETS_LIB="$REPO_ROOT/lib"
  # shellcheck source=/dev/null
  . "$REPO_ROOT/lib/common.sh"; . "$REPO_ROOT/lib/manifest.sh"
  manifest_init
  local rc="$AGENT_SECRETS_HOME/.zshrc"
  printf 'export EDITOR=vim\n' >"$rc"
  manifest_pathblock_install "$rc" "agent-secrets" 'export PATH="$HOME/bin:$PATH"'
  run grep -c 'HOME/bin' "$rc"; [ "$output" -ge 1 ]
  manifest_rollback >/dev/null
  run grep -c 'HOME/bin' "$rc"; [ "$output" -eq 0 ]
  run grep -c 'EDITOR=vim' "$rc"; [ "$output" -eq 1 ]   # surrounding line preserved
}

@test "uninstall --dry-run mutates nothing" {
  setup_store
  export AGENT_SECRETS_LIB="$REPO_ROOT/lib"
  . "$REPO_ROOT/lib/common.sh"
  # keep-vs-purge default is KEEP; dry-run should leave the store in place
  run bash "$REPO_ROOT/cmd/uninstall.sh" --dry-run
  [ "$status" -eq 0 ]
  [ -f "$AGENT_SECRETS_HOME/.config/secrets/secrets.env" ]
}
