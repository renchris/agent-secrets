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
  if [ -t 0 ]; then
    key="$(ui_read_secret 'Paste your saved age private key')"
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
    agsec_ok "restore verified — your store decrypts with the pasted key"
    return 0
  fi
  agsec_warn "restore could NOT decrypt the store — the pasted key may be wrong"
  return 1
}
