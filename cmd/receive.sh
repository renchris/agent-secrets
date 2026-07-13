#!/usr/bin/env bash
# cmd/receive.sh — `receive [--rename NEW] [--yes-i-reviewed]`: ingest a pasted v1 share envelope on
# STDIN, decrypt it to the local age key, and store it names-only. NOT env-gated (design §3.10): the
# protection is the /dev/tty confirm seam (an agent with no tty hits a hard-refuse), never the env guard.
# The blob occupies STDIN, so every confirm/re-prompt reads from ${AGSEC_CONFIRM_SRC:-/dev/tty} — an
# exhausted STDIN must never silently default the recipient/collision gate (design §3.7, load-bearing).
set -euo pipefail
. "${AGENT_SECRETS_LIB:?run via bin/agent-secrets}/common.sh"
case "${1:-}" in -h|--help) . "$AGENT_SECRETS_LIB/help.sh"; agsec_help_render receive; exit 0 ;; esac
# shellcheck source=lib/store.sh
. "$AGENT_SECRETS_LIB/store.sh"
# shellcheck source=lib/keychain.sh
. "$AGENT_SECRETS_LIB/keychain.sh"

# --- byte caps (design §3.7 dual caps) ------------------------------------------
AGSEC_RECEIVE_MAX_ENVELOPE=65536   # raw pasted envelope, capped BEFORE base64-decode
AGSEC_RECEIVE_MAX_CIPHERTEXT=32768 # decoded age ciphertext, capped BEFORE decrypt

# --- flags ----------------------------------------------------------------------
rename=""
yes_reviewed=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --rename) shift; rename="${1:-}"; [ -n "$rename" ] || agsec_die "--rename needs a NAME" 2;;
    --rename=*) rename="${1#--rename=}";;
    --yes-i-reviewed) yes_reviewed=1;;
    *) agsec_die "unknown flag: $1" 2;;
  esac
  shift
done
[ -f "$(agsec_store_file)" ] || agsec_die "no store yet — run: agent-secrets setup"

# --- confirm-source seam (design §3.7) ------------------------------------------
# Every human confirm reads from here — NOT STDIN (the blob occupies STDIN).
CONFIRM_SRC="${AGSEC_CONFIRM_SRC:-/dev/tty}"

# Openable-for-read test: a subshell open() catches both an unreadable path AND /dev/tty with no
# controlling terminal (ENXIO) — `[ -r /dev/tty ]` alone passes on the permission bits and lies.
_receive_src_openable() { ( exec 3<"$1" ) 2>/dev/null; }

# Read one y/N answer from the confirm source (never STDIN). No answer → treated as No.
_receive_confirm_yes() {
  local ans=""
  IFS= read -r ans <"$CONFIRM_SRC" 2>/dev/null || true
  case "$ans" in [Yy] | [Yy][Ee][Ss]) return 0 ;; *) return 1 ;; esac
}

# No usable confirm source and no CI escape → hard-refuse (never auto-default the gate).
if [ -z "$yes_reviewed" ] && ! _receive_src_openable "$CONFIRM_SRC"; then
  agsec_die "receive needs a controlling terminal (or pass --yes-i-reviewed for CI)"
fi

# --- ingest the blob from STDIN (mirror restore.sh:21-25) -----------------------
# The blob is envelope TEXT (not a secret value), so holding it in a var is fine; the decrypted VALUE
# is what must stay out of vars/argv (below). tty-vs-cat branch survives bracketed-paste corruption.
if [ -t 0 ]; then
  printf '%sPaste the share envelope, then press Ctrl-D:%s\n' "$C_DIM" "$C_RESET" >&2
  blob="$(cat)"
else
  blob="$(cat)"
fi

# --- cap 1: raw envelope BEFORE decode ------------------------------------------
raw_bytes="$(printf '%s' "$blob" | wc -c | tr -d ' ')"
[ "$raw_bytes" -le "$AGSEC_RECEIVE_MAX_ENVELOPE" ] \
  || agsec_die "envelope too large ($raw_bytes bytes > $AGSEC_RECEIVE_MAX_ENVELOPE) — refusing before decode"

# --- parse + version-check (design §3.2 EXACT format) ---------------------------
ver="$(printf '%s\n' "$blob" | sed -n 's/^-----BEGIN AGENT-SECRETS SHARE \(.*\)-----$/\1/p' | head -1)"
[ -n "$ver" ] || agsec_die "unknown or unsupported share envelope"
[ "$ver" = "$AGSEC_SHARE_ENVELOPE_VERSION" ] || agsec_die "unknown or unsupported share envelope"
printf '%s\n' "$blob" | grep -q '^-----END AGENT-SECRETS SHARE '"$AGSEC_SHARE_ENVELOPE_VERSION"'-----$' \
  || agsec_die "unknown or unsupported share envelope"

env_name="$(printf '%s\n' "$blob" | sed -n 's/^name: //p' | head -1)"
embedded_digest="$(printf '%s\n' "$blob" | sed -n 's/^digest: //p' | head -1)"

# Age armor WITH its BEGIN/END markers (age -d needs them) + the base64 body alone (for the digest).
armor="$(printf '%s\n' "$blob" | sed -n '/^-----BEGIN AGE ENCRYPTED FILE-----$/,/^-----END AGE ENCRYPTED FILE-----$/p')"
printf '%s\n' "$armor" | grep -q '^-----BEGIN AGE ENCRYPTED FILE-----$' \
  || agsec_die "unknown or unsupported share envelope"
printf '%s\n' "$armor" | grep -q '^-----END AGE ENCRYPTED FILE-----$' \
  || agsec_die "unknown or unsupported share envelope"
# base64 body alone = the armor with its BEGIN/END markers stripped (first + last line).
body="$(printf '%s\n' "$armor" | sed '1d;$d')"

# Effective NAME: --rename wins, else the envelope name.
name="${rename:-$env_name}"
[ -n "$name" ] || agsec_die "envelope has no name and no --rename given"
case "$name" in
  [A-Za-z_]*[!A-Za-z0-9_]* | [!A-Za-z_]*) agsec_die "invalid name '$name' — use letters, digits, underscore (start with a letter/_)";;
esac

# --- secure temps + shred-on-every-exit (design §3.7: value/key never persist) --
# Register the plaintext/key temps with an EXIT trap up front: a SIGINT or a store_add agsec_die
# (sops-encrypt failure, custody race) must never strand the decrypted VALUE or the age private key
# on disk. mktemp lands them in the 0700 config dir under a 0077 umask.
agsec_secure_umask
dbody=""; idf=""; armor_tmp=""; pt=""
trap 'rm -f "$dbody" "$idf" "$armor_tmp" "$pt" 2>/dev/null' EXIT

# --- decode the age body ONCE (binary → temp; NUL-safe single decode) -----------
# base64 -D fails on chat-mangled armor (a stray non-base64 byte); route THAT to the same curated
# fail-closed message age -d emits — never a silent `set -e` abort (a bare command-substitution
# assignment would swallow the failure and exit 1 with no diagnostic).
dbody="$(mktemp "$(agsec_config_dir)/.agsec.XXXXXX")"; chmod 600 "$dbody"
printf '%s\n' "$body" | base64 -D >"$dbody" 2>/dev/null \
  || agsec_die "could not decrypt — the envelope may be corrupt or not encrypted to your key"

# --- local digest recompute (design §3.4) over the decoded ciphertext bytes -----
# Reflow-stable, advisory ONLY: compare it to the block's own `digest:` line (a paste-integrity
# check); a sender running `share --verify` reads this same value to you out-of-band.
local_digest="$(agsec_digest <"$dbody")"
agsec_note "digest $local_digest — matches the 'digest:' line in the block you pasted (a --verify sender reads it aloud)"
if [ -n "$embedded_digest" ] && [ "$embedded_digest" != "$local_digest" ]; then
  agsec_warn "envelope digest hint ($embedded_digest) differs from the locally computed value — possible corruption"
fi

# --- cap 2: decoded ciphertext BEFORE decrypt -----------------------------------
dec_bytes="$(wc -c <"$dbody" | tr -d ' ')"
[ "$dec_bytes" -le "$AGSEC_RECEIVE_MAX_CIPHERTEXT" ] \
  || agsec_die "ciphertext too large ($dec_bytes bytes > $AGSEC_RECEIVE_MAX_CIPHERTEXT) — refusing before decrypt"

# --- sender-auth (design §3.4; unsigned allowed, loud warning) ------------------
agsec_warn "sender unverified — you are trusting whoever pasted this"

# --- canary refuse (hard, no confirm — runs even under --yes-i-reviewed) --------
[ "$name" != "$AGENT_SECRETS_CANARY_NAME" ] \
  || agsec_die "refusing to receive the in-store canary name ($AGENT_SECRETS_CANARY_NAME) — sharing the tripwire poisons whole-store-sweep detection"

# --- existing-NAME hard-stop (design §3.7) --------------------------------------
if store_has "$name"; then
  if [ -n "$yes_reviewed" ]; then
    agsec_die "$name already exists — refusing to overwrite under --yes-i-reviewed (use --rename NEW)"
  fi
  agsec_warn "$name already exists in your store — overwrite?"
  _receive_confirm_yes || agsec_die "aborted — $name left unchanged (use --rename NEW to keep both)"
fi

# --- decrypt → store (names-only; value never in a shell var/argv) --------------
# umask + the EXIT trap covering dbody/idf/armor_tmp/pt are already in place (above).
idf="$(mktemp "$(agsec_config_dir)/.agsec.XXXXXX")"; chmod 600 "$idf"
kc_read >"$idf" 2>/dev/null || agsec_die "no local age key available — run: agent-secrets setup"
armor_tmp="$(mktemp "$(agsec_config_dir)/.agsec.XXXXXX")"; chmod 600 "$armor_tmp"
printf '%s\n' "$armor" >"$armor_tmp"
pt="$(mktemp "$(agsec_config_dir)/.agsec.XXXXXX")"; chmod 600 "$pt"

# stderr discipline (design §3.7): discard raw age/sops diagnostics (a corrupt blob's fragments can
# leak into agent-readable scrollback) and emit ONE curated fail-closed message.
if ! age -d -i "$idf" "$armor_tmp" 2>/dev/null >"$pt"; then
  agsec_die "could not decrypt — the envelope may be corrupt or not encrypted to your key"
fi
rm -f "$idf" "$armor_tmp" "$dbody"; idf=""; armor_tmp=""; dbody=""

# v0.1 stores SINGLE-LINE values only — a value is injected as an env var, and multi-line values do not
# round-trip through run/share (multi-line/file secrets are a v0.2 item). Refuse a multi-line envelope
# here; the EXIT trap shreds the decrypted 0600 temp on the die, so no plaintext persists.
nl_count="$(tr -dc '\n' <"$pt" | wc -c | tr -d ' ')"
trailing=0
if [ -s "$pt" ] && [ "$(tail -c1 "$pt" | wc -l | tr -d ' ')" -eq 1 ]; then trailing=1; fi
effective_nl=$(( nl_count - trailing ))
if [ "$effective_nl" -ge 1 ]; then
  agsec_die "this envelope carries a MULTI-LINE value (e.g. a PEM/JSON blob); agent-secrets ${AGENT_SECRETS_VERSION} stores single-line secrets only — they inject as env vars and multi-line values don't round-trip through run/share. Ask the sender for a single-line secret, or handle this key outside agent-secrets for now." 2
fi
store_add "$name" <"$pt"
rm -f "$pt"; pt=""

# --- manifest (design §3.8; values-free) ----------------------------------------
store_manifest_set_sharing "$name" direction="received" source="received:peer"

agsec_ok "received $name (value never shown)"
