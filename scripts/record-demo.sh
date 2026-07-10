#!/usr/bin/env bash
# scripts/record-demo.sh — record demo.cast against the REAL tool under a SYNTHETIC HOME with FAKE
# names only (never a real username/host/secret-name). The store is seeded BEFORE
# recording, so the recorded stream shows only names-only surfaces — no secret value (not even a
# fake one) ever appears in the cast. Run: scripts/record-demo.sh [output.cast]
set -euo pipefail
ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:-$ROOT/demo.cast}"
export AGENT_SECRETS_HOME; AGENT_SECRETS_HOME="$(mktemp -d "${TMPDIR:-/tmp}/agsec-demo.XXXXXX")"
# Keychain is NOT HOME-scoped — the mock `security` (+ siblings) on PATH keeps the recording fully
# isolated from the real login Keychain, same as the bats suite.
export PATH="$ROOT/tests/mocks:$ROOT/bin:$PATH"
trap 'rm -rf "$AGENT_SECRETS_HOME"' EXIT

# --- seed a store with FAKE names OUTSIDE the recording (values never enter the cast) ---
printf 'seed' | AGENT_SECRETS_UNATTENDED=1 "$ROOT/bin/agent-secrets" setup >/dev/null 2>&1 || true
printf 'seed2' | "$ROOT/bin/agent-secrets" add OPENAI_API_KEY >/dev/null 2>&1 || true

# --- the recorded script: names-only surfaces only ---
DEMO="$AGENT_SECRETS_HOME/demo-run.sh"
cat > "$DEMO" <<'SCRIPT'
#!/usr/bin/env bash
b() { printf '\033[1m$ %s\033[0m\n' "$*"; }
b "agent-secrets --version";        agent-secrets --version;               echo
b "agent-secrets list";             agent-secrets list;                    echo
b "agent-secrets doctor";           agent-secrets doctor 2>&1 | head -9;   echo
b "agent-secrets help";             agent-secrets help 2>&1 | head -12
SCRIPT
chmod +x "$DEMO"

if command -v asciinema >/dev/null 2>&1; then
  asciinema rec --overwrite -c "bash '$DEMO'" "$OUT" && echo "recorded $OUT"
else
  echo "asciinema not installed — skipping recording" >&2; exit 0
fi
