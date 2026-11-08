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
  printf 'creation_rules:\n  - path_regex: secrets\\.env$\n    age: "%s"\n' "$recips" \
    | agsec_atomic_write "$sops_cfg" 600 || agsec_die "store_init: cannot write $sops_cfg"
  # manifest.toml header (values-free metadata; store_add appends rows).
  local man; man="$(agsec_manifest_toml)"
  [ -f "$man" ] || printf '# agent-secrets credential manifest (values-free)\n' >"$man"
  # Creates the encrypted store on first run (canary is the seed entry). An existing store we cannot
  # decrypt must not be mistaken for "no canary yet" and re-seeded.
  local crc=0; store_canary_insert || crc=$?
  [ "$crc" -ne 2 ] || agsec_die_undecryptable
  [ "$crc" -eq 0 ] || return "$crc"
  _store_export_key
}

# Upsert NAME with a one-line value from STDIN. Value never touches argv; plaintext is staged
# only in a 0600 temp under the config dir and shredded. Manifest row appended if absent.
store_add() {
  local name="${1:?store_add: NAME required}"
  case "$name" in [A-Za-z_]*[!A-Za-z0-9_]* | [!A-Za-z_]*) agsec_die "store_add: invalid name '$name'";; esac
  agsec_secure_umask
  # A line that ended in CRLF loses its CR (a stored trailing CR breaks any HTTP header it lands in);
  # a value read at EOF with no newline is kept byte for byte.
  local value=""; if IFS= read -r value; then value="${value%$'\r'}"; fi
  # Fail CLOSED on a multi-line value: a second line means the caller piped a multi-line/file secret to
  # `add`, which stores only the first line — a silent truncation reported as success. The extra line
  # lands in a shell var exactly as `value` already does (no new exposure) and is never printed.
  if IFS= read -r _rest || [ -n "${_rest:-}" ]; then
    unset value _rest
    agsec_die "add takes a SINGLE-LINE value (received more than one line). Multi-line secrets travel via share/receive; a single-line value is what 'run' can inject as an env var." 2
  fi
  # Fail CLOSED on an EMPTY value: a `curl … | bash` (EOF'd pipe) or a mis-piped caller would otherwise
  # store ANTHROPIC_API_KEY= silently and report "✓ stored", and apiKeyHelper would then feed Claude an
  # empty credential (auth breaks with no diagnostic). A real secret is never empty; the canary
  # placeholder + receive both pipe non-empty values, so this rejects only the accidental-empty case.
  if [ -z "$value" ]; then
    unset value
    # Inside an agent session the LOUD line must carry the real remedy (F7): pre-fix, "got end of
    # input" dominated while the actual fix — a real terminal, or piping from an EXISTING variable —
    # sat in add.sh's quiet note:. Same refusal, same exit code; only the diagnosis changed.
    if agsec_in_agent_session; then
      agsec_die "no value arrived on STDIN — this agent session has no usable TTY for a hidden prompt. Ask the USER to run 'agent-secrets add $name' in a real terminal, or pipe from an EXISTING variable/file (never a literal in the command)." 2
    fi
    # The feedback failure: a user pasted `printf '%s' "$YOUR_REAL_ANTHROPIC_KEY" | agent-secrets add …`
    # verbatim; the unset placeholder made stdin empty. Name the docs-literal cause AND the hidden-prompt
    # escape hatch (no pipe) — never just "got end of input", which reads as a plumbing bug.
    agsec_die "add takes a NON-EMPTY single-line value on STDIN (got end of input). If you copied a command from the docs, replace the placeholder (e.g. \$YOUR_REAL_KEY) with your real value first — or run 'agent-secrets add $name' with NO pipe for a hidden prompt." 2
  fi
  local recips; recips="$(_store_recipients)" || agsec_die "store_add: no age recipients (run setup)"
  local store lock plain new=""; store="$(agsec_store_file)"; lock="$(_store_lock_dir)"
  # Read-modify-write under one lock: two concurrent adds would otherwise each decrypt the same old
  # store and the second commit would drop the first one's name.
  _store_lock "agent-secrets add $name"
  plain="$(mktemp "$(agsec_config_dir)/.agsec.XXXXXX")" \
    || { agsec_unlock "$lock"; agsec_die "store_add: cannot create a temp file in $(agsec_config_dir)"; }
  # Shred the whole-store plaintext (+ transient copies) on a signal: without this, a signal between
  # decrypt and the final shred strands every secret VALUE in cleartext under the config dir.
  trap '_store_shred "$plain" "$plain.f" "$new"; agsec_unlock "$lock"; exit 130' INT
  trap '_store_shred "$plain" "$plain.f" "$new"; agsec_unlock "$lock"; exit 143' TERM
  trap '_store_shred "$plain" "$plain.f" "$new"; agsec_unlock "$lock"; exit 129' HUP
  if [ -f "$store" ]; then
    _store_decrypt >"$plain" 2>/dev/null || { _store_shred "$plain"; agsec_unlock "$lock"; agsec_die "store_add: cannot decrypt store (custody/key problem — run doctor)"; }
    { grep -v "^${name}=" "$plain" || true; } >"$plain.f"; mv -f "$plain.f" "$plain"
  fi
  printf '%s=%s\n' "$name" "$value" >>"$plain"
  unset value
  new="$(agsec_tmp_sibling "$store")" \
    || { _store_shred "$plain"; agsec_unlock "$lock"; agsec_die "store_add: cannot create a temp file next to $store"; }
  sops -e --input-type dotenv --output-type dotenv --age "$recips" "$plain" >"$new" \
    || { _store_shred "$plain" "$new"; agsec_unlock "$lock"; agsec_die "store_add: sops encrypt failed"; }
  _store_shred "$plain"
  agsec_commit "$new" "$store" 600 || { agsec_unlock "$lock"; agsec_die "store_add: cannot replace $store"; }
  _store_manifest_upsert "$name"
  # Traps first: a signal after the unlock must not remove a lock another process has since taken.
  trap - INT TERM HUP
  agsec_unlock "$lock"
}

_store_lock_dir() { printf '%s\n' "$(agsec_config_dir)/.store.lock"; }
# Every writer of the store or the manifest holds this lock. RECOVERY_CMD may be empty.
_store_lock() {  # RECOVERY_CMD
  agsec_lock "$(_store_lock_dir)" 10 && return 0
  agsec_fail conflict "Couldn't lock the store: another agent-secrets process is writing it." "${1:-}" "Retry"
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
  local lock; lock="$(_store_lock_dir)"; _store_lock ""
  local tmp; tmp="$(mktemp "$(agsec_config_dir)/.agsec.XXXXXX")" \
    || { agsec_unlock "$lock"; agsec_die "store_manifest_set_sharing: cannot create a temp file"; }
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
    rm -f "$tmp"; agsec_unlock "$lock"; agsec_die "store_manifest_set_sharing: manifest rewrite failed"
  fi
  agsec_unlock "$lock"
}

# Strip every sharing line from manifest.toml: shared_with / shared_at / direction, and any
# source = "received:*" line (a plain source = "sops:…" line is kept). Values-free. Used by
# uninstall keep-mode so the retained store carries no colleague social graph (design §3.8).
store_manifest_purge_sharing() {
  local man; man="$(agsec_manifest_toml)"; [ -f "$man" ] || return 0
  local lock; lock="$(_store_lock_dir)"; _store_lock ""
  local tmp; tmp="$(mktemp "$(agsec_config_dir)/.agsec.XXXXXX")" \
    || { agsec_unlock "$lock"; agsec_die "store_manifest_purge_sharing: cannot create a temp file"; }
  grep -vE '^(shared_with|shared_at|direction) = |^source = "received:' "$man" >"$tmp" || true
  mv -f "$tmp" "$man"
  agsec_unlock "$lock"
}

agsec_die_undecryptable() {
  agsec_fail undecryptable "Couldn't decrypt the store at $(agsec_store_file)." "agent-secrets doctor" "Check key custody"
}

# Names, one per line. rc 0 = listed (possibly none) · 1 = no store file yet · 2 = the store exists but
# can't be decrypted, which callers must not read as "empty". sed drains its input, so a non-zero
# PIPESTATUS[0] is sops's own failure, never SIGPIPE. Values stay inside the pipe.
store_names() {
  [ -f "$(agsec_store_file)" ] || return 1
  local err=/dev/null rc
  [ "${AGENT_SECRETS_DEBUG:-}" != 1 ] || err=/dev/stderr
  # In an `if` so set -e/pipefail callers still reach the PIPESTATUS read.
  if _store_decrypt 2>"$err" | sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\)=.*/\1/p'; then
    rc=${PIPESTATUS[0]}
  else
    rc=${PIPESTATUS[0]}
  fi
  [ "$rc" -eq 0 ] || return 2
}
# rc as store_names; -F so a '.' in NAME is not a wildcard.
store_has() {
  local want="${1:?store_has: NAME required}" hit
  hit="$(store_names)" || return $?
  printf '%s\n' "$hit" | grep -qxF -- "$want"
}

# Decrypt ONE entry to STDOUT — the JIT value-out (callers pipe into a helper, never a terminal).
store_extract() {
  local name="${1:?store_extract: NAME required}"
  _store_export_key
  sops -d --input-type dotenv --extract "[\"$name\"]" "$(agsec_store_file)"
}

# POSIX single-quote each argument and join with spaces. Parameter expansion, not $(sed): a command
# substitution would strip an argument's trailing newlines. The replacements are quoted variables
# because bash 3.2 and 5.x treat a backslash in an unquoted replacement differently.
_store_shquote() {
  local a out="" sq="'" rep="'\\''"
  for a in "$@"; do
    a=${a//"$sq"/"$rep"}
    out="$out '$a'"
  done
  printf '%s' "${out# }"
}

# Inject the store into a process env and exec CMD (process-scoped; dies with the process tree).
# sops exec-env runs its command as one `sh -c` string, so shell-quote argv into a single arg —
# otherwise flag-like args (e.g. `--resume`) are misparsed as sops's own options. --same-process plus
# the `exec` makes sops, then sh, become the child: no sops process waits in between.
store_exec() {
  [ "${1:-}" = "--" ] && shift
  [ "$#" -ge 1 ] || agsec_die "store_exec: usage: store_exec -- <cmd> [args...]"
  _store_export_key
  local cmd; cmd="exec $(_store_shquote "$@")"
  exec sops exec-env --same-process "$(agsec_store_file)" "$cmd"
}

# Like store_exec but does NOT replace this process: it starts the child in the background, sets
# AGSEC_CHILD_PID and returns. Used by egress_run, which must outlive the child to tear down the loopback
# proxy and to forward signals. The value still enters the child env only, never argv.
# - `<&0`: without job control bash points a background job's stdin at /dev/null; claude needs the TTY.
# - bash also starts a background job with SIGINT/SIGQUIT ignored, `trap -` cannot undo that, and an
#   ignored signal stays ignored across exec, so Ctrl-C would no longer reach the child. perl restores the
#   defaults and execs in place, so after perl → sops → sh every exec keeps the one pid in $!.
store_exec_managed() {
  [ "${1:-}" = "--" ] && shift
  [ "$#" -ge 1 ] || agsec_die "store_exec_managed: usage: store_exec_managed -- <cmd> [args...]"
  _store_export_key
  local cmd; cmd="exec $(_store_shquote "$@")"
  # shellcheck disable=SC2016  # $SIG and @ARGV belong to perl
  /usr/bin/perl -e '$SIG{INT} = $SIG{QUIT} = "DEFAULT"; exec { $ARGV[0] } @ARGV or exit 127' \
    sops exec-env --same-process "$(agsec_store_file)" "$cmd" <&0 &
  # shellcheck disable=SC2034  # read by egress_run
  AGSEC_CHILD_PID=$!
}

# Seed the in-store canary: a plausibly-named honeytoken entry a whole-store sweep grabs.
# rc 2 = the store exists but can't be decrypted; seeding then would overwrite every other entry.
store_canary_insert() {
  local rc=0
  store_has "$AGENT_SECRETS_CANARY_NAME" || rc=$?
  case "$rc" in 0) return 0 ;; 2) return 2 ;; esac
  printf '%s' "$AGENT_SECRETS_CANARY_PLACEHOLDER" | store_add "$AGENT_SECRETS_CANARY_NAME"
}
