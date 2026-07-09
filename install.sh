#!/usr/bin/env bash
# install.sh — one-command bootstrap (curl'd). 
# MUST: function-guarded (main(){…}; main "$@") so truncated download can't partial-exec (fix #2);
# consent gate + --dry-run as the first screen; brew install age sops gum; pinned-tag + SHA-256
# verify; AGENT_SECRETS_BASE_URL override (private-repo/mirror; the smoke uses it); record every
# artifact via lib/manifest.sh; then invoke `agent-secrets setup`. No secret values here.
set -euo pipefail

main() {
  echo "install.sh: not implemented yet" >&2
  exit 1
}

main "$@"
