#!/usr/bin/env bash
# scripts/keychain-smoke.sh — macOS-major-upgrade custody gate.
# Names-only, prompt-free: exit 0 if the login Keychain yields the bootstrap age key, non-zero
# otherwise. Prints NOTHING — no value, no name. The exit code IS the whole result. Run BEFORE a
# macOS major upgrade to record a passing baseline, and AFTER (before any agent run); a
# post-upgrade failure flips custody to the file fallback via the selector (degraded, tracked).
# Self-contained (no common.sh) so it runs in a bare launchd gui/<uid> context.
set -euo pipefail
SERVICE="${AGENT_SECRETS_KC_SERVICE:-agent-age-key}"
security find-generic-password -s "$SERVICE" -w >/dev/null 2>&1
