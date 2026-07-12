#!/usr/bin/env bash
# cmd/smoke.sh — weekly maintenance smoke. Run by the launchd job via `agent-secrets smoke`
# (a HIDDEN dispatcher verb — routed, but deliberately kept out of help and help --json).
# Six checks: (1) Keychain read, (2) sops decrypt self-test, (3) apiKeyHelper non-empty,
# (4) wrappers executable, (5) manifest.toml rotate_by scan → local notification, (6) npm
# ignore-scripts still set. Any failure → notification. Names-only: never prints a value; every
# lib call is guarded in a subshell so an unset/absent store reports a failure, never crashes.
# Exit 0 if all pass, else 1.
set -euo pipefail
. "${AGENT_SECRETS_LIB:?AGENT_SECRETS_LIB unset — run via the launchd job or bin/agent-secrets}/common.sh"
. "$AGENT_SECRETS_LIB/store.sh"
. "$AGENT_SECRETS_LIB/keychain.sh"

fail=0

notify() {  # title message — names-only; no values ever transit here
  osascript -e "display notification \"$2\" with title \"$1\"" >/dev/null 2>&1 || true
  agsec_warn "$1: $2"
}
# Guarded value capture (contains a die-stub/absent-lib exit; value never printed).
_try() {
  local __v=$1; shift; local __o
  if __o=$("$@" 2>/dev/null); then printf -v "$__v" '%s' "$__o"; return 0
  else local __r=$?; printf -v "$__v" '%s' "$__o"; return "$__r"; fi
}
_guard() { ( "$@" ) >/dev/null 2>&1; }

# (1) Keychain prompt-free read test (exit-code only; value discarded)
if _guard kc_read; then agsec_ok "keychain read"
else agsec_bad "keychain read"; notify "agent-secrets smoke" "Keychain read failed"; fail=1; fi

# (2) sops decrypt self-test — --extract one entry, checked non-empty, never printed
v=""
if _try v store_extract "$AGENT_SECRETS_CANARY_NAME" && [ -n "$v" ]; then agsec_ok "sops decrypt"
else agsec_bad "sops decrypt"; notify "agent-secrets smoke" "sops decrypt self-test failed"; fail=1; fi
v=""

# (3) apiKeyHelper returns non-empty (never printed)
akh="$(agsec_bin_dir)/apiKeyHelper"; out=""
if [ -x "$akh" ] && _try out "$akh" && [ -n "$out" ]; then agsec_ok "apiKeyHelper"
else agsec_bad "apiKeyHelper"; notify "agent-secrets smoke" "apiKeyHelper empty/missing"; fail=1; fi
out=""

# (4) wrappers exist and are executable
for w in claude-agent cursor-agent; do
  if [ -x "$(agsec_bin_dir)/$w" ]; then agsec_ok "wrapper $w"
  else agsec_bad "wrapper $w"; notify "agent-secrets smoke" "wrapper $w missing/not executable"; fail=1; fi
done

# (5) manifest.toml rotate_by scan → notification for anything within 14 days
mf="$(agsec_manifest_toml)"
if [ -f "$mf" ]; then
  today=$(date +%s); name=""
  while IFS= read -r line; do
    case "$line" in
      *name*=*) name=$(printf '%s' "$line" | sed -E 's/.*=[[:space:]]*"?([^"]*)"?[[:space:]]*$/\1/') ;;
      *rotate_by*=*)
        rb=$(printf '%s' "$line" | sed -E 's/.*=[[:space:]]*"?([0-9-]+)"?.*/\1/')
        due=$(date -j -f %Y-%m-%d "$rb" +%s 2>/dev/null) || continue
        days=$(( (due - today) / 86400 ))
        if [ "$days" -le 14 ]; then notify "agent-secrets rotation" "$name rotate_by in ${days}d"; fi ;;
    esac
  done < "$mf"
  agsec_ok "rotate_by scan"
else
  agsec_attn "rotate_by scan (no manifest)"
fi

# (6) npm ignore-scripts still set — ADVISORY only (matches doctor's non-failing `attn`): npm absent
# or ignore-scripts unset is not a smoke FAILURE, so it neither fails the weekly job nor fires a red alert.
if agsec_have npm && _try v npm config get ignore-scripts && [ "$v" = true ]; then agsec_ok "ignore-scripts"
else agsec_attn "ignore-scripts (advisory — set: npm config set ignore-scripts true)"; fi

exit "$fail"
