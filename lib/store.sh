# shellcheck shell=bash
# lib/store.sh — sops+age secret store.
# Assumes common.sh is already sourced by the entry script. Names-only: store_extract and
# store_exec are the sole value-outs (JIT injection). No secret VALUE ever reaches stdout/log/argv.

# --- internal helpers -----------------------------------------------------------
# SOPS_AGE_KEY_CMD selector path (defined by keychain.sh::age_key_cmd_path; fall back to the
# frozen literal so store.sh works even when keychain.sh is not sourced — same value either way).
_store_keycmd_path() {
  if declare -F age_key_cmd_path >/dev/null 2>&1; then age_key_cmd_path
  else printf '%s\n' "$(agsec_config_dir)/age-key-cmd.sh"; fi
}
_store_export_key() { SOPS_AGE_KEY_CMD="$(_store_keycmd_path)"; export SOPS_AGE_KEY_CMD; }

# Age public recipients: primary (required) + recovery (optional). Public keys — safe in argv.
_store_recipients() {
  local pub rec out=""
  pub="$(agsec_age_pub_file)"; rec="$(agsec_config_dir)/recovery.pub"
  [ -s "$pub" ] || return 1
  out="$(tr -d '[:space:]' <"$pub")"
  [ -s "$rec" ] && out="$out,$(tr -d '[:space:]' <"$rec")"
  printf '%s\n' "$out"
}

# Overwrite-and-remove a staged plaintext temp (FileVault gives cryptographic erasure on rm).
_store_shred() { [ -e "${1:-}" ] || return 0; rm -f "$1"; }

# Decrypt the whole store to a plaintext dotenv on stdout (VALUES present — internal use only,
# never surfaced to a terminal; consumers are store_has/store_names/store_add which never echo).
_store_decrypt() {
  _store_export_key
  sops -d --input-type dotenv --output-type dotenv "$(agsec_store_file)"
}

# --- public interface --------------------------------------------------------
store_init() {
  agsec_secure_umask
  agsec_require age; agsec_require sops
  local cfg; cfg="$(agsec_config_dir)"; mkdir -p "$cfg"; chmod 700 "$cfg" 2>/dev/null || true
  local recips; recips="$(_store_recipients)" \
    || agsec_die "store_init: missing age public key $(agsec_age_pub_file) — wizard must write it first"
  case "$recips" in *,*) : ;; *) agsec_warn "recovery.pub absent — encrypting to the primary age key only";; esac
  # .sops.yaml (2 recipients) — the committed recipient record + interactive `sops` edit config.
  local sops_cfg; sops_cfg="$(agsec_sops_config)"
  { printf 'creation_rules:\n  - path_regex: secrets\\.env$\n    age: "%s"\n' "$recips"; } >"$sops_cfg"
  chmod 600 "$sops_cfg" 2>/dev/null || true
  # manifest.toml header (values-free metadata; store_add appends rows).
  local man; man="$(agsec_manifest_toml)"
  [ -f "$man" ] || printf '# agent-secrets credential manifest (values-free)\n' >"$man"
  store_canary_insert      # creates the encrypted store on first run (canary is the seed entry)
  _store_export_key
}

# Upsert NAME with a one-line value from STDIN. Value never touches argv; plaintext is staged
# only in a 0600 temp under the config dir and shredded. Manifest row appended if absent.
store_add() {
  local name="${1:?store_add: NAME required}"
  case "$name" in [A-Za-z_]*[!A-Za-z0-9_]* | [!A-Za-z_]*) agsec_die "store_add: invalid name '$name'";; esac
  agsec_secure_umask
  local value; IFS= read -r value || true
  local recips; recips="$(_store_recipients)" || agsec_die "store_add: no age recipients (run setup)"
  local store plain; store="$(agsec_store_file)"; plain="$(mktemp "$(agsec_config_dir)/.agsec.XXXXXX")"
  if [ -f "$store" ]; then
    _store_decrypt >"$plain" 2>/dev/null || { _store_shred "$plain"; agsec_die "store_add: cannot decrypt store (custody/key problem — run doctor)"; }
    { grep -v "^${name}=" "$plain" || true; } >"$plain.f"; mv -f "$plain.f" "$plain"
  fi
  printf '%s=%s\n' "$name" "$value" >>"$plain"
  unset value
  sops -e --input-type dotenv --output-type dotenv --age "$recips" "$plain" >"$store.new" \
    || { _store_shred "$plain"; _store_shred "$store.new"; agsec_die "store_add: sops encrypt failed"; }
  mv -f "$store.new" "$store"; _store_shred "$plain"
  _store_manifest_upsert "$name"
}

# Append a values-free manifest.toml row if NAME is not already present.
_store_manifest_upsert() {
  local name="$1" man rotate
  man="$(agsec_manifest_toml)"; [ -f "$man" ] || return 0
  grep -q "name = \"$name\"" "$man" 2>/dev/null && return 0
  rotate="$(date -v+"${AGENT_SECRETS_ROTATE_DAYS_DEFAULT}"d +%F 2>/dev/null || echo unknown)"
  { printf '\n[[credential]]\nname = "%s"\nplatform = ""\nsource = "sops:secrets.env"\n' "$name"
    printf 'scope = ""\nrotate_by = "%s"\nused_by = []\nsurface = ""\n' "$rotate"; } >>"$man"
}

store_has()   { _store_decrypt 2>/dev/null | grep -q "^${1:?store_has: NAME required}="; }
store_names() { _store_decrypt 2>/dev/null | sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\)=.*/\1/p'; }

# Decrypt ONE entry to STDOUT — the JIT value-out (callers pipe into a helper, never a terminal).
store_extract() {
  local name="${1:?store_extract: NAME required}"
  _store_export_key
  sops -d --input-type dotenv --extract "[\"$name\"]" "$(agsec_store_file)"
}

# Inject the store into a process env and exec CMD (process-scoped; dies with the process tree).
# sops exec-env runs its command as one `sh -c` string, so shell-quote argv into a single arg —
# otherwise flag-like args (e.g. `--resume`) are misparsed as sops's own options.
store_exec() {
  [ "${1:-}" = "--" ] && shift
  [ "$#" -ge 1 ] || agsec_die "store_exec: usage: store_exec -- <cmd> [args...]"
  _store_export_key
  local cmd; printf -v cmd '%q ' "$@"
  exec sops exec-env "$(agsec_store_file)" "$cmd"
}

# Seed the in-store canary: a plausibly-named honeytoken entry a whole-store sweep grabs.
store_canary_insert() {
  store_has "$AGENT_SECRETS_CANARY_NAME" && return 0
  printf '%s' "canarytoken-placeholder-replace-during-onboarding" | store_add "$AGENT_SECRETS_CANARY_NAME"
}
