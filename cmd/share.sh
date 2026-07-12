#!/usr/bin/env bash
# cmd/share.sh — `share <NAME> --to <recipient>`: encrypt ONE secret to a colleague's age key and print
# a paste-able v1 envelope. The don't-share ladder (lib/ladder.sh) runs FIRST; only its terminal rung
# produces the blob. Names-only: the value flows STDIN → `age` → armor, never into a var/argv/stdout.
set -euo pipefail
. "${AGENT_SECRETS_LIB:?run via bin/agent-secrets}/common.sh"
case "${1:-}" in -h|--help) . "$AGENT_SECRETS_LIB/help.sh"; agsec_help_render share; exit 0 ;; esac
# shellcheck source=lib/store.sh
. "$AGENT_SECRETS_LIB/store.sh"
# shellcheck source=lib/ladder.sh
. "$AGENT_SECRETS_LIB/ladder.sh"

# --- parse ----------------------------------------------------------------------
name="" to="" singleton="" verify="" sign="" rename=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --to)        [ "$#" -ge 2 ] || agsec_die "share: --to <recipient> is required" 2; to="$2"; shift 2 ;;
    --to=*)      to="${1#--to=}"; shift ;;
    --singleton) singleton=1; shift ;;
    --verify)    verify=1; shift ;;
    --sign)      sign=1; shift ;;
    --rename)    [ "$#" -ge 2 ] || agsec_die "share: --rename <NEW> requires a value" 2; rename="$2"; shift 2 ;;
    --rename=*)  rename="${1#--rename=}"; shift ;;
    -*)          agsec_die "share: unknown flag '$1'" 2 ;;
    *)           if [ -z "$name" ]; then name="$1"; else agsec_die "share: unexpected argument '$1'" 2; fi; shift ;;
  esac
done
[ -n "$name" ] || agsec_die "usage: agent-secrets share <NAME> --to <age1…|github:user|self> [--singleton] [--verify] [--sign] [--rename NEW]" 2
[ -n "$to" ]   || agsec_die "share: --to <recipient> is required" 2

# --- work area (0700; holds only the temp github keyfile + armor) ---------------
workdir="$(mktemp -d "${TMPDIR:-/tmp}/agsec-share.XXXXXX")"; chmod 700 "$workdir"
trap 'rm -rf "$workdir"' EXIT

# --- 2. agent-session refuse + interactive confirm source -----------------------
agsec_in_agent_session && agsec_die "share refuses inside an agent session (transcripts are secret-bearing)"
confirm_src="${AGSEC_CONFIRM_SRC:-/dev/tty}"
# The interactive-terminal requirement is the REAL agent-exfil boundary (design §3.10): an injected
# agent with no controlling tty hard-refuses HERE even after it strips CLAUDECODE. It is NOT gated by
# AGENT_SECRETS_UNATTENDED — that flag only auto-answers the y/N confirm (step 7), never this gate.
( : < "$confirm_src" ) 2>/dev/null || agsec_die "share needs an interactive terminal"

# --- 3. canary refuse (hard, no confirm) ----------------------------------------
[ "$name" = "$AGENT_SECRETS_CANARY_NAME" ] \
  && agsec_die "refusing to share the canary '$AGENT_SECRETS_CANARY_NAME' — sharing the tripwire poisons breach detection on both machines"

# Reject a syntactically-invalid NAME up front (store names are ^[A-Za-z_][A-Za-z0-9_]*$). Without
# this, a dot-for-underscore typo slips past store_has's grep (^NAME=, where '.' is a wildcard) and
# dies later with a raw sops/age error instead of a clean, fail-fast "no such secret".
case "$name" in
  [A-Za-z_]*[!A-Za-z0-9_]* | [!A-Za-z_]*) agsec_die "no such secret: $name" ;;
esac

# --- determine recipient kind (self vs other) for the ladder, cheaply -----------
pubfile="$(agsec_age_pub_file)"
self_key=""; [ -s "$pubfile" ] && self_key="$(tr -d '[:space:]' <"$pubfile")"
recipient_kind=other
if [ "$to" = self ]; then recipient_kind=self
elif [ -n "$self_key" ] && [ "$to" = "$self_key" ]; then recipient_kind=self; fi

# --- 4. ladder gate (R0–R4) BEFORE name resolution ------------------------------
ladder_gate "$name" "$recipient_kind" "$singleton" || exit 1

# --- 5. name-exists -------------------------------------------------------------
store_has "$name" || agsec_die "no such secret: $name"

# --- 6. resolve recipient -------------------------------------------------------
# recip = the recipient string we fingerprint + confirm; age_args = the `age` recipient flags.
recip=""; label="$to"; age_args=()
# Reject SSH certs + sk-FIDO2 hardware keys up front — age cannot use them, whatever the prefix.
case "$to" in
  *-cert-v01@*)        agsec_die "recipient is an SSH certificate — age needs a bare public key, not a cert; paste the underlying key or an age1… string" ;;
  sk-ssh-*|sk-ecdsa-*) agsec_die "recipient is an sk-FIDO2 hardware key — age cannot decrypt to it; ask for a native age1… recipient" ;;
esac
case "$to" in
  self)
    [ -n "$self_key" ] || agsec_die "share --to self: no local public key ($pubfile) — run: agent-secrets setup"
    recip="$self_key"; label="yourself"; recipient_kind=self; age_args=(-r "$recip") ;;
  github:*)
    ghuser="${to#github:}"
    [ -n "$ghuser" ] || agsec_die "share --to github:<user>: empty user"
    keyfile="$workdir/gh.keys"; usable="$workdir/gh.usable"
    ( umask 177; : >"$keyfile" )
    curl -fsSL "https://github.com/${ghuser}.keys" >"$keyfile" 2>/dev/null \
      || agsec_die "share: could not fetch https://github.com/${ghuser}.keys — check the handle, or paste an age1… recipient instead"
    # Keep only usable recipient lines (ssh pubkeys / age1); drop certs + sk-FIDO2.
    grep -E '^(ssh-(rsa|ed25519|ecdsa)|age1)' "$keyfile" 2>/dev/null \
      | grep -vE '(-cert-v01@|^sk-ssh-|^sk-ecdsa-)' >"$usable" || true
    [ -s "$usable" ] \
      || agsec_die "share: $ghuser has no age-usable public keys on GitHub (empty/cert/FIDO2-only) — ask them to run 'agent-secrets pubkey' and paste the age1… string"
    recip="$(cat "$usable")"; label="$ghuser"; age_args=(-R "$usable")
    agsec_warn ".keys returns ALL of $ghuser's authorized keys — the blob is decryptable by any of them; prefer a native age1… recipient" ;;
  age1*)
    recip="$to"; label="$to"; age_args=(-r "$recip") ;;
  ssh-*)
    recip="$to"; label="$to"; age_args=(-r "$recip") ;;
  *)
    agsec_die "share: unrecognized recipient '$to' — use an age1… string, github:<user>, or self" 2 ;;
esac

# fingerprint of the resolved recipient (round-trips the resolved key into the confirm; §4 paste-fidelity)
fingerprint="$(printf '%s' "$recip" | agsec_digest)"

# --- 7. the ONE confirm (from confirm_src; skipped only under AGENT_SECRETS_UNATTENDED) ---
if [ -z "${AGENT_SECRETS_UNATTENDED:-}" ]; then
  printf 'Share the VALUE of %s → "%s" (%s)? [y/N] ' "$name" "$label" "$fingerprint" >&2
  read -r _ans < "$confirm_src" || _ans=""
  case "$_ans" in [yY]*) : ;; *) agsec_die "aborted — nothing shared" ;; esac
fi

# --- 8. encrypt (value: STDIN → age → armor; never argv/var/stdout) -------------
armor="$workdir/blob.age"
store_extract "$name" | age "${age_args[@]}" -a >"$armor" \
  || agsec_die "share: age encryption failed"

# --- 9. digest over base64-DECODED ciphertext (reflow-stable) -------------------
digest="$(sed -n '/-----BEGIN AGE ENCRYPTED FILE-----/,/-----END AGE ENCRYPTED FILE-----/p' "$armor" \
  | sed '1d;$d' | base64 -D 2>/dev/null | agsec_digest)"

# --- advisory --verify readback (a second y/N over the value-blob digest) -------
if [ -n "$verify" ] && [ -z "${AGENT_SECRETS_UNATTENDED:-}" ]; then
  printf 'Read this digest to the recipient out-of-band; they must confirm it matches: %s\n  Proceed? [y/N] ' "$digest" >&2
  read -r _v < "$confirm_src" || _v=""
  case "$_v" in [yY]*) : ;; *) agsec_die "aborted — digest not confirmed" ;; esac
fi

# --- 10. emit the envelope inside a code fence ----------------------------------
env_name="${rename:-$name}"
printf 'Paste the WHOLE block below (including the ``` fences) into chat. The recipient runs:\n' >&2
printf '  agent-secrets receive\n\n' >&2
{
  printf '```\n'
  printf -- '-----BEGIN AGENT-SECRETS SHARE %s-----\n' "$AGSEC_SHARE_ENVELOPE_VERSION"
  printf 'name: %s\n' "$env_name"
  printf 'direction: sent\n'
  printf 'digest: %s\n' "$digest"
  cat "$armor"
  printf -- '-----END AGENT-SECRETS SHARE %s-----\n' "$AGSEC_SHARE_ENVELOPE_VERSION"
  printf '```\n'
}

# --- 12. --sign (opt-in, best-effort; no fail-closed) ---------------------------
# The signature is a detached SSH sig leg (design §3.4). It is emitted as a SEPARATE labeled block so
# it can never perturb the strict v1 envelope receive parses. Unavailable signing key → warn + proceed.
if [ -n "$sign" ]; then
  sigkey="${AGSEC_SIGN_KEY:-$(agsec_home)/.ssh/id_ed25519}"
  if agsec_have ssh-keygen && [ -f "$sigkey" ]; then
    sigfile="$workdir/blob.sig"
    if ssh-keygen -Y sign -n "share-v1@agent-secrets" -f "$sigkey" "$armor" >/dev/null 2>&1 \
       && [ -f "$armor.sig" ]; then
      mv -f "$armor.sig" "$sigfile"
      printf '\nSender signature (optional; the recipient verifies with ssh-keygen -Y verify):\n' >&2
      printf '```\n'; cat "$sigfile"; printf '```\n'
    else
      agsec_warn "--sign: ssh-keygen -Y sign failed — proceeding UNSIGNED (recipient sees 'sender unverified')"
    fi
  else
    agsec_warn "--sign: no usable signing key at $sigkey — proceeding UNSIGNED (recipient sees 'sender unverified')"
  fi
fi

# --- 11. manifest sharing row (real recipient only; self writes no row) ---------
if [ "$recipient_kind" != self ]; then
  store_manifest_set_sharing "$name" \
    shared_with="$fingerprint" shared_at="$(date +%F)" direction="sent" 2>/dev/null || true
fi

agsec_ok "encrypted $name → \"$label\" ($fingerprint) — envelope printed above (no auto-rotate)"
