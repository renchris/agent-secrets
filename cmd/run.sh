#!/usr/bin/env bash
# cmd/run.sh — `run -- <cmd>...`: JIT-inject secrets (process-scoped) and exec the command.
# Sources: common.sh, store.sh, keychain.sh. Requires `--` separator.
set -euo pipefail
. "${AGENT_SECRETS_LIB:?run via bin/agent-secrets}/common.sh"
case "${1:-}" in -h|--help) . "$AGENT_SECRETS_LIB/help.sh"; agsec_help_render run; exit 0 ;; esac
# shellcheck source=lib/store.sh
. "$AGENT_SECRETS_LIB/store.sh"
# shellcheck source=lib/keychain.sh
. "$AGENT_SECRETS_LIB/keychain.sh"

# --no-egress (or AGENT_SECRETS_NO_EGRESS=1) opts out of the allowlist bound for a tool that breaks
# behind a proxy. Parsed BEFORE the required `--` separator.
if [ "${1:-}" = "--no-egress" ]; then export AGENT_SECRETS_NO_EGRESS=1; shift; fi
[ "${1:-}" = "--" ] || agsec_die "usage: agent-secrets run [--no-egress] -- <cmd> [args...]" 2
[ "$#" -ge 2 ] || agsec_die "usage: agent-secrets run [--no-egress] -- <cmd> [args...]" 2   # a command must follow --
[ -f "$(agsec_store_file)" ] || agsec_die "no store found — run: agent-secrets setup"
# shellcheck source=lib/egress.sh
. "$AGENT_SECRETS_LIB/egress.sh"
egress_run "$@"   # inject secrets + (if an allowlist is configured) bound egress; else plain store_exec
