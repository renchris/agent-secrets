#!/usr/bin/env bash
# scripts/record-demo.sh — regenerate assets/demo.gif (the hero animation) reproducibly.
# Seeds an ISOLATED store with FAKE names outside the recording, wires wrappers so `doctor` is
# green, then runs Charm VHS over assets/demo.tape. NAMES-ONLY: no secret value is ever typed or
# shown; the real login Keychain is untouched (mock `security` on PATH). Requires: vhs, age, sops.
set -euo pipefail
ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEMO="${AGENT_SECRETS_DEMO_HOME:-/tmp/agsec-demoenv}"
export AGENT_SECRETS_HOME="$DEMO"

command -v vhs >/dev/null 2>&1 || { echo "vhs not installed — brew install vhs" >&2; exit 1; }

rm -rf "$DEMO"; mkdir -p "$DEMO/bin"
# Seed with realistic-LENGTH fake values (so `run … | wc -c` shows a convincing count) — the values
# are placeholders, never real, and never displayed by the tool.
# shellcheck disable=SC2016  # the $(...) refs run in the INNER bash -c, intentionally unexpanded here
env AGENT_SECRETS_HOME="$DEMO" AGENT_SECRETS_LIB="$ROOT/lib" PATH="$ROOT/tests/mocks:$PATH" bash -c '
  . "$AGENT_SECRETS_LIB/common.sh"; . "$AGENT_SECRETS_LIB/keychain.sh"; . "$AGENT_SECRETS_LIB/store.sh"
  mkdir -p "$(agsec_config_dir)"; age-keygen -o "$(agsec_age_key_file)" 2>/dev/null; chmod 600 "$(agsec_age_key_file)"
  age-keygen -y "$(agsec_age_key_file)" >"$(agsec_age_pub_file)"; kc_write_selector; store_init >/dev/null 2>&1
  cat "$(agsec_age_key_file)" | kc_add
  printf "%048d" 0 | store_add ANTHROPIC_API_KEY >/dev/null 2>&1
  printf "%048d" 0 | store_add OPENAI_API_KEY    >/dev/null 2>&1
  printf "%048d" 0 | store_add STRIPE_SECRET_KEY >/dev/null 2>&1'
for w in claude-agent cursor-agent apiKeyHelper; do ln -sf "$ROOT/bin/$w" "$DEMO/bin/$w"; done
mkdir -p "$DEMO/.claude/projects"; chmod 700 "$DEMO/.claude/projects"
printf '{"cleanupPeriodDays":7,"apiKeyHelper":"%s/bin/apiKeyHelper"}\n' "$DEMO" > "$DEMO/.claude/settings.json"

( cd "$ROOT" && vhs assets/demo.tape )
echo "regenerated $ROOT/assets/demo.gif"
rm -rf "$DEMO"
