#!/usr/bin/env bash
# cmd/list.sh — `list`: print secret NAMES + manifest.toml metadata (rotate_by, used_by).
# Never values. Sources: common.sh, store.sh. Optional --format=json.
set -euo pipefail
. "${AGENT_SECRETS_LIB:?run via bin/agent-secrets}/common.sh"
agsec_die "list: not implemented yet"
