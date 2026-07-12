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
  if agsec_have gh; then ui_ok "gh present (optional)"; else ui_say "  gh not present (optional — only for the private store repo)"; fi
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
  age-keygen -o "$kf"; chmod 600 "$kf"              # NO 2>/dev/null — a real keygen failure must surface, not silently abort
  age-keygen -y "$kf" >"$pf"
  local rec="$cfg/recovery.key"; age-keygen -o "$rec" 2>/dev/null; age-keygen -y "$rec" >"$cfg/recovery.pub"
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
      security add-generic-password -U -a "${USER:-agent}" -s "$AGENT_SECRETS_KC_SERVICE" -w 2>/dev/null \
        || ui_warn "Keychain populate skipped — running on file custody (fully supported)"
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
    if [ ! -t 0 ]; then val="$(cat)"; else val="unattended-placeholder-value"; fi
    printf '%s' "$val" | store_add "$name"; unset val; ui_ok "stored $name"; return 0
  fi
  name="$(ui_menu 'Which secret first?' ANTHROPIC_API_KEY OPENAI_API_KEY 'custom')"
  if [ "$name" = custom ]; then printf 'name: ' >&2; IFS= read -r name || true; fi
  ui_read_secret "Value for $name" | store_add "$name"
  ui_ok "stored $name (value never shown)"
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
    mkdir -p "$(dirname "$sj")"; [ -f "$sj" ] || printf '{}\n' >"$sj"
    local bak; bak="$(agsec_state_dir)/settings.json.bak"; mkdir -p "$(dirname "$bak")"; cp "$sj" "$bak"
    jq --arg h "$bindir/apiKeyHelper" '.apiKeyHelper=$h' "$sj" >"$sj.new" && mv "$sj.new" "$sj"
    manifest_record_edit "$sj" "$bak" apiKeyHelper >/dev/null 2>&1 || true
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
  ui_say "Docs: README.md. Local-only store? keep a second copy (doctor warns if you don't)."
}

main() {
  if [ -z "$UNATTENDED" ] && agsec_in_agent_session; then
    agsec_die "refusing the key ceremony inside an agent session (transcripts are secret-bearing) — run in a normal terminal (or AGENT_SECRETS_UNATTENDED=1 for a fake-value test)"
  fi
  agsec_secure_umask
  ui_title "agent-secrets setup"
  case "$(restore_returning_user_check)" in
    installed) ui_say "agent-secrets is already set up."
      _confirm "Run a health check instead of re-onboarding?" y && exec bash "$AGENT_SECRETS_CMD/doctor.sh" ;;
    partial) ui_say "A previous setup was interrupted — continuing (idempotent; your key is kept)." ;;
  esac
  ui_step 2 7 "Preflight";        _preflight;      _state preflight
  ui_step 3 7 "Your one key";     _key_ceremony;   _state key
  ui_step 4 7 "Your first secret";_first_secret;   _state secret
  ui_step 5 7 "Wire your tools";  _wire_tools;     _state wired
  ui_step 6 7 "Health check";     bash "$AGENT_SECRETS_CMD/doctor.sh" || true
  ui_step 7 7 "Done";             _done_screen;    _state 'done'
}
main "$@"
