#!/usr/bin/env bats
# tests/headless.bats — the agent entrypoint: `setup` with nobody to prompt, and the invariants that
# make it safe to run inside a transcript-bearing session. Every assertion corresponds to a measured
# claim in docs/plans/AGENT_ENTRYPOINT_HEADLESS.md (M1–M5). Synthetic HOME + mocked `security`.
load test_helper

# A "coding-agent session" as the tool detects it. Stdin is /dev/null, exactly as a Claude Code
# Bash tool call presents it.
_agent() { env CLAUDECODE=1 AGENT_SECRETS_HOME="$AGENT_SECRETS_HOME" "$@" </dev/null; }

# ---- the mode switch --------------------------------------------------------------------------

@test "M1/M2: bare `setup` inside an agent session runs HEADLESS instead of refusing — real keys, primary custody, exit 0" {
  run _agent bash "$REPO_ROOT/bin/agent-secrets" setup
  [ "$status" -eq 0 ]
  [[ "$output" != *"refusing the key ceremony"* ]] || return 1
  [[ "$output" == *"(headless)"* ]] || return 1
  [[ "$output" == *"coding-agent session"* ]] || return 1          # the ONE reason, named
  [[ "$output" == *"Keychain custody — primary"* ]] || return 1    # M3: populated over stdin, no tty
  [[ "$output" == *"You're set up"* ]] || return 1
  [ -s "$AGENT_SECRETS_HOME/.config/secrets/age.key" ]
  [ -s "$AGENT_SECRETS_HOME/.config/secrets/secrets.env" ]
  [ -L "$AGENT_SECRETS_HOME/bin/claude-agent" ]
  grep -q done "$AGENT_SECRETS_HOME/.local/state/agent-secrets/wizard-state.json"
}

@test "names-only under headless: no AGE-SECRET-KEY, no prompt text, no clipboard call in the output" {
  # Capture pbcopy: a headless run must never touch the user's clipboard (it is not theirs to overwrite).
  local d="$AGENT_SECRETS_HOME/cap"; mkdir -p "$d"
  printf '#!/bin/sh\necho PBCOPY-CALLED >>"$AGENT_SECRETS_HOME/pbcopy.calls"; cat >/dev/null\n' >"$d/pbcopy"; chmod +x "$d/pbcopy"
  run env PATH="$d:$PATH" CLAUDECODE=1 AGENT_SECRETS_HOME="$AGENT_SECRETS_HOME" bash "$REPO_ROOT/bin/agent-secrets" setup </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" != *"AGE-SECRET-KEY"* ]] || return 1
  [[ "$output" != *"[Y/n]"* ]] || return 1
  [[ "$output" != *"[y/N]"* ]] || return 1
  [[ "$output" != *"choose ["* ]] || return 1
  [[ "$output" != *"password data for new item"* ]] || return 1
  [ ! -f "$AGENT_SECRETS_HOME/pbcopy.calls" ]
}

@test "the recovery key is KEPT on disk (0600) in headless — never deleted unverified — and the done screen names the human follow-up" {
  run _agent bash "$REPO_ROOT/bin/agent-secrets" setup
  [ "$status" -eq 0 ]
  local rec="$AGENT_SECRETS_HOME/.config/secrets/recovery.key"
  [ -s "$rec" ]
  [ "$(stat -f '%Lp' "$rec")" = "600" ]
  [[ "$output" == *"RECOVERY key kept on this Mac"* ]] || return 1
  [[ "$output" == *"Left for a human"* ]] || return 1
  [[ "$output" == *"agent-secrets setup"* ]] || return 1
}

@test "--headless forces the prompt-free path even with no agent marker (ssh -T / cron / CI with real keys)" {
  run bash -c "env -u CLAUDECODE -u CLAUDE_CODE -u CURSOR_AGENT -u CURSOR_TRACE_ID -u TERM_PROGRAM AGENT_SECRETS_HOME='$AGENT_SECRETS_HOME' bash '$REPO_ROOT/bin/agent-secrets' setup --headless </dev/null"
  [ "$status" -eq 0 ]
  [[ "$output" == *"(headless)"* ]] || return 1
  [[ "$output" == *"--headless"* ]] || return 1
  [ -s "$AGENT_SECRETS_HOME/.config/secrets/age.key" ]
}

@test "headless is idempotent: a second run mints no second key and touches no prompt" {
  _agent bash "$REPO_ROOT/bin/agent-secrets" setup >/dev/null 2>&1
  local pub1; pub1="$(cat "$AGENT_SECRETS_HOME/.config/secrets/age.pub")"
  run _agent bash "$REPO_ROOT/bin/agent-secrets" setup
  [ "$status" -eq 0 ]
  [ "$(cat "$AGENT_SECRETS_HOME/.config/secrets/age.pub")" = "$pub1" ]
  [[ "$output" == *"already set up"* ]] || return 1
}

# ---- --import-env: the only way a secret enters a headless setup --------------------------------

@test "--import-env stores each NAME that is set in the environment, names the absent ones, and never prints a value" {
  run env CLAUDECODE=1 AGENT_SECRETS_HOME="$AGENT_SECRETS_HOME" \
      OPENROUTER_API_KEY=env-import-val-7e2 ABSENT_KEY= \
      bash "$REPO_ROOT/bin/agent-secrets" setup --import-env OPENROUTER_API_KEY,ABSENT_KEY,NEVER_SET </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"imported OPENROUTER_API_KEY"* ]] || return 1
  [[ "$output" == *"ABSENT_KEY is not set"* ]] || return 1          # empty counts as not set (store_add fail-closes on empty)
  [[ "$output" == *"NEVER_SET is not set"* ]] || return 1
  [[ "$output" != *"env-import-val-7e2"* ]] || return 1
  run agsec list
  [[ "$output" == *"OPENROUTER_API_KEY"* ]] || return 1
  [[ "$output" != *"ABSENT_KEY"* ]] || return 1
  [[ "$output" != *"NEVER_SET"* ]] || return 1
}

@test "--import-env implies headless, and refuses a NAME that is not an identifier (a value on argv is the leak it guards)" {
  run bash -c "env -u CLAUDECODE -u CLAUDE_CODE -u CURSOR_AGENT -u CURSOR_TRACE_ID -u TERM_PROGRAM AGENT_SECRETS_HOME='$AGENT_SECRETS_HOME' bash '$REPO_ROOT/bin/agent-secrets' setup --import-env 'sk-ant-looks-like-a-value' </dev/null"
  [ "$status" -eq 2 ]
  [[ "$output" == *"--import-env"* ]] || return 1
  [ ! -f "$AGENT_SECRETS_HOME/.config/secrets/age.key" ]          # refused BEFORE any mutation
  run bash -c "env -u CLAUDECODE -u CLAUDE_CODE -u CURSOR_AGENT -u CURSOR_TRACE_ID -u TERM_PROGRAM MY_TOKEN=tok-9a AGENT_SECRETS_HOME='$AGENT_SECRETS_HOME' bash '$REPO_ROOT/bin/agent-secrets' setup --import-env MY_TOKEN </dev/null"
  [ "$status" -eq 0 ]
  [[ "$output" == *"(headless)"* ]] || return 1
}

@test "--import-env on an ALREADY set-up machine imports and reports — the natural 'add these' one-liner" {
  _agent bash "$REPO_ROOT/bin/agent-secrets" setup >/dev/null 2>&1
  run env CLAUDECODE=1 AGENT_SECRETS_HOME="$AGENT_SECRETS_HOME" LATER_KEY=later-val-1 \
      bash "$REPO_ROOT/bin/agent-secrets" setup --import-env LATER_KEY </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"imported LATER_KEY"* ]] || return 1
  run agsec list
  [[ "$output" == *"LATER_KEY"* ]] || return 1
}

# ---- M4: apiKeyHelper is wired only once ANTHROPIC_API_KEY exists ---------------------------------

@test "M4: headless setup with no ANTHROPIC_API_KEY does NOT wire apiKeyHelper, and doctor exits 0" {
  mkdir -p "$AGENT_SECRETS_HOME/.claude"
  run _agent bash "$REPO_ROOT/bin/agent-secrets" setup
  [ "$status" -eq 0 ]
  [[ "$output" == *"apiKeyHelper not wired"* ]] || return 1
  # settings.json either does not exist or carries no apiKeyHelper key
  if [ -f "$AGENT_SECRETS_HOME/.claude/settings.json" ]; then
    [ -z "$(jq -r '.apiKeyHelper // empty' "$AGENT_SECRETS_HOME/.claude/settings.json")" ]
  fi
  run agsec doctor
  [ "$status" -eq 0 ]
  [[ "$output" != *"✗"* ]] || return 1
  [[ "$output" == *"no ANTHROPIC_API_KEY stored"* ]] || return 1
}

@test "M4: `add ANTHROPIC_API_KEY` completes the wiring the moment the key exists (reversible edit, recorded)" {
  _agent bash "$REPO_ROOT/bin/agent-secrets" setup >/dev/null 2>&1
  run bash -c "printf '%s' add-wires-val-4b | AGENT_SECRETS_HOME='$AGENT_SECRETS_HOME' bash '$REPO_ROOT/bin/agent-secrets' add ANTHROPIC_API_KEY"
  [ "$status" -eq 0 ]
  [[ "$output" == *"wired apiKeyHelper"* ]] || return 1
  [[ "$output" != *"add-wires-val-4b"* ]] || return 1
  [ "$(jq -r '.apiKeyHelper' "$AGENT_SECRETS_HOME/.claude/settings.json")" = "$AGENT_SECRETS_HOME/bin/apiKeyHelper" ]
  jq -e '.[] | select(.type=="edit" and .marker=="apiKeyHelper")' "$AGENT_SECRETS_HOME/.local/state/agent-secrets/install-manifest.json" >/dev/null
  run agsec doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"settings.json apiKeyHelper — wired"* ]] || return 1
  [[ "$output" == *"apiKeyHelper — returns credential"* ]] || return 1
}

@test "M4: doctor flags a helper wired with NO key stored as ✗ — that configuration breaks Claude Code's auth" {
  setup_store
  local bd="$AGENT_SECRETS_HOME/bin"; mkdir -p "$bd" "$AGENT_SECRETS_HOME/.claude"
  ln -sf "$REPO_ROOT/bin/apiKeyHelper" "$bd/apiKeyHelper"
  jq -n --arg h "$bd/apiKeyHelper" '{apiKeyHelper:$h}' >"$AGENT_SECRETS_HOME/.claude/settings.json"
  run agsec doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"auth will FAIL"* ]] || return 1
}

# ---- F28: a ✗ health check is a failed setup ------------------------------------------------------
# The ✗ fixture is M4's: a settings.json helper wired with no ANTHROPIC_API_KEY stored. Setup leaves a
# pre-existing helper in place (lib/wire.sh only adds one), so doctor --summary reports it as ✗.
_wire_helper_without_key() {
  mkdir -p "$AGENT_SECRETS_HOME/.claude"
  jq -n --arg h "$AGENT_SECRETS_HOME/bin/apiKeyHelper" '{apiKeyHelper:$h}' >"$AGENT_SECRETS_HOME/.claude/settings.json"
}

@test "setup exits 1 and does not say 'You're set up' when the health check finds a ✗" {
  _wire_helper_without_key
  run _agent bash "$REPO_ROOT/bin/agent-secrets" setup --no-discovery
  [ "$status" -eq 1 ]
  [[ "$output" == *"auth will FAIL"* ]] || return 1
  [[ "$output" != *"You're set up"* ]] || return 1
  [[ "$output" == *"Set up, with problems"* ]] || return 1
  [[ "$output" == *"next: agent-secrets doctor"* ]] || return 1
  [[ "$output" == *"$AGENT_SECRETS_HOME/bin/agent-secrets"* ]] || return 1   # the done screen still runs
  local st="$AGENT_SECRETS_HOME/.local/state/agent-secrets/wizard-state.json"
  grep -qx checked "$st"
  ! grep -q done "$st"
}

@test "a re-run on an installed machine exits 1 when the health check finds a ✗" {
  _agent bash "$REPO_ROOT/bin/agent-secrets" setup --no-discovery >/dev/null 2>&1
  _wire_helper_without_key
  run _agent bash "$REPO_ROOT/bin/agent-secrets" setup --no-discovery
  [ "$status" -eq 1 ]
  [[ "$output" == *"already set up"* ]] || return 1
  [[ "$output" == *"next: agent-secrets doctor"* ]] || return 1
  grep -qx checked "$AGENT_SECRETS_HOME/.local/state/agent-secrets/wizard-state.json"
}

# ---- discovery: default on, announced, --no-discovery, standalone ---------------------------------

@test "headless writes the machine-wide agent rules by default and ANNOUNCES each file before writing" {
  mkdir -p "$AGENT_SECRETS_HOME/.claude"
  run _agent bash "$REPO_ROOT/bin/agent-secrets" setup
  [ "$status" -eq 0 ]
  [[ "$output" == *"Writing the agent-secrets rules"* ]] || return 1
  [[ "$output" == *"$AGENT_SECRETS_HOME/.claude/CLAUDE.md"* ]] || return 1
  grep -q '<!-- >>> agent-secrets >>> -->' "$AGENT_SECRETS_HOME/.claude/CLAUDE.md"
  grep -q 'agent-secrets:version=' "$AGENT_SECRETS_HOME/.claude/CLAUDE.md"   # integrity-marked
  jq -e '.[] | select(.type=="pathblock" and .marker=="agent-secrets")' "$AGENT_SECRETS_HOME/.local/state/agent-secrets/install-manifest.json" >/dev/null  # reversible
}

@test "--no-discovery writes nothing machine-wide" {
  mkdir -p "$AGENT_SECRETS_HOME/.claude"
  run _agent bash "$REPO_ROOT/bin/agent-secrets" setup --no-discovery
  [ "$status" -eq 0 ]
  [ ! -f "$AGENT_SECRETS_HOME/.claude/CLAUDE.md" ]
}

@test "setup --discovery is the standalone later opt-in — one command, no wizard, idempotent" {
  mkdir -p "$AGENT_SECRETS_HOME/.claude"
  _agent bash "$REPO_ROOT/bin/agent-secrets" setup --no-discovery >/dev/null 2>&1
  [ ! -f "$AGENT_SECRETS_HOME/.claude/CLAUDE.md" ]
  run _agent bash "$REPO_ROOT/bin/agent-secrets" setup --discovery
  [ "$status" -eq 0 ]
  [[ "$output" == *"aware: Claude Code"* ]] || return 1
  [[ "$output" != *"[1/6]"* ]] || return 1
  run _agent bash "$REPO_ROOT/bin/agent-secrets" setup --discovery
  [ "$status" -eq 0 ]
  [ "$(grep -c '<!-- >>> agent-secrets >>> -->' "$AGENT_SECRETS_HOME/.claude/CLAUDE.md")" = "1" ]   # one block, not two
}

# ---- --keychain and --restore are usable from an agent session now ----------------------------------

@test "setup --keychain works inside an agent session (no tty needed: file → pipe → security -i)" {
  setup_store                                   # file custody only
  run _agent bash "$REPO_ROOT/bin/agent-secrets" setup --keychain
  [ "$status" -eq 0 ]
  [[ "$output" == *"primary"* ]] || return 1
  export AGENT_SECRETS_LIB="$REPO_ROOT/lib"; . "$REPO_ROOT/lib/common.sh"; . "$REPO_ROOT/lib/keychain.sh"
  run kc_status
  [ "$output" = "primary" ]
}

@test "kc_populate_stdin stores ONLY the AGE-SECRET-KEY line (a whole key file's first line is a comment)" {
  setup_store
  export AGENT_SECRETS_LIB="$REPO_ROOT/lib"; . "$REPO_ROOT/lib/common.sh"; . "$REPO_ROOT/lib/keychain.sh"
  run kc_populate_stdin
  [ "$status" -eq 0 ]
  run security find-generic-password -s "$AGENT_SECRETS_KC_SERVICE" -w
  [[ "$output" == AGE-SECRET-KEY-1* ]] || return 1
  [[ "$output" != *"# created"* ]] || return 1
  [ "$(printf '%s' "$output" | wc -l | tr -d ' ')" = "0" ]       # exactly one line
}

@test "setup --restore inside an agent session takes the key from a PIPE (a file the agent holds), never a prompt" {
  setup_store
  export AGENT_SECRETS_LIB="$REPO_ROOT/lib"; . "$REPO_ROOT/lib/common.sh"
  local saved; saved="$(cat "$(agsec_age_key_file)")"
  rm -f "$(agsec_age_key_file)"
  run bash -c "printf '%s' '$saved' | CLAUDECODE=1 AGENT_SECRETS_HOME='$AGENT_SECRETS_HOME' bash '$REPO_ROOT/bin/agent-secrets' setup --restore"
  [ "$status" -eq 0 ]
  [[ "$output" == *"verified"* ]] || return 1
  [[ "$output" != *"AGE-SECRET-KEY"* ]] || return 1
}
