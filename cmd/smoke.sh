#!/usr/bin/env bash
# cmd/smoke.sh — weekly maintenance smoke: Keychain read, sops decrypt self-test,
# apiKeyHelper non-empty, wrappers executable, manifest.toml rotate_by scan → local notification,
# ignore-scripts still set. Run by the launchd job (not a dispatcher verb). Names-only, no values.
# Sources: common.sh, store.sh, keychain.sh.
set -euo pipefail
. "${AGENT_SECRETS_LIB:?run via bin/agent-secrets}/common.sh"
agsec_die "smoke: not implemented yet"
