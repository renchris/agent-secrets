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

@test "claude discovery writes a marker block to ~/.claude/CLAUDE.md (Claude Code + Copilot); rollback strips it, user content kept" {
  _load_disc
  local cm="$AGENT_SECRETS_HOME/.claude/CLAUDE.md"
  mkdir -p "$AGENT_SECRETS_HOME/.claude"
  printf '# My global rules\nBe concise.\n' >"$cm"             # pre-existing user content
  run agsec_discovery_write_key claude
  [ "$status" -eq 0 ]
  grep -qF '<!-- >>> agent-secrets >>> -->' "$cm"              # md-comment markers (CLAUDE.md is the both-reader surface)
  grep -qF 'run -- <cmd>' "$cm"                                # golden rules landed
  grep -qF 'Be concise.' "$cm"                                 # user content preserved
  run grep -c '^# >>> agent-secrets' "$cm"; [ "$output" -eq 0 ]   # NO shell-comment H1 marker
  manifest_rollback >/dev/null 2>&1
  run grep -c 'agent-secrets' "$cm"; [ "$output" -eq 0 ]      # block stripped
  grep -qF 'Be concise.' "$cm"                                 # user content still there (pre-existing file not deleted)
}

@test "claude block is abs-path pinned + self-guarded + integrity-marked (drift-proof, PATH-hijack-safe, synced-inert)" {
  _load_disc
  mkdir -p "$AGENT_SECRETS_HOME/.claude"
  local cm="$AGENT_SECRETS_HOME/.claude/CLAUDE.md"
  AGENT_SECRETS_BIN=/opt/x/bin/agent-secrets agsec_discovery_write_key claude >/dev/null
  grep -qF '/opt/x/bin/agent-secrets run -- <cmd>' "$cm"                       # abs-path pinned (anti PATH-hijack)
  grep -qF 'Ignore this entire section unless the file' "$cm"                  # self-guard → inert if synced to a tool-less machine
  grep -qE '<!-- agent-secrets:version=.* sha256=[0-9a-f]{64} -->' "$cm"       # version+integrity marker
  local blk; blk="$(_disc_extract_block "$cm")"
  [[ "$(agsec_block_integrity "$blk")" == ok\ * ]]                             # integrity verifies (untampered)
  # a hand-edit flips integrity to 'tampered'
  local edited; edited="$(printf '%s\n' "$blk" | sed 's/NEVER write/ALWAYS write/')"
  [ "$(agsec_block_integrity "$edited")" = tampered ]
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
