#!/usr/bin/env bats
# tests/onboarding.bats — the "complete onboarding" UX: doctor --summary tiers, the placeholder-credential
# guard, `help onboarding`, the centralized agent-rules block + Cursor clipboard, cleanupPeriodDays-on-create.
# All under synthetic AGENT_SECRETS_HOME; never touches the real machine.
load test_helper

# ---- doctor --summary (P1-2) -------------------------------------------------------------------

@test "doctor --summary hides optional hardening rows and prints the count footer" {
  setup_store
  run bash "$REPO_ROOT/bin/agent-secrets" doctor --summary
  # core rows survive
  [[ "$output" == *"[custody]"* ]] || return 1
  [[ "$output" == *"[store]"* ]] || return 1
  # aspirational rows are hidden in summary
  [[ "$output" != *"[backup]"* ]] || return 1
  [[ "$output" != *"[supply-chain]"* ]] || return 1
  [[ "$output" != *"[maintenance]"* ]] || return 1
  # and the footer names how to see them
  [[ "$output" == *"optional hardening check(s) hidden"* ]] || return 1
}

@test "doctor --summary shows fewer attn than the full report (the 'feels broken' fix)" {
  setup_store
  full=$(bash "$REPO_ROOT/bin/agent-secrets" doctor | grep -c '⚠') || true
  summ=$(bash "$REPO_ROOT/bin/agent-secrets" doctor --summary | grep -c '⚠') || true
  [ "$summ" -lt "$full" ]           # strictly quieter
  [ "$summ" -le 3 ]                 # acceptance: ≤3 attn by default
}

@test "doctor --summary still surfaces a real ✗ (never hides failures)" {
  # bare HOME → injection wrappers missing = ✗; summary must still show them
  run bash "$REPO_ROOT/bin/agent-secrets" doctor --summary
  [ "$status" -eq 1 ]
  [[ "$output" == *"✗"* ]] || return 1
  [[ "$output" == *"[injection]"* ]] || return 1
}

@test "doctor --summary is text-only: --format=json still emits EVERY row (agents parse the full manifest)" {
  setup_store
  # doctor exits 1 here (no injection wrappers on setup_store) — tolerate it; we compare row counts, not exit.
  full=$(bash "$REPO_ROOT/bin/agent-secrets" doctor --format=json | jq '.checks|length') || true
  summ=$(bash "$REPO_ROOT/bin/agent-secrets" doctor --summary --format=json | jq '.checks|length') || true
  [ "$full" -eq "$summ" ]           # summary does not filter JSON
  [ "$full" -gt 8 ]
}

# ---- placeholder-credential guard (P0-3) -------------------------------------------------------

@test "doctor flags ANTHROPIC_API_KEY holding the unattended placeholder; clears with a real value" {
  setup_store
  printf '%s' "unattended-placeholder-value" | store_add ANTHROPIC_API_KEY
  run bash "$REPO_ROOT/bin/agent-secrets" doctor
  [[ "$output" == *"unattended TEST placeholder"* ]] || return 1
  # a real value clears the flag
  printf '%s' "sk-ant-real-xyz" | store_add ANTHROPIC_API_KEY
  run bash "$REPO_ROOT/bin/agent-secrets" doctor
  [[ "$output" != *"unattended TEST placeholder"* ]] || return 1
}

@test "the placeholder guard is names-only: it never prints the placeholder VALUE beyond the known constant" {
  setup_store
  printf '%s' "unattended-placeholder-value" | store_add ANTHROPIC_API_KEY
  # doctor may name the constant in its own remediation text, but must not echo a stored real value.
  printf '%s' "sk-ant-SENTINEL-must-not-leak" | store_add OPENAI_API_KEY
  run bash -c "bash '$REPO_ROOT/bin/agent-secrets' doctor 2>&1 | grep -c SENTINEL"
  [ "$output" -eq 0 ]
}

# ---- canary (optional) (P1-4) ------------------------------------------------------------------

@test "doctor marks the inert canary as (optional), not a defect" {
  setup_store
  run bash "$REPO_ROOT/bin/agent-secrets" doctor
  [[ "$output" == *"INERT decoy (optional)"* ]] || return 1
}

# ---- help onboarding (P0-1) --------------------------------------------------------------------

@test "help onboarding renders the brew-less gh + az recipes and the token ladder" {
  run bash "$REPO_ROOT/bin/agent-secrets" help onboarding
  [ "$status" -eq 0 ]
  [[ "$output" == *"GitHub CLI (gh)"* ]] || return 1
  [[ "$output" == *"Azure CLI (az)"* ]] || return 1
  [[ "$output" == *"gh auth login"* ]] || return 1
  [[ "$output" == *"az login"* ]] || return 1
  [[ "$output" == *"Python 3.9+"* ]] || return 1        # the non-obvious az prerequisite
}

@test "help onboarding is a TOPIC, not a command: help --json still lists exactly 11 commands" {
  run bash -c "bash '$REPO_ROOT/bin/agent-secrets' help --json | jq -e '.commands|length==11'"
  [ "$status" -eq 0 ]
}

@test "top-level help advertises the onboarding topic" {
  run bash "$REPO_ROOT/bin/agent-secrets" help
  [[ "$output" == *"help onboarding"* ]] || return 1
}

# ---- centralized agent-rules + Cursor clipboard (P0-2) -----------------------------------------

@test "agsec_agent_rules is the single source of the four golden rules (names-only, paste template)" {
  export AGENT_SECRETS_LIB="$REPO_ROOT/lib"
  # shellcheck source=/dev/null
  . "$REPO_ROOT/lib/common.sh"
  run agsec_agent_rules
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c '^- ')" -eq 4 ]           # exactly four rules
  [[ "$output" == *"NEVER write a secret to a .env"* ]] || return 1
  [[ "$output" == *"agent-secrets run -- <cmd>"* ]] || return 1
}

@test "done screen copies the golden rules to the clipboard and points at help onboarding" {
  # Capturing pbcopy shadows the discard mock so we can assert the clipboard payload.
  local capdir="$AGENT_SECRETS_HOME/capbin"; mkdir -p "$capdir"
  printf '#!/usr/bin/env bash\ncat >"%s/clip.txt"\n' "$AGENT_SECRETS_HOME" >"$capdir/pbcopy"
  chmod +x "$capdir/pbcopy"
  run env PATH="$capdir:$PATH" bash -c "printf '%s' seedval | AGENT_SECRETS_UNATTENDED=1 bash '$REPO_ROOT/bin/agent-secrets' setup"
  [ "$status" -eq 0 ]
  [[ "$output" == *"help onboarding"* ]] || return 1                # next-steps pointer
  [[ "$output" == *"copied to your clipboard"* ]] || return 1       # the clipboard action happened
  grep -qF "agent-secrets run -- <cmd>" "$AGENT_SECRETS_HOME/clip.txt"   # the rules actually landed there
}

# ---- cleanupPeriodDays on create + reversibility (P1-3) -----------------------------------------

@test "setup sets cleanupPeriodDays=14 on a settings.json it CREATES" {
  run bash -c "printf '%s' seedval | AGENT_SECRETS_UNATTENDED=1 bash '$REPO_ROOT/bin/agent-secrets' setup"
  [ "$status" -eq 0 ]
  run jq -r '.cleanupPeriodDays' "$AGENT_SECRETS_HOME/.claude/settings.json"
  [ "$output" = "14" ]
}

@test "rollback of a tool-created settings.json removes BOTH apiKeyHelper and cleanupPeriodDays (no residue)" {
  export AGENT_SECRETS_LIB="$REPO_ROOT/lib"
  # shellcheck source=/dev/null
  . "$REPO_ROOT/lib/common.sh"; . "$REPO_ROOT/lib/manifest.sh"; manifest_init
  local sj="$AGENT_SECRETS_HOME/settings.json" bak="$AGENT_SECRETS_HOME/nobak"
  printf '{"apiKeyHelper":"x","cleanupPeriodDays":14}\n' >"$sj"   # what _wire_tools creates
  manifest_record_edit "$sj" "$bak" apiKeyHelper created
  manifest_record_edit "$sj" "$bak" cleanupPeriodDays created     # the second surgical marker
  manifest_rollback >/dev/null
  [ ! -f "$sj" ]                                                  # reduced to {} → deleted, not orphaned
}

@test "setup does NOT touch cleanupPeriodDays in a PRE-EXISTING settings.json (respects the user's file)" {
  mkdir -p "$AGENT_SECRETS_HOME/.claude"
  printf '{"model":"opus"}\n' >"$AGENT_SECRETS_HOME/.claude/settings.json"    # user's own file, no cleanupPeriodDays
  run bash -c "printf '%s' seedval | AGENT_SECRETS_UNATTENDED=1 bash '$REPO_ROOT/bin/agent-secrets' setup"
  [ "$status" -eq 0 ]
  run jq -r '.cleanupPeriodDays // "unset"' "$AGENT_SECRETS_HOME/.claude/settings.json"
  [ "$output" = "unset" ]                                         # we did not inject an un-cleanly-revertable key
  run jq -r '.model' "$AGENT_SECRETS_HOME/.claude/settings.json"
  [ "$output" = "opus" ]                                          # user's key preserved
}

# ---- backup gh dependency chain (P1-5) ---------------------------------------------------------

@test "doctor backup row names the gh prerequisite when gh is present" {
  setup_store                                                     # gh mock IS on PATH → gh-present branch
  run bash "$REPO_ROOT/bin/agent-secrets" doctor
  [[ "$output" == *"off-machine backup"* ]] || return 1
  [[ "$output" == *"gh auth login"* ]] || return 1
}

@test "doctor onboarding category triages external-CLI readiness (full), hidden by --summary (optional tier)" {
  setup_store
  run bash "$REPO_ROOT/bin/agent-secrets" doctor
  [[ "$output" == *"[onboarding]"* ]] || return 1
  [[ "$output" == *"gh (GitHub CLI) — installed"* ]] || return 1   # gh mock is on PATH → present
  [[ "$output" == *"az (Azure CLI)"* ]] || return 1                # az triaged (checked nowhere else)
  # optional tier → the whole triage is hidden in the quiet post-setup view (no new ⚠ noise)
  run bash "$REPO_ROOT/bin/agent-secrets" doctor --summary
  [[ "$output" != *"[onboarding]"* ]] || return 1
}

@test "backup with gh absent points at the install recipe (help onboarding), not a bare doctor" {
  # A PATH without the gh mock (and no real gh in /usr/bin:/bin) → agsec_have gh is false.
  run env -i PATH=/usr/bin:/bin HOME="$HOME" AGENT_SECRETS_HOME="$AGENT_SECRETS_HOME" \
      AGENT_SECRETS_LIB="$REPO_ROOT/lib" AGENT_SECRETS_PLAIN=1 \
      bash "$REPO_ROOT/cmd/backup.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"help onboarding"* ]] || return 1
  [[ "$output" == *"gh auth login"* ]] || return 1
}
