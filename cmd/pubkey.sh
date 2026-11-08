#!/usr/bin/env bash
# cmd/pubkey.sh — `pubkey [--copy]`: print your age recipient string + its fingerprint.
# The recipient is a PUBLIC key — stdout/argv/clipboard are ALL safe here (unlike every
# value path), so pubkey is NOT gated: it works fine inside an agent session. That's the
# point — it's the on-ramp a colleague needs before they can `share` a secret with you.
set -euo pipefail
. "${AGENT_SECRETS_LIB:?run via bin/agent-secrets}/common.sh"
case "${1:-}" in -h|--help) . "$AGENT_SECRETS_LIB/help.sh"; agsec_help_render pubkey; exit 0 ;; esac

copy=0 dash_warned=0
for arg in "$@"; do
  case "$arg" in
    --copy) copy=1 ;;
    -) [ "$dash_warned" -eq 1 ] || agsec_warn "pubkey: '-' is ignored and will be rejected in a future release"
       dash_warned=1 ;;
    -h|--help) . "$AGENT_SECRETS_LIB/help.sh"; agsec_help_render pubkey; exit 0 ;;
    -*) agsec_unknown_option pubkey "$arg" ;;
    *) agsec_unexpected_argument pubkey ;;
  esac
done
agsec_parse_only_exit

pub="$(agsec_age_pub_file)"
[ -s "$pub" ] || agsec_die "no public key yet — run: agent-secrets setup"

recip="$(tr -d '[:space:]' < "$pub")"
[ -n "$recip" ] || agsec_die "no public key yet — run: agent-secrets setup"
fp="$(printf '%s' "$recip" | agsec_digest)"

# The recipient is the only stdout, so `pubkey | pbcopy` and `$(agent-secrets pubkey)` get just the key.
printf '%sYour age recipient (public key — safe to share):%s\n' "$E_BOLD" "$E_RESET" >&2
printf '%s\n' "$recip"
agsec_plan "fingerprint: $fp"   # an ID, so never faint
agsec_note "hand this to whoever will \`share\` a secret with you — it carries no secret."

if [ "$copy" -eq 1 ]; then
  if agsec_have pbcopy; then
    printf '%s' "$recip" | pbcopy
    agsec_note "copied recipient string to clipboard."
  else
    agsec_warn "pbcopy not found — recipient string printed above, not copied."
  fi
fi
