# shellcheck shell=bash
# lib/discovery.sh — machine-wide, harness-agnostic agent discovery.
#
# A data-driven REGISTRY of the surfaces (files) where coding-agent harnesses read machine-wide
# instructions, plus the install / render / report logic that iterates it. Sourced AFTER common.sh
# (rule renderer + path helpers) and manifest.sh (reversible writes). The rule TEXT has a single
# source — agsec_render_rules (common.sh); this file only decides WHERE it lands per harness and HOW
# it is written (dedicated file vs marker block into a shared file vs manual clipboard).
#
# Discovery is ADVISORY, not enforced: an instruction file makes an agent AWARE of agent-secrets and
# how to call it; it does not guarantee compliance (prose adherence is probabilistic). Per user
# decision 2026-07-14 there is no enforcement hook — the store staying names-only is the real
# invariant; these files are affordance, and doctor labels them "advisory".
#
# Reversibility is automatic: kind=file → manifest_record_file (uninstall deletes it); kind=block →
# manifest_pathblock_install (uninstall strips the marker block, deletes the file if WE created it).

# --- path resolvers ----------------------------------------------------------------------------------
# ALL derive from agsec_home() so tests (AGENT_SECRETS_HOME sandbox) never touch the real machine. A
# harness's OWN relocation var (CLAUDE_CONFIG_DIR / CODEX_HOME) is honored in production but IGNORED
# under the sandbox — an inherited value must not escape AGENT_SECRETS_HOME (this dev shell literally
# has CLAUDE_CONFIG_DIR=~/.claude-secondary set).

# Claude Code's config dir (honors CLAUDE_CONFIG_DIR in production; sandbox-pinned under tests).
_disc_claude_dir() {
  if [ -n "${AGENT_SECRETS_HOME:-}" ]; then printf '%s\n' "$AGENT_SECRETS_HOME/.claude"
  else printf '%s\n' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"; fi
}
# The LITERAL ~/.claude that VS Code Copilot reads — it hardcodes the home path, ignoring CLAUDE_CONFIG_DIR.
_disc_claude_literal_dir() { printf '%s\n' "$(agsec_home)/.claude"; }
_disc_codex_dir() {
  if [ -n "${AGENT_SECRETS_HOME:-}" ]; then printf '%s\n' "$AGENT_SECRETS_HOME/.codex"
  else printf '%s\n' "${CODEX_HOME:-$HOME/.codex}"; fi
}
_disc_gemini_dir() { printf '%s\n' "$(agsec_home)/.gemini"; }
_disc_zed_dir()    { printf '%s\n' "$(agsec_home)/.config/zed"; }
_disc_cline_dir()  { printf '%s\n' "$(agsec_home)/.agents"; }

# Is VS Code present? (covers the Copilot-only machine — ~/.claude may not exist yet but Copilot reads it.)
_disc_vscode_present() {
  [ -d "$(agsec_home)/.vscode" ] || [ -d "$(agsec_home)/.vscode-insiders" ] || agsec_have code || agsec_have code-insiders
}

# --- registry ----------------------------------------------------------------------------------------
# Harness keys in install/report order. "claude" covers Claude Code AND VS Code Copilot (one dedicated
# file); the broader rows append a marker block to each tool's own shared instruction file, and only
# fire when that tool is actually present on this Mac (their gate = config dir exists). Cursor is handled
# out-of-band (clipboard, in setup's done-screen + an MCP server) — it has no writable global file.
# Override the list to scope a run (tests do this per row).
AGSEC_DISCOVERY_KEYS="${AGSEC_DISCOVERY_KEYS:-claude codex gemini zed cline}"

# _disc_row <key> → TAB-separated: kind \t path \t format \t style \t label \t max_bytes
#   kind: file  = a dedicated whole file the tool solely reads (we own it → clean delete on uninstall)
#         block = a marker block appended to a shared, possibly user-populated file
_disc_row() {
  case "$1" in
    # CLAUDE.md (a marker block), NOT ~/.claude/rules/*.md: CLAUDE.md is the version-robust surface BOTH
    # Claude Code and VS Code Copilot read by default (chat.useClaudeMdFile=true on every version);
    # user-home ~/.claude/rules is NOT default-read by Copilot on stable VS Code (verified against source
    # + docs 2026-07-14). W2's md-comment markers keep it from rendering as an H1.
    claude) printf 'block\t%s\tclaude-md\tmd\tClaude Code + VS Code Copilot (~/.claude/CLAUDE.md)\t0\n' "$(_disc_claude_dir)/CLAUDE.md" ;;
    codex)  printf 'block\t%s\tagents-md\tmd\tCodex CLI (~/.codex/AGENTS.md)\t32768\n'            "$(_disc_codex_dir)/AGENTS.md" ;;
    gemini) printf 'block\t%s\tagents-md\tmd\tGemini CLI (~/.gemini/GEMINI.md)\t0\n'              "$(_disc_gemini_dir)/GEMINI.md" ;;
    zed)    printf 'block\t%s\tagents-md\tmd\tZed (~/.config/zed/AGENTS.md)\t0\n'                 "$(_disc_zed_dir)/AGENTS.md" ;;
    cline)  printf 'block\t%s\tagents-md\tmd\tCline (~/.agents/AGENTS.md)\t0\n'                   "$(_disc_cline_dir)/AGENTS.md" ;;
    *) return 1 ;;
  esac
}

# _disc_gate <key> → 0 if the harness is present (its config dir exists). We NEVER fabricate a tool's
# config dir to plant a file for an absent tool. The claude row is the exception: it ALSO serves VS
# Code Copilot, so it fires when ~/.claude exists OR VS Code is present.
_disc_gate() {
  case "$1" in
    claude) [ -d "$(_disc_claude_dir)" ] || [ -d "$(_disc_claude_literal_dir)" ] || _disc_vscode_present ;;
    codex)  [ -d "$(_disc_codex_dir)" ] ;;
    gemini) [ -d "$(_disc_gemini_dir)" ] ;;
    zed)    [ -d "$(_disc_zed_dir)" ] ;;
    cline)  [ -d "$(_disc_cline_dir)" ] ;;
    *) return 1 ;;
  esac
}

# --- render / install / report -----------------------------------------------------------------------

# Field extractor: _disc_field <key> <1..6> (kind path format style label max_bytes).
_disc_field() { _disc_row "$1" | cut -f"$2"; }

# Write ONE surface (kind=file|block) at <path>, rendered against the ABSOLUTE bin. Returns 0 ONLY if a
# write actually happened; returns 1 (a normal SKIP, never fatal) when the target is not writable —
# managed / MDM-locked / read-only. This is the false-green fix: the caller must never claim a surface it
# did not write. Composable across environments: a denied write degrades to a skip everywhere.
_disc_write_one() {
  local kind="$1" path="$2" fmt="$3" style="$4" bin dir
  bin="$(agsec_bin_path)"; dir="$(dirname "$path")"
  mkdir -p "$dir" 2>/dev/null || true
  if [ -e "$path" ]; then [ -w "$path" ] || return 1; else [ -w "$dir" ] || return 1; fi
  case "$kind" in
    file)  agsec_render_rules "$fmt" "$bin" >"$path" 2>/dev/null || return 1
           manifest_record_file "$path" >/dev/null 2>&1 || true ;;
    block) manifest_pathblock_install "$path" "$AGENT_SECRETS_DISCOVERY_MARKER" "$(agsec_render_rules "$fmt" "$bin")" "$style" ;;
    *) return 1 ;;
  esac
}

# Write discovery for ONE present harness (idempotent, reversible). Prints the label ONLY if at least one
# target was actually written; prints nothing when gated-out or every target was unwritable. Callers own
# the consent prompt (never silent-write a global agent-instruction file).
agsec_discovery_write_key() {
  local key="$1" kind path fmt style label max targets t wrote=0
  _disc_gate "$key" || return 0
  kind="$(_disc_field "$key" 1)"; path="$(_disc_field "$key" 2)"; fmt="$(_disc_field "$key" 3)"
  style="$(_disc_field "$key" 4)"; label="$(_disc_field "$key" 5)"; max="$(_disc_field "$key" 6)"
  # Per-READER coverage: Claude Code honors CLAUDE_CONFIG_DIR while VS Code Copilot reads the LITERAL
  # ~/.claude/CLAUDE.md — when a relocated config makes them diverge, target BOTH so neither reader is
  # dropped. Common case (var unset / tests): they coincide → a single target.
  targets="$path"
  if [ "$key" = claude ]; then
    local lit; lit="$(_disc_claude_literal_dir)/CLAUDE.md"
    [ "$lit" != "$path" ] && targets="$(printf '%s\n%s' "$path" "$lit")"
  fi
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    # Per-surface byte cap (e.g. Codex AGENTS.md 32 KiB) — refuse rather than truncate a near-cap file.
    if [ "$kind" = block ] && [ "${max:-0}" -gt 0 ] && [ -f "$t" ]; then
      local cur add; cur="$(wc -c <"$t" 2>/dev/null || printf 0)"; add="$(agsec_render_rules "$fmt" "$(agsec_bin_path)" | wc -c)"
      if [ "$((cur + add + 8))" -gt "$max" ]; then agsec_warn "discovery: $t near its ${max}-byte cap — skipped" 2>/dev/null || true; continue; fi
    fi
    _disc_write_one "$kind" "$t" "$fmt" "$style" && wrote=1
  done <<EOF
$targets
EOF
  [ "$wrote" = 1 ] && printf '%s\n' "$label"
  return 0
}

# Install discovery across every PRESENT harness in the registry. Returns 0 always; prints one label
# line per surface written (for the caller to echo). Consent is the caller's responsibility.
agsec_discovery_install_all() {
  local key
  for key in $AGSEC_DISCOVERY_KEYS; do
    agsec_discovery_write_key "$key" || true
  done
}

# Report coverage for one key → TAB: key \t status \t path \t label
#   status: in-sync | stale | tampered | absent | not-applicable
# Integrity is judged by the block's OWN embedded version+sha marker (agsec_block_integrity), NOT by a
# content-compare to the current render — so a dotfile-synced block carrying another machine's abs-path
# is NOT falsely flagged (its self-hash still verifies). tampered = embedded sha mismatch OR a
# hidden-Unicode payload; stale = integrity ok but an OLDER tool version; unmarked (legacy/hand-authored)
# falls back to a content-compare.
agsec_discovery_status_key() {
  local key="$1" kind path fmt label block integ ver
  kind="$(_disc_field "$key" 1)"; path="$(_disc_field "$key" 2)"
  fmt="$(_disc_field "$key" 3)"; label="$(_disc_field "$key" 5)"
  if ! _disc_gate "$key"; then printf '%s\tnot-applicable\t%s\t%s\n' "$key" "$path" "$label"; return 0; fi
  if [ "$kind" = file ]; then
    [ -f "$path" ] && block="$(cat "$path" 2>/dev/null)" || block=""
  else
    block="$(_disc_extract_block "$path")"
  fi
  [ -n "$block" ] || { printf '%s\tabsent\t%s\t%s\n' "$key" "$path" "$label"; return 0; }
  # A hidden-Unicode / bidi payload makes the block read one way to a human, another to the agent.
  if _disc_has_hidden_unicode "$block"; then printf '%s\ttampered\t%s\t%s\n' "$key" "$path" "$label"; return 0; fi
  integ="$(agsec_block_integrity "$block")"
  case "$integ" in
    tampered) printf '%s\ttampered\t%s\t%s\n' "$key" "$path" "$label" ;;
    ok\ *)
      ver="${integ#ok }"
      if [ "$ver" = "$(agsec_version)" ]; then printf '%s\tin-sync\t%s\t%s\n' "$key" "$path" "$label"
      else printf '%s\tstale\t%s\t%s\n' "$key" "$path" "$label"; fi ;;
    *)  # unmarked (legacy / hand-authored): best-effort content-compare to the current render
      if [ "$block" = "$(agsec_render_rules "$fmt")" ]; then printf '%s\tin-sync\t%s\t%s\n' "$key" "$path" "$label"
      else printf '%s\tstale\t%s\t%s\n' "$key" "$path" "$label"; fi ;;
  esac
}

# Detect bidi-override / zero-width / BOM characters in a loaded instruction block — the Rules-File-
# Backdoor / ATLAS AML-CS0041 class where hidden Unicode makes a block say one thing to a human reviewer
# and another to the agent. Byte-level (LC_ALL=C) match on the UTF-8 encodings of U+202A-202E,
# U+2066-2069, U+200B-200F, U+FEFF. Returns 0 if any is present. (Em-dash U+2014 / middot U+00B7 used in
# our own render do NOT match these ranges.)
_disc_has_hidden_unicode() {
  printf '%s' "$1" | LC_ALL=C grep -qE $'\xe2\x80[\xaa-\xae]|\xe2\x81[\xa6-\xa9]|\xe2\x80[\x8b-\x8f]|\xef\xbb\xbf'
}

# Extract the body BETWEEN our markers (either style) from a shared file; empty if no block.
_disc_extract_block() {
  local file="$1" bsh esh bmd emd
  [ -f "$file" ] || return 0
  bsh="$(_manifest_block_begin "$AGENT_SECRETS_DISCOVERY_MARKER" sh)"; esh="$(_manifest_block_end "$AGENT_SECRETS_DISCOVERY_MARKER" sh)"
  bmd="$(_manifest_block_begin "$AGENT_SECRETS_DISCOVERY_MARKER" md)"; emd="$(_manifest_block_end "$AGENT_SECRETS_DISCOVERY_MARKER" md)"
  awk -v bsh="$bsh" -v esh="$esh" -v bmd="$bmd" -v emd="$emd" '
    { line=$0; sub(/\r$/,"",line) }
    (line==bsh || line==bmd) { inb=1; next }
    inb && (line==esh || line==emd) { inb=0; next }
    inb { print }
  ' "$file"
}
