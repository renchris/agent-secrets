# shellcheck shell=bash
# lib/wire.sh — the ~/.claude/settings.json apiKeyHelper edit, in ONE place (setup + add call it).
# Sourced after common.sh, store.sh, keychain.sh, manifest.sh, ui.sh. Names-only: this file checks
# whether a NAME exists in the store; it never reads a value.
#
# WHY THE EDIT IS CONDITIONAL (measured 2026-09-17, docs/plans/AGENT_ENTRYPOINT_HEADLESS.md M4):
# Claude Code ranks `apiKeyHelper` ABOVE the claude.ai `/login` credential, and a helper that "exits
# with an error, times out, or prints nothing" fails every request with "Your apiKeyHelper script is
# failing". Our helper prints ANTHROPIC_API_KEY from the store — so wiring it while the store holds no
# such entry breaks Claude Code for every Max/OAuth user the moment setup finishes. The wizard used to
# do exactly that whenever the first secret was skipped. Now the edit happens only once the key is in
# the store, and `add ANTHROPIC_API_KEY` performs it the moment that becomes true.

# agsec_wire_apikeyhelper — wire settings.json to <bindir>/apiKeyHelper, reversibly (manifest edit
# record, write-once backup). Idempotent. Prints one line per outcome.
#   rc 0 = wired (now, or already) · 1 = deliberately not wired (no ANTHROPIC_API_KEY in the store, or
#   the helper wrapper is absent) · 2 = could not wire (jq missing, the store does not decrypt,
#   settings.json is not valid JSON or cannot be written, or another wiring held the lock too long)
agsec_wire_apikeyhelper() {
  local bindir helper sj rc=0; bindir="$(agsec_bin_dir)"; helper="$bindir/apiKeyHelper"
  sj="$(agsec_home)/.claude/settings.json"
  if [ ! -x "$helper" ]; then
    ui_warn "apiKeyHelper wrapper missing at $helper — re-run:  agent-secrets setup"
    return 1
  fi
  ( store_has ANTHROPIC_API_KEY ) >/dev/null 2>&1 || rc=$?
  if [ "$rc" -eq 2 ]; then
    ui_warn "can't read the store (decrypt failed) — run: agent-secrets doctor"
    return 2
  elif [ "$rc" -ne 0 ]; then
    ui_say "apiKeyHelper not wired: no ANTHROPIC_API_KEY in the store yet, so"
    ui_say "  Claude Code keeps using its own login. Storing one wires it:"
    ui_say "  agent-secrets add ANTHROPIC_API_KEY"
    return 1
  fi
  if ! agsec_have jq; then
    ui_warn "jq missing — cannot wire apiKeyHelper into settings.json."
    ui_say  "  Install jq (the installer vendors it), then re-run:  agent-secrets setup"
    return 2
  fi
  # setup and `add ANTHROPIC_API_KEY` can race on the same read-modify-write; the lock serializes them.
  local lock; lock="$(agsec_state_dir)/.settings.lock"
  mkdir -p "$(agsec_state_dir)"
  if ! agsec_lock "$lock" 10; then
    ui_warn "could not wire apiKeyHelper — another agent-secrets run is editing settings.json; re-run:  agent-secrets setup"
    return 2
  fi
  rc=0; _agsec_wire_settings "$helper" "$sj" || rc=$?
  agsec_unlock "$lock"
  return "$rc"
}

# The settings.json read-modify-write, called with the settings lock held. Same rc contract.
_agsec_wire_settings() {  # HELPER SETTINGS_JSON
  local helper="$1" sj="$2"
  mkdir -p "$(dirname "$sj")"
  if [ -f "$sj" ] && [ "$(jq -r '.apiKeyHelper // empty' "$sj" 2>/dev/null)" = "$helper" ]; then
    ui_ok "apiKeyHelper already wired into settings.json"
    return 0
  fi
  local pre=1; [ -f "$sj" ] || pre=0            # existed BEFORE we touched it?
  [ "$pre" = 1 ] || printf '{}\n' >"$sj"
  local bak; bak="$(agsec_state_dir)/settings.json.bak"; mkdir -p "$(dirname "$bak")"
  # $h is a jq variable bound by `jq --arg h` below — it MUST stay literal in the shell (single quotes),
  # so SC2016's "expand it" advice would be a bug here. Applies to the created-file variant too.
  # shellcheck disable=SC2016
  local jqprog='.apiKeyHelper=$h'
  if [ "$pre" = 1 ]; then
    [ -f "$bak" ] || cp "$sj" "$bak"            # WRITE-ONCE: a re-run must not overwrite the pristine backup
    manifest_record_edit "$sj" "$bak" apiKeyHelper >/dev/null 2>&1 || true
  else
    # We created settings.json → rollback DELETES it (restoring an empty {} would leave residue).
    manifest_record_edit "$sj" "$bak" apiKeyHelper created >/dev/null 2>&1 || true
    # On a file WE create, ALSO set cleanupPeriodDays=14 — clears the `hygiene ⚠ cleanupPeriodDays unset`
    # that fired immediately after setup, and caps how long ~/.claude transcripts (which can hold
    # secret-adjacent output) linger. Recorded as a SECOND surgical edit so rollback removes BOTH keys →
    # the created file reduces to {} and is deleted; a single-marker revert would leave
    # {"cleanupPeriodDays":14} orphaned. ONLY on create: never inject a second, less-cleanly-revertable
    # key into a settings.json the user already owns.
    manifest_record_edit "$sj" "$bak" cleanupPeriodDays created >/dev/null 2>&1 || true
    # shellcheck disable=SC2016  # $h is a jq --arg variable; keep it literal in the shell
    jqprog='.apiKeyHelper=$h | .cleanupPeriodDays=14'
  fi
  # Capture jq's exit: an INVALID pre-existing settings.json makes jq fail, and an unconditional ui_ok
  # would print a FALSE "wired" success. Only claim success when the write actually happened. The temp
  # file is a sibling and agsec_commit writes through a symlinked settings.json (dotfile managers).
  local tmp
  if ! tmp="$(agsec_tmp_sibling "$sj")"; then
    ui_warn "could not wire apiKeyHelper — can't create a temp file beside $sj"
    return 2
  fi
  if ! jq --arg h "$helper" "$jqprog" "$sj" >"$tmp" 2>/dev/null; then
    rm -f "$tmp"
    ui_warn "could not wire apiKeyHelper — not valid JSON:"
    ui_say  "  $sj"
    ui_say  "  Fix it, then re-run:  agent-secrets setup"
    return 2
  fi
  if ! agsec_commit "$tmp" "$sj"; then
    ui_warn "could not wire apiKeyHelper — can't write $sj"
    return 2
  fi
  ui_ok "wired apiKeyHelper into settings.json (recorded in the manifest)"
  return 0
}
