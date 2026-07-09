# shellcheck shell=bash
# lib/keychain.sh — bootstrap age-key custody (Keychain primary + 0600 file fallback).
#
# Call `security` by BARE name so tests can shim it. Names-only.
kc_add()            { agsec_die "kc_add: not implemented"; }
kc_read()           { agsec_die "kc_read: not implemented"; }
age_key_cmd_path()  { agsec_die "age_key_cmd_path: not implemented"; }
kc_write_selector() { agsec_die "kc_write_selector: not implemented"; }
kc_status()         { agsec_die "kc_status: not implemented"; }
