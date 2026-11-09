# shellcheck shell=bash
# lib/restore.sh — restore flow + returning-user fast path.
# setup.sh calls these. Names-only: the age key VALUE transits stdin/ui_read_secret, never echoed.

# fresh | installed | partial — for setup.sh's returning-user branch (screen 1).
restore_returning_user_check() {
  if [ -f "$(agsec_store_file)" ] && [ -x "$(agsec_bin_dir)/claude-agent" ]; then
    printf 'installed\n'
  elif [ -f "$(agsec_wizard_state)" ] || [ -f "$(agsec_age_key_file)" ]; then
    printf 'partial\n'
  else
    printf 'fresh\n'
  fi
}

# Re-onboard from the saved note + restored store copy: re-establish key custody, then verify the
# existing store decrypts. Age private key: STDIN if piped (testable), else ui_read_secret.
restore_flow() {
  agsec_secure_umask
  local key
  if agsec_stdin_is_tty; then
    # An age key file is MULTI-LINE (comment lines + the AGE-SECRET-KEY-1 line), so a single-line
    # ui_read_secret would capture only the leading comment. Read the whole paste hidden (stty -echo),
    # ended by Ctrl-D — the same full material kc_add expects.
    local _stty; _stty="$(stty -g 2>/dev/null || true)"
    # A signal mid-paste must not leave the terminal without echo. The handlers live in this function so
    # they see the local _stty; EXIT is not trapped because setup.sh owns that trap.
    trap '[ -n "$_stty" ] && stty "$_stty" 2>/dev/null; printf "\n" >&2; exit 130' INT
    trap '[ -n "$_stty" ] && stty "$_stty" 2>/dev/null; printf "\n" >&2; exit 143' TERM
    trap '[ -n "$_stty" ] && stty "$_stty" 2>/dev/null; printf "\n" >&2; exit 129' HUP
    stty -echo 2>/dev/null || true
    # Prompt after echo is off and the handlers are set, so nothing typed at the prompt is shown.
    ui_say "Paste your saved age private key (all lines), then press Ctrl-D:"
    key="$(cat)"
    [ -n "$_stty" ] && stty "$_stty" 2>/dev/null || true
    trap - INT TERM HUP
    printf '\n' >&2
  else
    key="$(cat)"   # full multi-line key material (age key files carry comment lines)
  fi
  [ -n "$key" ] || { agsec_warn "no key provided — cannot restore"; return 1; }
  printf '%s' "$key" | kc_add           # writes the 0600 fallback (+ best-effort Keychain)
  unset key
  kc_write_selector                     # SOPS_AGE_KEY_CMD target
  if [ ! -f "$(agsec_store_file)" ]; then
    agsec_warn "no store file present — restore the encrypted store copy first, then re-run"
    return 1
  fi
  if store_extract "$AGENT_SECRETS_CANARY_NAME" >/dev/null 2>&1; then
    agsec_receipt "restore verified — your store decrypts with the pasted key"
    return 0
  fi
  agsec_warn "restore could NOT decrypt the store — the pasted key may be wrong"
  return 1
}
