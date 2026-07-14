#!/usr/bin/env bats
# tests/discovery.bats — machine-wide, harness-agnostic agent discovery (lib/discovery.sh). The opt-in
# dedicated rules file that teaches agents in EVERY repo to route secrets through agent-secrets, driven
# by the surface registry. Install (registry) → doctor reports (advisory) → uninstall (rollback) removes.
# All under a synthetic HOME (AGENT_SECRETS_HOME); nothing touches the real machine.
load test_helper

_load_disc() {
  export AGENT_SECRETS_LIB="$REPO_ROOT/lib"
  # shellcheck source=/dev/null
  . "$REPO_ROOT/lib/common.sh"; . "$REPO_ROOT/lib/manifest.sh"; . "$REPO_ROOT/lib/discovery.sh"
  manifest_init
}

@test "the discovery marker has a SINGLE source (common.sh constant), not a hardcoded install.sh literal" {
  local b
  b="$(sed -n 's/.*AGENT_SECRETS_DISCOVERY_MARKER="\([^"]*\)".*/\1/p' "$REPO_ROOT/lib/common.sh" | head -1)"
  [ -n "$b" ]                                       # the constant IS defined in common.sh (the single source)
  # install.sh must NOT define its own DISCOVERY_MARKER literal — the registry (lib/discovery.sh) uses the
  # common.sh constant, so a hardcoded copy is exactly the drift this refactor eliminated by construction.
  run grep -cE 'DISCOVERY_MARKER=' "$REPO_ROOT/install.sh"
  [ "$output" -eq 0 ]
}

@test "claude discovery writes the dedicated ~/.claude/rules file (Claude Code + Copilot); rollback deletes it" {
  _load_disc
  mkdir -p "$AGENT_SECRETS_HOME/.claude"                       # Claude Code present → gate passes
  local rf="$AGENT_SECRETS_HOME/.claude/rules/agent-secrets.md"
  run agsec_discovery_write_key claude
  [ "$status" -eq 0 ]
  [ -f "$rf" ]                                                 # dedicated rules file written (not a CLAUDE.md block)
  grep -qF "agent-secrets run -- <cmd>" "$rf"                 # the golden rules landed
  grep -qF "Secrets: use" "$rf"                                # markdown section header present
  manifest_rollback >/dev/null 2>&1
  [ ! -f "$rf" ]                                               # uninstall DELETES the dedicated file (no shared-file surgery)
}

@test "claude discovery content matches the single renderer (no drift between file and source)" {
  _load_disc
  mkdir -p "$AGENT_SECRETS_HOME/.claude"
  agsec_discovery_write_key claude >/dev/null
  local rf="$AGENT_SECRETS_HOME/.claude/rules/agent-secrets.md"
  diff <(agsec_render_rules claude-md) "$rf"                   # file == render, byte for byte
}

@test "discovery does NOT fabricate a config dir for an absent tool (codex gate)" {
  _load_disc
  # No ~/.codex on this synthetic machine → the codex row must not create it or write anything.
  AGSEC_DISCOVERY_KEYS="codex" run agsec_discovery_install_all
  [ ! -e "$AGENT_SECRETS_HOME/.codex" ]
}

@test "doctor reports the claude surface: absent before install, present+advisory after" {
  _load_disc
  mkdir -p "$AGENT_SECRETS_HOME/.claude"
  run agsec doctor
  [[ "$output" == *"agent rules"* ]] || return 1
  [[ "$output" == *"not installed (opt-in"* ]] || return 1     # absent before any write
  agsec_discovery_write_key claude >/dev/null
  run agsec doctor
  [[ "$output" == *"agent rules"* ]] || return 1
  [[ "$output" == *"advisory"* ]] || return 1                  # present, labeled advisory (not enforced)
}

@test "doctor still surfaces the flagship claude reminder even with no ~/.claude dir" {
  _load_disc
  run agsec doctor
  [[ "$output" == *"agent rules"* ]] || return 1
  [[ "$output" == *"not installed (opt-in"* ]] || return 1     # opt-in reminder shows regardless
}
