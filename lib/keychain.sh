# shellcheck shell=bash
# lib/keychain.sh — bootstrap age-key custody (Keychain primary + 0600 file fallback).
# Call `security` by BARE name so tests
# shim it. Names/status only — the age key VALUE transits STDIN in, and kc_read's stdout out.

# Store the age PRIVATE key (STDIN) under both custody sinks. The 0600 file is the guaranteed,
# clean, no-argv sink; the Keychain add mirrors it via the design's STDIN `-w` form (also honored
# by the test `security` shim).  ⚠️ On real macOS Sequoia the `security -w` no-argv path does NOT
# read STDIN — it prompts /dev/tty with a double-confirm — so the Keychain sink cannot be
# populated without argv (banned) or an interactive tty double-type.
# custody runs on the file fallback until a no-argv Keychain-write flow.
kc_add() {
  # Read the FULL key material from stdin — an age key file is multi-line (comment lines + the
  # AGE-SECRET-KEY line), so a single `read -r` would drop the actual key. `cat` preserves all of it.
  local key; key="$(cat)"
  agsec_secure_umask
  local f; f="$(agsec_age_key_file)"; mkdir -p "$(dirname "$f")"
  printf '%s' "$key" >"$f"; chmod 600 "$f" 2>/dev/null || true      # primary custody: 0600 file
  # Mirror into the login Keychain without the value in argv (STDIN form; -U to update).
  printf '%s' "$key" | security add-generic-password -U -a "${USER:-agent}" \
    -s "$AGENT_SECRETS_KC_SERVICE" -w >/dev/null 2>&1 || true
  unset key
}

# The age-key-cmd selector body: Keychain primary, 0600 file fallback. Value → STDOUT only
# (consumed by sops as SOPS_AGE_KEY_CMD). This exact line is materialized by kc_write_selector.
kc_read() {
  security find-generic-password -s "$AGENT_SECRETS_KC_SERVICE" -w 2>/dev/null \
    || cat "$(agsec_age_key_file)"
}

age_key_cmd_path() { printf '%s\n' "$(agsec_config_dir)/age-key-cmd.sh"; }

# Materialize kc_read as a standalone 0700 selector script (SOPS_AGE_KEY_CMD target). Absolute
# paths are baked so it resolves in sops's context regardless of cwd.
kc_write_selector() {
  agsec_secure_umask
  local path; path="$(age_key_cmd_path)"; mkdir -p "$(dirname "$path")"
  { printf '#!/bin/sh\n# agent-secrets age-key selector (Keychain primary, 0600 file fallback).\n'
    printf 'security find-generic-password -s "%s" -w 2>/dev/null \\\n' "$AGENT_SECRETS_KC_SERVICE"
    printf '  || cat "%s"\n' "$(agsec_age_key_file)"; } >"$path"
  chmod 700 "$path" 2>/dev/null || true
}

# Custody status for doctor — names/status ONLY, never the key.
kc_status() {
  if security find-generic-password -s "$AGENT_SECRETS_KC_SERVICE" -w >/dev/null 2>&1; then
    printf 'primary\n'
  elif [ -s "$(agsec_age_key_file)" ]; then
    printf 'degraded (file custody)\n'
  else
    printf 'missing\n'
  fi
}
