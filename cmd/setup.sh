#!/usr/bin/env bash
# cmd/setup.sh — onboarding wizard. Screens 1–7 (installer owns screen-0 consent).
# Interactive by default; AGENT_SECRETS_UNATTENDED=1 runs it non-interactively with fake values for
# tests (accepts defaults, file custody, skips the clipboard/paste steps). Idempotent:
# re-running never mints a second key. Names-only.
set -euo pipefail
. "${AGENT_SECRETS_LIB:?run via bin/agent-secrets}/common.sh"
# help guard — precede the agent-session refusal so `setup --help` self-documents
case "${1:-}" in -h|--help) . "$AGENT_SECRETS_LIB/help.sh"; agsec_help_render setup; exit 0 ;; esac
for _m in ui store keychain manifest restore; do . "$AGENT_SECRETS_LIB/$_m.sh"; done

UNATTENDED="${AGENT_SECRETS_UNATTENDED:-}"
STATE="$(agsec_wizard_state)"
_state() { mkdir -p "$(dirname "$STATE")"; printf '%s\n' "$1" >"$STATE"; }
_confirm() { [ -n "$UNATTENDED" ] && return 0; ui_confirm "$@"; }

_preflight() {
  if agsec_have fdesetup && fdesetup status 2>/dev/null | grep -q On; then ui_ok "FileVault on"
  else ui_warn "FileVault off — enable it for at-rest protection (guided, not silent)"; fi
  if agsec_have age && agsec_have sops; then ui_ok "age + sops present"; else ui_warn "age/sops missing — the installer bootstraps them"; fi
  if agsec_have gh; then ui_ok "gh present (enables: agent-secrets backup)"; else ui_say "  gh not present (optional — install it to use: agent-secrets backup)"; fi
}

_key_ceremony() {
  local cfg; cfg="$(agsec_config_dir)"; mkdir -p "$cfg"; chmod 700 "$cfg" 2>/dev/null || true
  local kf pf; kf="$(agsec_age_key_file)"; pf="$(agsec_age_pub_file)"
  # Idempotency gates on the PRIVATE key ALONE — age.pub is a non-secret recipient we can always
  # re-derive. Requiring BOTH wedged setup permanently: with age.key present but age.pub missing
  # (an interrupt between the two keygens, or the user deleting the "non-secret" pubkey), the guard
  # fell through to `age-keygen -o`, which REFUSES to overwrite the existing key (exit 1); the
  # `2>/dev/null` hid the error and `set -e` aborted the wizard silently → permanent onboarding lockout.
  if [ -s "$kf" ]; then
    # NOTE: do NOT sweep a lingering recovery.key here. The go-forward strand case is covered by the
    # EXIT trap below; sweeping on every re-onboard would delete a recovery key a user DELIBERATELY kept
    # (declined the "saved it offline?" confirm, which leaves it with a "delete it yourself" warning).
    [ -s "$pf" ] || age-keygen -y "$kf" >"$pf"      # re-derive the public recipient when it's absent
    ui_ok "key already exists — not minting a second one"; kc_write_selector; store_init; return 0
  fi
  if [ -f "$kf" ]; then rm -f "$kf"; fi             # clear a 0-byte/partial key from an interrupted mint (age-keygen -o is O_EXCL)
  # Strand guard: a store already present + no key = a restore scenario. Minting a NEW key here would
  # make that store permanently undecryptable — route the user to the restore path instead.
  if [ -s "$(agsec_store_file)" ]; then
    agsec_die "a store exists at $(agsec_store_file) but there is no key to decrypt it — run: agent-secrets setup --restore (paste your saved age key). Minting a new key would strand it."
  fi
  age-keygen -o "$kf"; chmod 600 "$kf"              # NO 2>/dev/null — a real keygen failure must surface, not silently abort
  age-keygen -y "$kf" >"$pf"
  # Same O_EXCL hardening as the primary key above: clear a stale/partial recovery.key so age-keygen -o
  # (which REFUSES to overwrite) can recreate it, and drop 2>/dev/null so a real keygen failure surfaces
  # instead of silently aborting the wizard under set -e (the exact wedge the primary key mint had).
  local rec="$cfg/recovery.key" rec_keep=0; [ -f "$rec" ] && rm -f "$rec"
  # Strand + clipboard guard: an interrupt anywhere in the ceremony below — ^C at the macOS Keychain
  # double-prompt, SIGTERM, or a set -e/agsec_die death — must never leave the recovery PRIVATE key on
  # disk OR the primary key on the clipboard. A single EXIT trap covers all three on bash 3.2 (verified);
  # %q-bake the path since the local is out of scope when the trap fires during unwind (project memory).
  # shellcheck disable=SC2064  # expand-NOW via the pre-built %q string is DELIBERATE (see above)
  trap "rm -f $(printf '%q' "$rec") 2>/dev/null; command -v pbcopy >/dev/null 2>&1 && printf '' | pbcopy 2>/dev/null || true" EXIT
  age-keygen -o "$rec"; age-keygen -y "$rec" >"$cfg/recovery.pub"
  kc_write_selector
  ui_ok "generated your key + a recovery key (the store encrypts to both)"
  if [ -z "$UNATTENDED" ]; then
    if agsec_have pbcopy; then pbcopy <"$(agsec_age_key_file)"; ui_say "Your PRIVATE key is on the clipboard — paste it into your password manager now."; fi
    _confirm "Saved it to your password manager?" y || ui_warn "save it before continuing — it's the only way to recover your secrets"
    ui_say "Paste back your PUBLIC key (age1...) from the note to confirm you saved it:"
    local pb; IFS= read -r pb || true
    if [ "$pb" = "$(cat "$(agsec_age_pub_file)")" ]; then ui_ok "verified"; else ui_warn "no match — the real check is the restore drill later"; fi
    if _confirm "Store the key in your login Keychain for prompt-free use? (paste it once)" y; then
      ui_say "Paste your key at the next hidden prompt:"
      if security add-generic-password -U -a "${USER:-agent}" -s "$AGENT_SECRETS_KC_SERVICE" -w 2>/dev/null; then
        manifest_record_keychain "$AGENT_SECRETS_KC_SERVICE" >/dev/null 2>&1 || true   # reversible: uninstall removes it
      else
        ui_warn "Keychain populate skipped — running on file custody (fully supported)"
      fi
    fi
    # Deliver the RECOVERY key (the store encrypts to recovery.pub, so the user MUST hold its private
    # half — without this the second recipient is permanently unusable). Mirror the primary-key handoff:
    # clipboard → password manager, then a confirm. This MUST come AFTER the Keychain block so the
    # primary key stays on the clipboard for its "paste it once" prompt; here it overwrites it.
    if agsec_have pbcopy; then pbcopy <"$rec"; ui_say "Your RECOVERY key is now on the clipboard — save it offline (password manager or a printed sheet)."
    else ui_say "Copy $rec to offline/printed storage now — it is removed once you confirm."; fi
    _confirm "Saved your RECOVERY key offline?" y || { rec_keep=1; ui_warn "recovery.key left at $rec — save it offline, then delete the file yourself"; }
    agsec_have pbcopy && printf '' | pbcopy    # scrub the recovery key off the clipboard
  fi
  [ "$rec_keep" -eq 1 ] || rm -f "$rec"        # remove the on-disk recovery key unless the user explicitly asked to keep it
  trap - EXIT                                  # deliberate cleanup done — disarm the strand/clipboard guard
  store_init
}

_first_secret() {
  local name val
  if [ -n "$UNATTENDED" ]; then
    name="${AGENT_SECRETS_SEED_NAME:-ANTHROPIC_API_KEY}"
    # Seed-value resolution that CANNOT hang (feedback BLOCKER #3): the old `val="$(cat)"` blocked on
    # `cat` forever when stdin was an OPEN-but-empty pipe (an agent session's inherited stdin never
    # sends EOF). Resolve in priority order, none of which blocks unboundedly:
    #   1. AGENT_SECRETS_SEED_VALUE env var (deterministic automation — no stdin plumbing needed)
    #   2. a single piped line, read with a BOUNDED timeout (works with or without a trailing newline;
    #      a 5s ceiling turns the old infinite hang into a fast fall-through)
    #   3. a fake placeholder (the test/CI default)
    if [ -n "${AGENT_SECRETS_SEED_VALUE:-}" ]; then
      val="$AGENT_SECRETS_SEED_VALUE"                 # set AND non-empty (an empty SEED_VALUE falls through)
    elif [ ! -t 0 ]; then
      IFS= read -r -t 5 val 2>/dev/null || true      # val is set even on EOF-without-newline; timeout ⇒ empty
      [ -n "$val" ] || val="unattended-placeholder-value"
    else
      val="unattended-placeholder-value"
    fi
    [ -n "$val" ] || val="unattended-placeholder-value"   # never feed store_add an empty value (it fail-closes)
    printf '%s' "$val" | store_add "$name"; unset val; ui_ok "stored $name"; return 0
  fi
  name="$(ui_menu 'Which secret first?' ANTHROPIC_API_KEY OPENAI_API_KEY 'custom')"
  if [ "$name" = custom ]; then printf 'name: ' >&2; IFS= read -r name || true; fi
  ui_read_secret "Value for $name" | store_add "$name"
  ui_ok "stored $name (value never shown)"
}

# Offer to ARM the breach canary. Until armed it is an inert decoy; arming = replacing the placeholder
# with a real tripwire token (e.g. from canarytokens.org) so a whole-store sweep trips the operator's
# own alert. Value via STDIN/ui_read_secret — names-only. Skipped in UNATTENDED (tests keep the decoy).
_arm_canary() {
  [ -n "$UNATTENDED" ] && return 0
  ui_say "The breach canary ($AGENT_SECRETS_CANARY_NAME) ships as an INERT decoy — it detects a"
  ui_say "whole-store sweep only once you arm it with a real tripwire token."
  if _confirm "Arm it now? (paste a token you minted at canarytokens.org, or skip)" n; then
    ui_read_secret "Paste your canary/tripwire token" | store_add "$AGENT_SECRETS_CANARY_NAME"
    ui_ok "canary armed — a whole-store sweep now trips your alert"
  else
    ui_say "Skipped — arm later with:  agent-secrets add $AGENT_SECRETS_CANARY_NAME  (doctor will remind you)."
  fi
}

_wire_tools() {
  local bindir; bindir="$(agsec_bin_dir)"; mkdir -p "$bindir"
  local w
  for w in claude-agent cursor-agent apiKeyHelper; do
    [ -f "$AGENT_SECRETS_ROOT/bin/$w" ] || continue
    # A pre-existing NON-symlink at the target is the USER'S own file — `ln -sf` would clobber it and
    # uninstall's `rm -f` on the `file` record would then finish the loss. Write-once backup + an `edit`
    # record so uninstall RESTORES it. The edit record is appended BEFORE the file record: rollback is
    # LIFO, so the symlink is removed first, then the user's file restored.
    if [ -f "$bindir/$w" ] && [ ! -L "$bindir/$w" ]; then
      local wbak; wbak="$(agsec_state_dir)/wrapper-$w.bak"; mkdir -p "$(dirname "$wbak")"
      [ -f "$wbak" ] || cp -p "$bindir/$w" "$wbak"      # WRITE-ONCE: a re-run must not overwrite the pristine backup
      manifest_record_edit "$bindir/$w" "$wbak" >/dev/null 2>&1 || true
    fi
    # Symlink (not copy) so the wrapper follows the link back to its sibling lib/ under the install root.
    ln -sf "$AGENT_SECRETS_ROOT/bin/$w" "$bindir/$w"
    manifest_record_file "$bindir/$w" >/dev/null 2>&1 || true
  done
  ui_ok "installed wrappers to $bindir"
  local sj; sj="$(agsec_home)/.claude/settings.json"
  if agsec_have jq; then
    mkdir -p "$(dirname "$sj")"
    local pre=1; [ -f "$sj" ] || pre=0            # existed BEFORE we touched it?
    [ "$pre" = 1 ] || printf '{}\n' >"$sj"
    local bak; bak="$(agsec_state_dir)/settings.json.bak"; mkdir -p "$(dirname "$bak")"
    if [ "$pre" = 1 ]; then
      [ -f "$bak" ] || cp "$sj" "$bak"            # WRITE-ONCE: a re-run must not overwrite the pristine backup
      manifest_record_edit "$sj" "$bak" apiKeyHelper >/dev/null 2>&1 || true
    else
      # We created settings.json → rollback DELETES it (restoring an empty {} would leave residue).
      manifest_record_edit "$sj" "$bak" apiKeyHelper created >/dev/null 2>&1 || true
    fi
    # Capture jq's exit: an INVALID pre-existing settings.json makes jq fail, mv is skipped, and — because
    # an &&-list is errexit-exempt — the old unconditional ui_ok printed a FALSE "wired" success and left
    # a settings.json.new residue. Only claim success when the write actually happened.
    if jq --arg h "$bindir/apiKeyHelper" '.apiKeyHelper=$h' "$sj" >"$sj.new" 2>/dev/null; then
      mv "$sj.new" "$sj"
      ui_ok "wired apiKeyHelper into settings.json (reversible)"
    else
      rm -f "$sj.new"
      ui_warn "could not wire apiKeyHelper — $sj is not valid JSON (fix it, then re-run: agent-secrets setup)"
    fi
  else
    ui_warn "jq missing — skipped wiring apiKeyHelper into settings.json; install jq (the installer vendors it), then re-run: agent-secrets setup"
  fi
  ui_say "The Dock Cursor stays secret-free on purpose — use 'cursor-agent' for agent work."
}

_done_screen() {
  ui_title "You're set up"
  ui_say "The 3 commands you'll use:"
  ui_say "  agent-secrets add <NAME>    — add a secret (value never shown)"
  ui_say "  agent-secrets run -- <cmd>  — run a command with secrets injected"
  ui_say "  agent-secrets doctor        — health check"
  ui_say "Off-machine backup: run  agent-secrets backup  (doctor tracks whether you have one)."
  # Custody hint lands HERE because this is the moment the user can act on it: on macOS Sequoia the
  # wizard's Keychain paste is skipped in any non-interactive pass, leaving file custody in effect.
  case "$(kc_status 2>/dev/null || true)" in
    degraded*)
      ui_say ""
      ui_say "Your key runs on the 0600-file fallback (fully supported). Restore prompt-free"
      ui_say "Keychain custody anytime, in a real terminal:  agent-secrets setup --keychain" ;;
  esac
  # Cursor has no file-based global-rules path, so this is the one manual step left; hand the user
  # the exact text at the exact moment instead of pointing at the README.
  ui_say ""
  ui_say "Cursor users — paste these once into Cursor Settings → Rules → User Rules"
  ui_say "(Claude Code is covered by the installer's opt-in ~/.claude/CLAUDE.md block):"
  ui_say "  - NEVER write a secret to a .env, export it in plaintext, or print a secret VALUE."
  ui_say "  - Run tools WITH secrets injected, process-scoped: agent-secrets run -- <cmd>"
  # shellcheck disable=SC2016  # literal $VALUE is the point — this is a paste-ready template
  ui_say '  - Add/update a secret via STDIN (never argv): printf %s "$VALUE" | agent-secrets add NAME'
  ui_say "  - Names/health/manifest: agent-secrets list · doctor · help --json"
  ui_say ""
  ui_say "Docs: https://github.com/renchris/agent-secrets"
}

# Re-run ONLY the Keychain populate step (v2 feedback R2). On macOS Sequoia
# `security add-generic-password -w` (no argv) does not read STDIN — it prompts /dev/tty with a
# double-confirm — so any non-interactive first run leaves custody on the 0600-file fallback and
# doctor reports "degraded (file custody)". This path restores PRIMARY (prompt-free Keychain)
# custody in a real terminal without re-running the whole wizard. The key value transits the
# clipboard and the hidden /dev/tty prompt only — never argv, stdout, or a transcript.
_keychain_screen() {
  ui_title "agent-secrets setup --keychain"
  local kf; kf="$(agsec_age_key_file)"
  [ -s "$kf" ] || agsec_die "no key on this machine yet — run: agent-secrets setup"
  if [ "$(kc_status)" = primary ]; then
    ui_ok "Keychain custody is already primary — prompt-free reads work; nothing to do"
    return 0
  fi
  if [ -z "$UNATTENDED" ]; then
    if agsec_have pbcopy; then
      # Scrub the private key off the clipboard on ANY exit — a ^C at the macOS double-prompt would
      # otherwise leave it there for the next paste/clipboard-history reader.
      trap 'printf "" | pbcopy 2>/dev/null || true' EXIT
      pbcopy <"$kf"; ui_say "Your key is on the clipboard — paste it at the hidden prompt (macOS asks twice)."
    else ui_say "Paste your age PRIVATE key (from your password manager) at the hidden prompt (macOS asks twice)."; fi
  fi
  if security add-generic-password -U -a "${USER:-agent}" -s "$AGENT_SECRETS_KC_SERVICE" -w 2>/dev/null; then
    manifest_record_keychain "$AGENT_SECRETS_KC_SERVICE" >/dev/null 2>&1 || true   # reversible: uninstall removes it
    [ -z "$UNATTENDED" ] && agsec_have pbcopy && printf '' | pbcopy; trap - EXIT
    if [ "$(kc_status)" = primary ]; then
      ui_ok "Keychain custody restored — primary (prompt-free reads)"
    else
      ui_warn "the Keychain write succeeded but the read-back still falls to the file — file custody remains (fully supported); re-run in Terminal.app to retry"
    fi
    return 0
  fi
  [ -z "$UNATTENDED" ] && agsec_have pbcopy && printf '' | pbcopy; trap - EXIT
  agsec_die "Keychain populate did not complete — file custody remains in effect (fully supported); retry in Terminal.app with: agent-secrets setup --keychain"
}

# Disaster recovery on a new machine: re-establish key custody from the saved age key + a restored
# store copy, verify decryption, then re-wire the tools. Runs BEFORE any key mint (restore_flow +
# _key_ceremony's strand guard never let a fresh key clobber the restored store).
_restore_screen() {
  ui_title "agent-secrets restore"
  ui_say "Restoring on a new machine. First copy your backed-up encrypted store to:"
  ui_say "  $(agsec_store_file)"
  ui_say "then paste your saved age private key to re-establish custody."
  restore_flow || agsec_die "restore did not complete — see the message above (copy your store copy into place, then re-run: agent-secrets setup --restore)"
  _wire_tools
  _done_screen
}

main() {
  local do_restore=0 do_keychain=0
  case "${1:-}" in
    --restore)  do_restore=1 ;;
    --keychain) do_keychain=1 ;;
  esac
  if [ -z "$UNATTENDED" ] && agsec_in_agent_session; then
    agsec_die "refusing the key ceremony inside an agent session (transcripts are secret-bearing) — run in a normal terminal (or AGENT_SECRETS_UNATTENDED=1 for a fake-value test)"
  fi
  agsec_secure_umask
  # --keychain and --restore legitimately read piped stdin (the key), so they run BEFORE this guard.
  if [ "$do_keychain" -eq 1 ]; then _keychain_screen; return 0; fi
  if [ "$do_restore" -eq 1 ]; then _restore_screen; _state 'done'; return 0; fi
  # The wizard reads secrets from hidden prompts on STDIN; with no terminal it would silently read EOF
  # and store an empty first secret (the `curl … | bash` failure). Hard-refuse instead — the installer
  # defers the ceremony to a real terminal, and UNATTENDED tests use fake values.
  if [ -z "$UNATTENDED" ] && [ ! -t 0 ]; then
    agsec_die "setup is an interactive ceremony but stdin is not a terminal — run 'agent-secrets setup' in a real terminal (or AGENT_SECRETS_UNATTENDED=1 for a fake-value test run)"
  fi
  ui_title "agent-secrets setup"
  case "$(restore_returning_user_check)" in
    installed) ui_say "agent-secrets is already set up."
      # Re-wire before the health check: after an uninstall(keep)→reinstall the wrappers are re-symlinked
      # but settings.json is NOT (that edit is owned by _wire_tools), so the fast path must re-wire or
      # Claude Code is left unwired while doctor reads healthy. _wire_tools is idempotent.
      if _confirm "Run a health check instead of re-onboarding?" y; then _wire_tools; exec bash "$AGENT_SECRETS_CMD/doctor.sh"; fi ;;
    partial) ui_say "A previous setup was interrupted — continuing (idempotent; your key is kept)." ;;
  esac
  ui_step 2 7 "Preflight";        _preflight;      _state preflight
  ui_step 3 7 "Your one key";     _key_ceremony;   _state key
  ui_step 4 7 "Your first secret";_first_secret;   _arm_canary; _state secret
  ui_step 5 7 "Wire your tools";  _wire_tools;     _state wired
  ui_step 6 7 "Health check";     bash "$AGENT_SECRETS_CMD/doctor.sh" || true
  ui_step 7 7 "Done";             _done_screen;    _state 'done'
}
main "$@"
