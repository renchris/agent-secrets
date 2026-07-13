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

@test "non-interactive uninstall (stdin EOF) completes the rollback instead of aborting under set -e" {
  setup_store
  # stdin closed — an agent / cron / nohup context. Pre-fix: the bare `read` hit EOF, set -e aborted
  # the script BEFORE manifest_rollback, exit 1, TOTAL residue. Post-fix: fail-closed to KEEP + rollback.
  run bash "$REPO_ROOT/cmd/uninstall.sh" </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"uninstall complete"* ]]                   # rollback ran to completion
  [ -f "$AGENT_SECRETS_HOME/.config/secrets/secrets.env" ]    # KEEP default → the user's store survives
}

@test "uninstall keep-mode purges the colleague-share roster from the retained manifest (decision #6)" {
  setup_store
  printf 'x' | store_add MY_SHARED
  store_manifest_set_sharing MY_SHARED shared_with='sha256:deadbeef1234' shared_at='2026-07-11' direction='sent'
  run grep -c '^shared_with = ' "$(agsec_manifest_toml)"; [ "$output" -eq 1 ]   # present pre-uninstall
  printf 'N\n' | bash "$REPO_ROOT/cmd/uninstall.sh" >/dev/null 2>&1               # keep-mode (N = do not purge store)
  [ -f "$(agsec_manifest_toml)" ]                                                # manifest kept
  run grep -c '^shared_with = ' "$(agsec_manifest_toml)"; [ "$output" -eq 0 ]   # social graph purged
  run grep -c '^direction = ' "$(agsec_manifest_toml)"; [ "$output" -eq 0 ]
  run grep -c 'name = "MY_SHARED"' "$(agsec_manifest_toml)"; [ "$output" -eq 1 ] # credential row survives
}

@test "rollback DELETES a tool-created settings.json (no empty {} residue)" {
  export AGENT_SECRETS_LIB="$REPO_ROOT/lib"
  # shellcheck source=/dev/null
  . "$REPO_ROOT/lib/common.sh"; . "$REPO_ROOT/lib/manifest.sh"; manifest_init
  local sj="$AGENT_SECRETS_HOME/settings.json" bak="$AGENT_SECRETS_HOME/nobak"
  printf '{"apiKeyHelper":"x"}\n' >"$sj"          # the tool created + edited it (no pre-existing backup)
  manifest_record_edit "$sj" "$bak" apiKeyHelper created
  manifest_rollback >/dev/null
  [ ! -f "$sj" ]                                   # removed, not restored to {}
}

@test "rollback RESTORES a pre-existing settings.json to its pristine backup" {
  export AGENT_SECRETS_LIB="$REPO_ROOT/lib"
  # shellcheck source=/dev/null
  . "$REPO_ROOT/lib/common.sh"; . "$REPO_ROOT/lib/manifest.sh"; manifest_init
  local sj="$AGENT_SECRETS_HOME/settings.json" bak="$AGENT_SECRETS_HOME/pristine.bak"
  printf '{"user":"kept"}\n' >"$sj"; cp "$sj" "$bak"          # pristine backup captured pre-edit
  printf '{"user":"kept","apiKeyHelper":"x"}\n' >"$sj"        # tool's edit
  manifest_record_edit "$sj" "$bak" apiKeyHelper              # no created flag → restore
  manifest_rollback >/dev/null
  run cat "$sj"; [[ "$output" == *'"user":"kept"'* ]]; [[ "$output" != *"apiKeyHelper"* ]]
}

@test "rollback removes a tool-CREATED rc file left empty after stripping the PATH block" {
  export AGENT_SECRETS_LIB="$REPO_ROOT/lib"
  # shellcheck source=/dev/null
  . "$REPO_ROOT/lib/common.sh"; . "$REPO_ROOT/lib/manifest.sh"; manifest_init
  local rc="$AGENT_SECRETS_HOME/.zshenv-created"
  [ ! -f "$rc" ]                                              # absent → install must note created=1
  manifest_pathblock_install "$rc" "agent-secrets" 'export PATH="$HOME/bin:$PATH"'
  [ -f "$rc" ]
  manifest_rollback >/dev/null
  [ ! -f "$rc" ]                                              # orphan removed (only our block was in it)
}

@test "rollback keeps a PRE-EXISTING rc file, stripping only our block" {
  export AGENT_SECRETS_LIB="$REPO_ROOT/lib"
  # shellcheck source=/dev/null
  . "$REPO_ROOT/lib/common.sh"; . "$REPO_ROOT/lib/manifest.sh"; manifest_init
  local rc="$AGENT_SECRETS_HOME/.zshenv-existing"
  printf 'export EDITOR=vim\n' >"$rc"                         # user content pre-exists → created=0
  manifest_pathblock_install "$rc" "agent-secrets" 'export PATH="$HOME/bin:$PATH"'
  manifest_rollback >/dev/null
  [ -f "$rc" ]                                                # kept
  run grep -c 'EDITOR=vim' "$rc"; [ "$output" -eq 1 ]        # user line preserved
  run grep -c 'HOME/bin' "$rc"; [ "$output" -eq 0 ]          # our block stripped
}

@test "rollback SURGICALLY removes only .apiKeyHelper, preserving keys the user added AFTER install" {
  export AGENT_SECRETS_LIB="$REPO_ROOT/lib"
  # shellcheck source=/dev/null
  . "$REPO_ROOT/lib/common.sh"; . "$REPO_ROOT/lib/manifest.sh"; manifest_init
  local sj="$AGENT_SECRETS_HOME/settings.json" bak="$AGENT_SECRETS_HOME/day0.bak"
  printf '{"model":"opus"}\n' >"$sj"; cp "$sj" "$bak"                 # install-day backup
  printf '{"model":"opus","apiKeyHelper":"x","hooks":{"Stop":"y"}}\n' >"$sj"   # tool edit + user's LATER hooks
  manifest_record_edit "$sj" "$bak" apiKeyHelper                      # pre-existing → surgical del by marker
  manifest_rollback >/dev/null
  run cat "$sj"
  [[ "$output" == *'"model":"opus"'* ]]                              # preserved
  [[ "$output" == *'"hooks"'* ]]                                     # user's POST-install addition preserved (not snapshot-reverted)
  [[ "$output" != *"apiKeyHelper"* ]]                                # only the tool's key removed
}

@test "rollback RESTORES a user's PRE-EXISTING apiKeyHelper value, not deletes it" {
  export AGENT_SECRETS_LIB="$REPO_ROOT/lib"
  # shellcheck source=/dev/null
  . "$REPO_ROOT/lib/common.sh"; . "$REPO_ROOT/lib/manifest.sh"; manifest_init
  local sj="$AGENT_SECRETS_HOME/settings.json" bak="$AGENT_SECRETS_HOME/day0.bak"
  printf '{"model":"opus","apiKeyHelper":"/Users/me/orig.sh"}\n' >"$sj"   # user HAD their OWN apiKeyHelper
  cp "$sj" "$bak"                                                          # install-day backup captures it
  printf '{"model":"opus","apiKeyHelper":"/tool/apiKeyHelper"}\n' >"$sj"   # tool overwrote it
  manifest_record_edit "$sj" "$bak" apiKeyHelper                          # pre-existing → RESTORE, not delete
  manifest_rollback >/dev/null
  run cat "$sj"
  [[ "$output" == *'/Users/me/orig.sh'* ]]                               # user's ORIGINAL value restored
  [[ "$output" != *'/tool/apiKeyHelper'* ]]                              # tool's value gone
  [[ "$output" == *'opus'* ]]                                            # other keys preserved (jq pretty-prints)
}

@test "rollback strip KEEPS everything when the end marker is corrupted (no delete-to-EOF)" {
  export AGENT_SECRETS_LIB="$REPO_ROOT/lib"
  # shellcheck source=/dev/null
  . "$REPO_ROOT/lib/common.sh"; . "$REPO_ROOT/lib/manifest.sh"; manifest_init
  local cm="$AGENT_SECRETS_HOME/CLAUDE.md"
  printf '# top user rules\n' >"$cm"
  manifest_pathblock_install "$cm" "agent-secrets" 'agent-secrets discovery block'
  printf '# BELOW the block — important user content\n' >>"$cm"
  sed -i.bak 's/^# <<< agent-secrets <<<$/# CORRUPTED-END/' "$cm"; rm -f "$cm.bak"   # user breaks the end marker
  manifest_rollback >/dev/null
  grep -q '# BELOW the block' "$cm"                                  # content below the block SURVIVES
  grep -q '# top user rules' "$cm"                                   # content above survives
}
