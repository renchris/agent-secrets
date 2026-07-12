#!/usr/bin/env bash
# cmd/doctor.sh — categorized names-only health checks.
# Categories: custody · store · injection ·
# hygiene · maintenance · supply-chain (+ --gates c/d/e). Every check catches
# its own failure so doctor NEVER crashes when nothing is set up — it reports ✗/⚠ instead.
# Names-only: no check ever writes a secret VALUE (checked via exit code / non-empty only).
set -euo pipefail
. "${AGENT_SECRETS_LIB:?AGENT_SECRETS_LIB unset — run via bin/agent-secrets}/common.sh"
case "${1:-}" in -h|--help) . "$AGENT_SECRETS_LIB/help.sh"; agsec_help_render doctor; exit 0 ;; esac
. "$AGENT_SECRETS_LIB/store.sh"       # every call below is guarded against an unset/absent store
. "$AGENT_SECRETS_LIB/keychain.sh"    # guarded against an unset/absent store

FORMAT=text ; REDACT=0 ; FIX=0 ; GATES=0
for arg in "$@"; do
  case "$arg" in
    --format=json) FORMAT=json ;;
    --format=text) FORMAT=text ;;
    --redact)      REDACT=1 ;;
    --fix)         FIX=1 ;;
    --gates)       GATES=1 ;;
    -h|--help) printf '%s\n' "usage: agent-secrets doctor [--format=json] [--redact] [--gates] [--fix]"; exit 0 ;;
    *) agsec_die "doctor: unknown flag: $arg (see --help)" 2 ;;
  esac
done

# Must match install.sh's SMOKE_LABEL exactly, else the maintenance check can never pass.
LAUNCHD_LABEL="${AGENT_SECRETS_LAUNCHD_LABEL:-com.agent-secrets.smoke}"
had_bad=0
JSON_ROWS=()

_js() { local s=${1//\\/\\\\}; printf '%s' "${s//\"/\\\"}"; }  # minimal JSON string escape

# Emit one check result.  Args: category status(ok|attn|bad) name [detail]  — names-only.
_row() {
  local cat=$1 st=$2 name=$3 detail=${4:-}
  if [ "$st" = bad ]; then had_bad=1; fi
  if [ "$FORMAT" = json ]; then
    JSON_ROWS+=("$(printf '{"category":"%s","status":"%s","check":"%s","detail":"%s"}' \
      "$cat" "$st" "$(_js "$name")" "$(_js "$detail")")")
    return 0
  fi
  case "$st" in
    ok)   agsec_ok   "[$cat] $name${detail:+ — $detail}" ;;
    attn) agsec_attn "[$cat] $name${detail:+ — $detail}" ;;
    bad)  agsec_bad  "[$cat] $name${detail:+ — $detail}" ;;
  esac
}

# Guarded value capture — contains a die-stub/absent-lib `exit` inside a subshell so doctor
# never crashes.  Args: VAR CMD...   sets VAR to stdout, returns CMD's exit code.
_try() {
  local __v=$1; shift; local __o
  if __o=$("$@" 2>/dev/null); then printf -v "$__v" '%s' "$__o"; return 0
  else local __r=$?; printf -v "$__v" '%s' "$__o"; return "$__r"; fi
}
# Guarded exit-code-only check (value discarded — never captured, never printed).
_guard() { ( "$@" ) >/dev/null 2>&1; }

check_custody() {
  local st
  if _try st kc_status; then
    case "$st" in
      primary)   _row custody ok   "keychain custody" "primary" ;;
      degraded*) _row custody attn "keychain custody" "degraded (file custody)" ;;
      missing)   _row custody bad  "keychain custody" "missing" ;;
      *)         _row custody attn "keychain custody" "unknown state" ;;
    esac
  else
    _row custody bad "keychain custody" "unavailable (not set up)"
  fi
}

_scan_rotate() {  # manifest.toml rotate_by scan — names + days only, never values
  local mf; mf=$(agsec_manifest_toml)
  if [ ! -f "$mf" ]; then _row store attn "rotation scan" "no manifest"; return 0; fi
  local today line name rb due days dname flagged=0
  today=$(date +%s); name=""
  while IFS= read -r line; do
    case "$line" in
      *name*=*) name=$(printf '%s' "$line" | sed -E 's/.*=[[:space:]]*"?([^"]*)"?[[:space:]]*$/\1/') ;;
      *rotate_by*=*)
        rb=$(printf '%s' "$line" | sed -E 's/.*=[[:space:]]*"?([0-9-]+)"?.*/\1/')
        due=$(date -j -f %Y-%m-%d "$rb" +%s 2>/dev/null) || continue
        days=$(( (due - today) / 86400 ))
        if [ "$days" -le 14 ]; then
          dname=$name; if [ "$REDACT" = 1 ]; then dname=$(printf '%s' "$name" | agsec_digest); fi
          _row store attn "rotation due" "$dname in ${days}d"; flagged=1
        fi ;;
    esac
  done < "$mf"
  if [ "$flagged" = 0 ]; then _row store ok "rotation scan" "none due ≤14d"; fi
}

check_store() {
  local sf v; sf=$(agsec_store_file)
  if [ -f "$sf" ]; then _row store ok "store file" "present"; else _row store bad "store file" "absent"; fi
  if _try v store_extract "$AGENT_SECRETS_CANARY_NAME" && [ -n "$v" ]; then
    _row store ok "decrypt self-test" "canary readable"
  else
    _row store bad "decrypt self-test" "canary unreadable"
  fi
  v=""
  _scan_rotate
}

check_injection() {
  local bd w akh out; bd=$(agsec_bin_dir)
  for w in claude-agent cursor-agent; do
    if [ -x "$bd/$w" ]; then _row injection ok "wrapper" "$w executable"
    elif [ -e "$bd/$w" ]; then _row injection attn "wrapper" "$w not executable"
    else _row injection bad "wrapper" "$w missing"; fi
  done
  akh="$bd/apiKeyHelper"
  if [ -x "$akh" ]; then
    if _try out "$akh" && [ -n "$out" ]; then _row injection ok "apiKeyHelper" "returns credential"
    else _row injection bad "apiKeyHelper" "empty output"; fi
    out=""
  else
    _row injection bad "apiKeyHelper" "missing"
  fi
}

check_hygiene() {
  local pd mode sj cpd; pd="$(agsec_home)/.claude/projects"
  if [ -d "$pd" ]; then
    mode=$(stat -f '%OLp' "$pd" 2>/dev/null || echo '???')
    if [ "$mode" = 700 ]; then _row hygiene ok "projects dir mode" "700"
    else
      _row hygiene attn "projects dir mode" "$mode (want 700)"
      if [ "$FIX" = 1 ] && chmod 700 "$pd" 2>/dev/null; then _row hygiene ok "projects dir mode" "fixed → 700"; fi
    fi
  else _row hygiene attn "projects dir" "absent"; fi
  sj="$(agsec_home)/.claude/settings.json"
  if [ -f "$sj" ] && agsec_have jq; then
    cpd=$(jq -r '.cleanupPeriodDays // empty' "$sj" 2>/dev/null || echo '')
    if [ -n "$cpd" ] && [ "$cpd" -le 14 ] 2>/dev/null; then _row hygiene ok "cleanupPeriodDays" "$cpd"
    elif [ -n "$cpd" ]; then _row hygiene attn "cleanupPeriodDays" "$cpd (want ≤14)"
    else _row hygiene attn "cleanupPeriodDays" "unset (want ≤14)"; fi
  else _row hygiene attn "cleanupPeriodDays" "settings.json/jq unavailable"; fi
}

check_maintenance() {
  if _guard launchctl list "$LAUNCHD_LABEL"; then _row maintenance ok "weekly smoke job" "loaded"
  else _row maintenance attn "weekly smoke job" "not loaded ($LAUNCHD_LABEL)"; fi
}

check_supply() {
  local val
  if agsec_have npm && _try val npm config get ignore-scripts && [ "$val" = true ]; then
    _row supply-chain ok "npm ignore-scripts" "true"
  else
    _row supply-chain attn "npm ignore-scripts" "not set (want true)"
    if [ "$FIX" = 1 ] && agsec_have npm && npm config set ignore-scripts true >/dev/null 2>&1; then
      _row supply-chain ok "npm ignore-scripts" "fixed → true"
    fi
  fi
}

check_gates() {  # execution gates (c)/(d)/(e) — (c) degradation is a note, never a block/error
  local st
  if _try st kc_status && [ "$st" = primary ]; then _row gate ok "(c) keychain read" "primary"
  else _row gate attn "(c) keychain read" "degraded (file custody)"; fi
  if _guard store_exec -- true; then _row gate ok "(d) sops exec-env" "works"
  else _row gate attn "(d) sops exec-env" "unavailable (fallback: apiKeyHelper-only)"; fi
  if [ -d "/Applications/LuLu.app" ]; then _row gate ok "(e) egress profile" "LuLu present (ruleset unverified)"
  elif ls -d "/Applications/Little Snitch"*.app >/dev/null 2>&1; then _row gate ok "(e) egress profile" "Little Snitch present (ruleset unverified)"
  else _row gate attn "(e) egress profile" "no LuLu/Little Snitch app found"; fi
}

run_checks() {
  check_custody
  check_store
  check_injection
  check_hygiene
  check_maintenance
  check_supply
  if [ "$GATES" = 1 ]; then check_gates; fi
}

run_checks
if [ "$FORMAT" = json ]; then
  printf '{"checks":['
  i=0
  for row in "${JSON_ROWS[@]}"; do
    if [ "$i" -gt 0 ]; then printf ','; fi
    printf '%s' "$row"; i=$((i + 1))
  done
  printf '],"exit":%d}\n' "$had_bad"
fi
exit "$had_bad"
