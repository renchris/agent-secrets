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

@test "broader rows append a marker block to each PRESENT tool's shared file (md markers); rollback strips" {
  _load_disc
  # codex + gemini present; zed/cline absent → only codex+gemini get a surface, others not fabricated.
  mkdir -p "$AGENT_SECRETS_HOME/.codex" "$AGENT_SECRETS_HOME/.gemini"
  printf '# my codex rules\n' >"$AGENT_SECRETS_HOME/.codex/AGENTS.md"
  agsec_discovery_install_all >/dev/null
  local ca="$AGENT_SECRETS_HOME/.codex/AGENTS.md" gm="$AGENT_SECRETS_HOME/.gemini/GEMINI.md"
  grep -qF '<!-- >>> agent-secrets >>> -->' "$ca"            # codex: md block appended to the existing file
  grep -qF 'my codex rules' "$ca"                            # user content preserved
  grep -qF '<!-- >>> agent-secrets >>> -->' "$gm"            # gemini: block into a file we created
  [ ! -e "$AGENT_SECRETS_HOME/.config/zed" ]                 # zed absent → dir NOT fabricated
  [ ! -e "$AGENT_SECRETS_HOME/.agents" ]                     # cline absent → dir NOT fabricated
  manifest_rollback >/dev/null 2>&1
  run grep -c agent-secrets "$ca"; [ "$output" -eq 0 ]       # codex block stripped, pre-existing file kept
  grep -qF 'my codex rules' "$ca"
  [ ! -f "$gm" ]                                              # gemini file was tool-created → deleted on uninstall
}

@test "broader row respects the Codex 32 KiB cap (refuse rather than silently truncate)" {
  _load_disc
  mkdir -p "$AGENT_SECRETS_HOME/.codex"
  head -c 32760 /dev/zero | tr '\0' x >"$AGENT_SECRETS_HOME/.codex/AGENTS.md"   # near the 32768 cap
  AGSEC_DISCOVERY_KEYS="codex" agsec_discovery_install_all >/dev/null 2>&1
  run grep -c agent-secrets "$AGENT_SECRETS_HOME/.codex/AGENTS.md"
  [ "$output" -eq 0 ]                                         # skipped — never pushed past the cap
}
