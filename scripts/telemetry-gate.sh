#!/usr/bin/env bash
# scripts/telemetry-gate.sh — zero-telemetry / no-exfil CI gate.
# Fails (exit 1) if the tool source phones home, dumps env/Keychain, or a workflow leaks secrets.
# Scoped to ACTUAL exfil patterns so legitimate platform-name mentions do not false-positive.
# Runs in CI and is safe to run locally: scripts/telemetry-gate.sh
set -euo pipefail

ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# Directories/files that carry the tool's runtime behavior (exclude docs, tests, .git, self).
SRC_GLOBS=(bin cmd lib scripts install.sh)
SELF="scripts/telemetry-gate.sh"

fail=0
_hit() { printf '  ✗ %s\n' "$1" >&2; fail=1; }

# 1) Known analytics/telemetry endpoints or SDKs in tool source.
TELEMETRY_RE='(mixpanel|amplitude|segment\.(io|com)|google-?analytics|googletagmanager|posthog|\.datadoghq\.|newrelic|bugsnag|/collect\?|/v1/track|/api/track|telemetry\.[a-z]|analytics\.[a-z])'
# 2) Env / Keychain dumping piped somewhere, or bare full-env dumps in tool source.
EXFIL_RE='(security[[:space:]]+dump-keychain|(env|printenv)[[:space:]]*\|[[:space:]]*(curl|wget|nc|ncat|http)|base64[[:space:]]+.*\|[[:space:]]*(curl|wget|nc))'

echo "== telemetry-gate: scanning tool source ==" >&2
while IFS= read -r f; do
  [ "$f" = "$SELF" ] && continue
  if grep -nEI "$TELEMETRY_RE" "$f" 2>/dev/null; then _hit "telemetry endpoint/SDK in $f"; fi
  if grep -nEI "$EXFIL_RE" "$f" 2>/dev/null; then _hit "env/keychain exfil pattern in $f"; fi
done < <(find "${SRC_GLOBS[@]}" -type f \( -name '*.sh' -o -perm -u+x \) 2>/dev/null | sort -u)

# 3) Workflows must not dump env or echo secrets
echo "== telemetry-gate: scanning workflows ==" >&2
if [ -d .github/workflows ]; then
  while IFS= read -r wf; do
    if grep -nE 'run:[[:space:]]*(env|printenv|set)[[:space:]]*$' "$wf" 2>/dev/null; then _hit "bare env/printenv dump in $wf"; fi
    if grep -nE 'echo[[:space:]]+.*\$\{\{[[:space:]]*secrets\.' "$wf" 2>/dev/null; then _hit "secret echoed in $wf"; fi
  done < <(find .github/workflows -type f \( -name '*.yml' -o -name '*.yaml' \) | sort)
fi

if [ "$fail" -ne 0 ]; then
  echo "telemetry-gate: FAILED — remove the exfil/telemetry pattern(s) above." >&2
  exit 1
fi
echo "telemetry-gate: PASS (no telemetry, no env/Keychain exfil, no secret leakage in workflows)." >&2
