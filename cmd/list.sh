#!/usr/bin/env bash
# cmd/list.sh — `list`: print secret NAMES + manifest.toml metadata (rotate_by). Never values.
# Optional --format=json. 
set -euo pipefail
. "${AGENT_SECRETS_LIB:?run via bin/agent-secrets}/common.sh"
# shellcheck source=lib/store.sh
. "$AGENT_SECRETS_LIB/store.sh"
# shellcheck source=lib/keychain.sh
. "$AGENT_SECRETS_LIB/keychain.sh"

fmt=text
case "${1:-}" in
  ''|--format=text) fmt=text ;;
  --format=json) fmt=json ;;
  *) agsec_die "usage: agent-secrets list [--format=json]" ;;
esac

man="$(agsec_manifest_toml)"
_rotate_of() { grep -A6 "name = \"$1\"" "$man" 2>/dev/null | sed -n 's/.*rotate_by = "\(.*\)".*/\1/p' | head -1; }

if [ ! -f "$(agsec_store_file)" ]; then
  if [ "$fmt" = json ]; then printf '[]\n'; else agsec_note "no secrets yet — run: agent-secrets add <NAME>"; fi
  exit 0
fi

names="$(store_names 2>/dev/null || true)"

if [ "$fmt" = json ]; then
  {
    while IFS= read -r n; do
      [ -n "$n" ] || continue
      jq -cn --arg n "$n" --arg r "$(_rotate_of "$n")" '{name:$n, rotate_by:$r}'
    done <<EOF
$names
EOF
  } | jq -s '.'
else
  printf '%sSecrets (names only — values are never shown):%s\n' "$C_BOLD" "$C_RESET"
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    r="$(_rotate_of "$n")"
    printf '  • %s%s\n' "$n" "${r:+  ${C_DIM}(rotate by $r)${C_RESET}}"
  done <<EOF
$names
EOF
fi
