#!/usr/bin/env bats
# tests/discovery.bats — machine-wide agent discovery: the opt-in ~/.claude/CLAUDE.md block that
# teaches agents in EVERY repo to route secrets through agent-secrets. Install (manifest pathblock) →
# doctor detects → uninstall (rollback) strips, all under synthetic HOME.
load test_helper

@test "install.sh discovery marker == lib/common.sh AGENT_SECRETS_DISCOVERY_MARKER (no drift)" {
  local a b
  a="$(sed -n 's/.*DISCOVERY_MARKER="\([^"]*\)".*/\1/p' "$REPO_ROOT/install.sh" | head -1)"
  b="$(sed -n 's/.*AGENT_SECRETS_DISCOVERY_MARKER="\([^"]*\)".*/\1/p' "$REPO_ROOT/lib/common.sh" | head -1)"
  [ -n "$a" ]
  [ "$a" = "$b" ]   # doctor greps + uninstall strips by the constant; install writes by its literal — they MUST agree
}

@test "discovery block installs into ~/.claude/CLAUDE.md, doctor detects it, rollback strips it (user content preserved)" {
  export AGENT_SECRETS_LIB="$REPO_ROOT/lib"
  # shellcheck source=/dev/null
  . "$REPO_ROOT/lib/common.sh"; . "$REPO_ROOT/lib/manifest.sh"
  manifest_init
  local cm="$AGENT_SECRETS_HOME/.claude/CLAUDE.md"
  mkdir -p "$(dirname "$cm")"
  printf '# My global rules\nBe concise.\n' >"$cm"

  manifest_pathblock_install "$cm" "$AGENT_SECRETS_DISCOVERY_MARKER" \
    "$(printf '## Secrets: use agent-secrets\n- never plaintext\n')"

  grep -qF "# >>> agent-secrets >>>" "$cm"      # block wrapped in the marker
  grep -qF "use agent-secrets" "$cm"            # block body present
  grep -qF "Be concise." "$cm"                  # pre-existing user content preserved

  run agsec doctor
  [[ "$output" == *"global agent rules"* ]]
  [[ "$output" == *"present in ~/.claude/CLAUDE.md"* ]]

  manifest_rollback >/dev/null
  run grep -c "agent-secrets" "$cm"; [ "$output" -eq 0 ]   # block fully stripped
  grep -qF "Be concise." "$cm"                              # user content untouched by the strip
}

@test "doctor reports the discovery block absent when ~/.claude/CLAUDE.md carries none" {
  run agsec doctor
  [[ "$output" == *"global agent rules"* ]]
  [[ "$output" == *"not installed (opt-in"* ]]
}
