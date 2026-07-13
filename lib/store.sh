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
_store_export_key() {
  SOPS_AGE_KEY_CMD="$(_store_keycmd_path)"; export SOPS_AGE_KEY_CMD
  # Belt-and-suspenders for an unexpectedly-OLD sops (SOPS_AGE_KEY_CMD landed in sops v3.10.0; the
  # feedback's BLOCKER #4 was a 3.9.4 that silently ignored KEY_CMD → the store looked "unreadable").
  # Also point at the 0600 key file: sops ≥3.11 pools every identity source and tolerates a failing
  # KEY_CMD, while a pre-3.10 sops ignores the unknown KEY_CMD and decrypts via KEY_FILE — so the store
  # stays readable across the whole sops version range. Our KEY_CMD selector always exits 0 (Keychain
  # || file), which also covers the fragile 3.10.0–3.10.2 early-return window. Same key either way.
  local _kf; _kf="$(agsec_age_key_file)"
  if [ -s "$_kf" ]; then SOPS_AGE_KEY_FILE="$_kf"; export SOPS_AGE_KEY_FILE; fi
}

# Age public recipients: primary (required) + recovery (optional). Public keys — safe in argv.
_store_recipients() {
  local pub rec out=""
  pub="$(agsec_age_pub_file)"; rec="$(agsec_config_dir)/recovery.pub"
  [ -s "$pub" ] || return 1
  out="$(tr -d '[:space:]' <"$pub")"
  [ -s "$rec" ] && out="$out,$(tr -d '[:space:]' <"$rec")"
  printf '%s\n' "$out"
}

# Overwrite-and-remove staged plaintext temps (FileVault gives cryptographic erasure on rm).
# Variadic so a signal trap can shred every temp (decrypted store, filtered copy, new ciphertext).
_store_shred() { local f; for f in "$@"; do [ -e "$f" ] && rm -f "$f"; done; return 0; }

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
  # Fail CLOSED on a multi-line value: a second line means the caller piped a multi-line/file secret to
  # `add`, which stores only the first line — a silent truncation reported as success. The extra line
  # lands in a shell var exactly as `value` already does (no new exposure) and is never printed.
  if IFS= read -r _rest || [ -n "${_rest:-}" ]; then
    unset value _rest
    agsec_die "add takes a SINGLE-LINE value (received more than one line). Multi-line secrets travel via share/receive; a single-line value is what 'run' can inject as an env var." 2
  fi
  local recips; recips="$(_store_recipients)" || agsec_die "store_add: no age recipients (run setup)"
  local store plain; store="$(agsec_store_file)"; plain="$(mktemp "$(agsec_config_dir)/.agsec.XXXXXX")"
  # Shred the whole-store plaintext (+ transient copies) on an interrupt: without this, a SIGINT
  # between decrypt and the final shred strands every secret VALUE in cleartext under the config dir.
  trap '_store_shred "$plain" "$plain.f" "$store.new"; exit 130' INT TERM
  if [ -f "$store" ]; then
    _store_decrypt >"$plain" 2>/dev/null || { _store_shred "$plain"; agsec_die "store_add: cannot decrypt store (custody/key problem — run doctor)"; }
    { grep -v "^${name}=" "$plain" || true; } >"$plain.f"; mv -f "$plain.f" "$plain"
  fi
  printf '%s=%s\n' "$name" "$value" >>"$plain"
  unset value
  sops -e --input-type dotenv --output-type dotenv --age "$recips" "$plain" >"$store.new" \
    || { _store_shred "$plain"; _store_shred "$store.new"; agsec_die "store_add: sops encrypt failed"; }
  mv -f "$store.new" "$store"; _store_shred "$plain"; trap - INT TERM
  _store_manifest_upsert "$name"
}

# Multi-line values (PEM/JSON blobs) are NOT supported in v0.1 and this REFUSES them. sops dotenv can't
# hold raw newlines; the base64-round-trip workaround corrupted the value across multiple paths — `run`
# needed a decode prelude (BSD-only `base64 -D`), `share` re-transmitted the base64 string (the recipient
# then injected base64, not the bytes), and the encoding flag was never cleared on a single-line
# overwrite. Rather than ship a subtly-broken encoding, the supported unit is a single-line secret
# injected as an env var; multi-line/file secrets are a v0.2 item (proper file materialization, not env
# encoding). Kept as a named function because receive.sh + tests reference it — it fails closed (exit 2).
store_add_multiline() {
  local name="${1:-}"
  agsec_die "multi-line secrets are not supported in ${AGENT_SECRETS_VERSION:-v0.1} — they cannot round-trip through run/share. Store a SINGLE-LINE value${name:+ for $name}, or keep a multi-line/file secret outside agent-secrets for now." 2
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

# In-place updater for the [[credential]] block whose `name = "NAME"`. For each FIELD=VALUE arg
# (shared_with|shared_at|direction|source), replace the existing `FIELD = "…"` line within that block
# if present, else append it at the end of the block's fields. Values-free (fingerprint + metadata,
# never a secret). Unlike _store_manifest_upsert (skip-if-exists) this MUTATES an existing row.
store_manifest_set_sharing() {
  local name="${1:?store_manifest_set_sharing: NAME required}"; shift
  [ "$#" -ge 1 ] || agsec_die "store_manifest_set_sharing: at least one FIELD=VALUE required"
  local man; man="$(agsec_manifest_toml)"; [ -f "$man" ] || return 0
  # Join FIELD=VALUE pairs with a US (0x1f) separator — awk -v rejects an embedded newline.
  local fields="" pair
  for pair in "$@"; do fields="${fields}${pair}"$'\037'; done
  local tmp; tmp="$(mktemp "$(agsec_config_dir)/.agsec.XXXXXX")"
  if awk -v target="$name" -v fields="$fields" '
    BEGIN{
      n=split(fields, arr, "\037")
      for(i=1;i<=n;i++){ if(arr[i]=="") continue
        eq=index(arr[i],"="); fk[substr(arr[i],1,eq-1)]=substr(arr[i],eq+1) }
    }
    function flush(   i,k,last,line,replaced){
      if(bn==0) return
      if(istarget){
        last=bn; while(last>0 && buf[last] ~ /^[[:space:]]*$/) last--
        for(i=1;i<=last;i++){
          line=buf[i]; replaced=0
          for(k in fk){ if(line ~ ("^"k" = ")){ print k" = \""fk[k]"\""; done[k]=1; replaced=1; break } }
          if(!replaced) print line
        }
        for(k in fk){ if(!(k in done)) print k" = \""fk[k]"\"" }
        for(i=last+1;i<=bn;i++) print buf[i]
      } else { for(i=1;i<=bn;i++) print buf[i] }
      bn=0; istarget=0; delete done
    }
    /^\[\[credential\]\]/{ flush() }
    {
      buf[++bn]=$0
      if($0 ~ /^name = "/){ nm=$0; sub(/^name = "/,"",nm); sub(/".*/,"",nm); if(nm==target) istarget=1 }
    }
    END{ flush() }
  ' "$man" >"$tmp"; then
    mv -f "$tmp" "$man"
  else
    rm -f "$tmp"; agsec_die "store_manifest_set_sharing: manifest rewrite failed"
  fi
}

# Strip every sharing line from manifest.toml: shared_with / shared_at / direction, and any
# source = "received:*" line (a plain source = "sops:…" line is kept). Values-free. Used by
# uninstall keep-mode so the retained store carries no colleague social graph (design §3.8).
store_manifest_purge_sharing() {
  local man; man="$(agsec_manifest_toml)"; [ -f "$man" ] || return 0
  local tmp; tmp="$(mktemp "$(agsec_config_dir)/.agsec.XXXXXX")"
  grep -vE '^(shared_with|shared_at|direction) = |^source = "received:' "$man" >"$tmp" || true
  mv -f "$tmp" "$man"
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

# Like store_exec but does NOT replace the process — runs the child in a subshell and RETURNS its exit
# code. Used by egress_run, which must outlive the child to tear down the loopback proxy (an exec would
# strand it). Same JIT injection + shell-quoting; the value still enters the child env only, never argv.
store_exec_managed() {
  [ "${1:-}" = "--" ] && shift
  [ "$#" -ge 1 ] || agsec_die "store_exec_managed: usage: store_exec_managed -- <cmd> [args...]"
  _store_export_key
  local cmd; printf -v cmd '%q ' "$@"
  sops exec-env "$(agsec_store_file)" "$cmd"
}

# Seed the in-store canary: a plausibly-named honeytoken entry a whole-store sweep grabs.
store_canary_insert() {
  store_has "$AGENT_SECRETS_CANARY_NAME" && return 0
  printf '%s' "$AGENT_SECRETS_CANARY_PLACEHOLDER" | store_add "$AGENT_SECRETS_CANARY_NAME"
}
