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
  local rec="$cfg/recovery.key"; [ -f "$rec" ] && rm -f "$rec"
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
    agsec_have pbcopy && printf '' | pbcopy
    ui_say "Move $cfg/recovery.key to offline/printed storage now; it's being removed from disk."
  fi
  rm -f "$rec"
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
    if [ -n "${AGENT_SECRETS_SEED_VALUE+x}" ]; then
      val="$AGENT_SECRETS_SEED_VALUE"
    elif [ ! -t 0 ]; then
      IFS= read -r -t 5 val 2>/dev/null || true      # val is set even on EOF-without-newline; timeout ⇒ empty
      [ -n "$val" ] || val="unattended-placeholder-value"
    else
      val="unattended-placeholder-value"
    fi
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
    jq --arg h "$bindir/apiKeyHelper" '.apiKeyHelper=$h' "$sj" >"$sj.new" && mv "$sj.new" "$sj"
    ui_ok "wired apiKeyHelper into settings.json (reversible)"
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
  ui_say "Docs: https://github.com/renchris/agent-secrets"
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
  local do_restore=0
  [ "${1:-}" = "--restore" ] && do_restore=1
  if [ -z "$UNATTENDED" ] && agsec_in_agent_session; then
    agsec_die "refusing the key ceremony inside an agent session (transcripts are secret-bearing) — run in a normal terminal (or AGENT_SECRETS_UNATTENDED=1 for a fake-value test)"
  fi
  agsec_secure_umask
  if [ "$do_restore" -eq 1 ]; then _restore_screen; _state 'done'; return 0; fi
  ui_title "agent-secrets setup"
  case "$(restore_returning_user_check)" in
    installed) ui_say "agent-secrets is already set up."
      _confirm "Run a health check instead of re-onboarding?" y && exec bash "$AGENT_SECRETS_CMD/doctor.sh" ;;
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
