#!/usr/bin/env bash
# cmd/uninstall.sh — total removal via install-manifest: files, PATH block, launchd bootout,
# settings.json apiKeyHelper revert, Keychain agent-* purge; keep-vs-purge prompt for store+keys.
# Sources: common.sh, manifest.sh. Supports --dry-run.
set -euo pipefail
. "${AGENT_SECRETS_LIB:?run via bin/agent-secrets}/common.sh"
agsec_die "uninstall: not implemented yet"
