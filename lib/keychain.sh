# shellcheck shell=bash
# lib/keychain.sh — bootstrap age-key custody (Keychain primary + 0600 file fallback).
# Call `security` by BARE name so tests
# shim it. Names/status only — the age key VALUE transits STDIN in, and kc_read's stdout out.

# Populate the login Keychain from the 0600 key file, with NO argv, NO clipboard and NO tty.
#
# `security add-generic-password -w` with no value is a /dev/tty double-prompt on current macOS — it
# does not read STDIN — which is why custody used to fall to the file whenever nobody could type. But
# `security -i` reads its COMMAND LANGUAGE from stdin, and the -w value inside that command line is
# parsed by security itself: the key travels a pipe from an in-process read of the file into the
# security process, and is never in `ps`, on the clipboard, or on a terminal. Measured 2026-09-17 on
# macOS 15 against the real login Keychain with a throwaway service (docs/plans/
# AGENT_ENTRYPOINT_HEADLESS.md M3). This is what lets a headless `setup` end on PRIMARY custody, and
# what removed the invisible paste-twice screen from the human wizard.
#
# Only the AGE-SECRET-KEY line is stored, never the whole file: an age key file starts with comment
# lines, a one-line Keychain value holding `# created: …` decrypts nothing, and kc_read hands the
# Keychain value straight to sops as SOPS_AGE_KEY_CMD output (a bare identity line is what it wants).
#
# rc: 0 = item written AND custody reads back primary · 1 = written but the read-back still falls
# to the file · 2 = no usable key on disk, or the write itself failed.
kc_populate_stdin() {
  local kf line; kf="$(agsec_age_key_file)"
  [ -s "$kf" ] || return 2
  line="$(grep -m1 '^AGE-SECRET-KEY-' "$kf" 2>/dev/null)" || true
  [ -n "$line" ] || return 2
  if ! printf 'add-generic-password -U -a "%s" -s "%s" -w "%s"\n' "${USER:-agent}" \
        "$AGENT_SECRETS_KC_SERVICE" "$line" | security -i >/dev/null 2>&1; then
    unset line; return 2
  fi
  unset line
  # Record the item so uninstall reverts it by RECORD (with the exact-service scan as belt-and-suspenders).
  command -v manifest_record_keychain >/dev/null 2>&1 && manifest_record_keychain "$AGENT_SECRETS_KC_SERVICE" >/dev/null 2>&1 || true
  [ "$(kc_status)" = primary ] && return 0
  return 1
}

# Store the age PRIVATE key (STDIN) under both custody sinks: the 0600 file first (the guaranteed
# sink), then the Keychain mirror via kc_populate_stdin (best-effort — file custody is fully
# supported if the Keychain write does not take).
kc_add() {
  # Read the FULL key material from stdin — an age key file is multi-line (comment lines + the
  # AGE-SECRET-KEY line), so a single `read -r` would drop the actual key. `cat` preserves all of it.
  local key; key="$(cat)"
  agsec_secure_umask
  local f; f="$(agsec_age_key_file)"; mkdir -p "$(dirname "$f")"
  printf '%s' "$key" >"$f"; chmod 600 "$f" 2>/dev/null || true      # primary custody: 0600 file
  unset key
  kc_populate_stdin >/dev/null 2>&1 || true
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
