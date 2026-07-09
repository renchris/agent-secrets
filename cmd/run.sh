#!/usr/bin/env bash
# cmd/run.sh — `run -- <cmd>...`: JIT-inject secrets (process-scoped) and exec the command.
# Sources: common.sh, store.sh, keychain.sh. Requires `--` separator.
set -euo pipefail
. "${AGENT_SECRETS_LIB:?run via bin/agent-secrets}/common.sh"
agsec_die "run: not implemented yet"
