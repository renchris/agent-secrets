#!/usr/bin/env bash
# cmd/run.sh — `run -- <cmd>...`: JIT-inject secrets (process-scoped) and exec the command.
# Sources: common.sh, store.sh, keychain.sh. Requires `--` separator.
set -euo pipefail
. "${AGENT_SECRETS_LIB:?run via bin/agent-secrets}/common.sh"
# shellcheck source=lib/store.sh
. "$AGENT_SECRETS_LIB/store.sh"
# shellcheck source=lib/keychain.sh
. "$AGENT_SECRETS_LIB/keychain.sh"

[ "${1:-}" = "--" ] || agsec_die "usage: agent-secrets run -- <cmd> [args...]"
[ -f "$(agsec_store_file)" ] || agsec_die "no store found — run: agent-secrets setup"
store_exec "$@"
