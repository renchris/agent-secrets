#!/usr/bin/env bash
# cmd/doctor.sh — health check: categories custody|store|injection|hygiene|maintenance|
# supply-chain, each ✓/⚠/✗ names-only. Flags --format=json --redact --gates --fix.
# Sources: common.sh, store.sh, keychain.sh. Exit 0 if no ✗, else 1.
set -euo pipefail
. "${AGENT_SECRETS_LIB:?run via bin/agent-secrets}/common.sh"
agsec_die "doctor: not implemented yet"
