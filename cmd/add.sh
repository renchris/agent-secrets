#!/usr/bin/env bash
# cmd/add.sh — `add <NAME>`: read one value (hidden) and store it; upsert manifest.toml row.
# Sources: common.sh, ui.sh, store.sh. Value via ui_read_secret | store_add.
set -euo pipefail
. "${AGENT_SECRETS_LIB:?run via bin/agent-secrets}/common.sh"
agsec_die "add: not implemented yet"
