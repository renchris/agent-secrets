#!/usr/bin/env bash
# cmd/add.sh — `add <NAME>`: read one value (hidden) and store it (store_add writes the manifest row).
# Value source = STDIN if piped (testable/scriptable), else ui_read_secret.
set -euo pipefail
. "${AGENT_SECRETS_LIB:?run via bin/agent-secrets}/common.sh"
case "${1:-}" in -h|--help) . "$AGENT_SECRETS_LIB/help.sh"; agsec_help_render add; exit 0 ;; esac
# shellcheck source=lib/store.sh
. "$AGENT_SECRETS_LIB/store.sh"
# shellcheck source=lib/keychain.sh
. "$AGENT_SECRETS_LIB/keychain.sh"
# shellcheck source=lib/ui.sh
. "$AGENT_SECRETS_LIB/ui.sh"

name="${1:-}"
[ -n "$name" ] || agsec_die "usage: agent-secrets add <NAME>" 2
case "$name" in
  [A-Za-z_]*[!A-Za-z0-9_]* | [!A-Za-z_]*) agsec_die "invalid name '$name' — use letters, digits, underscore (start with a letter/_)" 2;;
esac
[ -f "$(agsec_store_file)" ] || agsec_die "no store yet — run: agent-secrets setup"

if [ -t 0 ]; then
  ui_read_secret "Value for $name" | store_add "$name"
else
  store_add "$name"          # value already on the pipe
fi
agsec_ok "stored $name (value never shown or logged)"
