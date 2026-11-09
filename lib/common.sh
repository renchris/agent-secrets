# shellcheck shell=bash
# shellcheck disable=SC2034  # sourced library: constants/colors are consumed by cmd/*.sh + wrappers
# lib/common.sh — shared foundation for agent-secrets.
# Sourced by bin/agent-secrets, every cmd/*.sh, and the wrappers.
# Stable interface: consume these helpers; do not redefine them in callers.
#
# HARD CONTRACT (enforced centrally here):
#   * Names-only. No function in this file ever writes a secret VALUE to stdout,
#     stderr, a log, or any file outside the sops-encrypted store.
#   * Synthetic-HOME. Every user path derives from agsec_home(); tests/recordings
#     set AGENT_SECRETS_HOME to an isolated dir so nothing touches the real HOME,
#     username, or secret-name set.

# Sourced library: do NOT `set -e`/`set -u` here (would leak into callers).
set -o pipefail 2>/dev/null || true

# Vendored dependency binaries (age/sops/gum/jq fetched without Homebrew by lib/deps.sh) live at
# <install-root>/vendor/bin. Prepend it here — common.sh is sourced by the dispatcher, every cmd/*.sh,
# AND all three wrappers — so those binaries are found at runtime WITHOUT editing bin/. common.sh is at
# <root>/lib/common.sh, so vendor/bin is a sibling of lib/. Idempotent; only prepends when it exists
# (a Homebrew/PATH toolchain never creates it, so this is a no-op for the classic install).
# AGSEC_SELF_ROOT is the install root resolved from THIS file's own location. It is kept (not
# unset) because it is the ONLY root available to a caller that sources common.sh directly without
# going through the dispatcher — install.sh does exactly that, and under `set -u` a bare
# ${AGENT_SECRETS_LIB} reference there aborted with "unbound variable" mid-way through the consent
# preview, AND blanked the version field of every rule block it wrote (doctor could then never
# match the marker). See agsec_root() below.
AGSEC_SELF_ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]:-$0}")/.." >/dev/null 2>&1 && pwd)"
if [ -n "${AGSEC_SELF_ROOT:-}" ] && [ -d "$AGSEC_SELF_ROOT/vendor/bin" ]; then
  case ":$PATH:" in
    *":$AGSEC_SELF_ROOT/vendor/bin:"*) : ;;
    *) PATH="$AGSEC_SELF_ROOT/vendor/bin:$PATH"; export PATH ;;
  esac
fi

# Disable sops's online "is this the latest?" update-check. By default `sops --version` calls
# api.github.com with NO client timeout, so on a locked-down corporate network (the exact target — the
# firewall may allow the release CDN but black-hole api.github.com) every version probe hangs 60-120s:
# in deps.sh's version gate + verify-by-exec, and in `doctor`'s toolchain check. This env var (honored
# by every sops that ships the check) makes `--version` return instantly; runtime decrypt calls never
# checked anyway. Unknown to an ancient sops → harmlessly ignored. Exported so child sops calls inherit it.
export SOPS_DISABLE_VERSION_CHECK=1

# VERSION is the single source; this literal is only the never-empty fallback. The dispatcher prints
# $AGENT_SECRETS_VERSION after sourcing this file. Keep this the only unindented assignment:
# tests/common.bats seds for exactly one such line.
AGENT_SECRETS_VERSION="0.1.3"
_agsec_v=""
if [ -r "${AGSEC_SELF_ROOT:-}/VERSION" ]; then
  { IFS= read -r _agsec_v || [ -n "$_agsec_v" ]; } <"${AGSEC_SELF_ROOT:-}/VERSION" || _agsec_v=""
  [ -z "$_agsec_v" ] || AGENT_SECRETS_VERSION="$_agsec_v"
fi
unset _agsec_v
AGENT_SECRETS_KC_SERVICE="agent-age-key"              # Keychain service: the bootstrap age key (uninstall purges this EXACT service)
AGENT_SECRETS_CANARY_NAME="AWS_BACKUP_ACCESS_KEY_ID"  # in-store canary (plausible name)
# The canary ships as this INERT decoy value — it provides breach detection only after the operator
# ARMS it by replacing the value with a real tripwire token (e.g. a canarytokens.org token bound to
# their own alert). setup offers to arm it; doctor warns while it is still the placeholder.
AGENT_SECRETS_CANARY_PLACEHOLDER="canary-INERT-arm-me-with-a-real-tripwire-token"
# The value the UNATTENDED wizard seeds when no real value is piped (tests/CI). A single source of
# truth so setup writes it and doctor can recognize it — flagging a store still holding this fake so
# apiKeyHelper never silently feeds a placeholder credential (a non-empty value passes the naive
# "returns a credential" check). Names-only: comparing against this known constant leaks nothing.
AGENT_SECRETS_UNATTENDED_PLACEHOLDER="unattended-placeholder-value"
AGENT_SECRETS_ROTATE_DAYS_DEFAULT=180                 # age key rotation cadence
AGSEC_SHARE_ENVELOPE_VERSION="v1"                     # colleague-share envelope; receive rejects unknown versions
AGENT_SECRETS_DISCOVERY_MARKER="agent-secrets"        # marker for the opt-in ~/.claude/CLAUDE.md discovery block (install writes, doctor greps, uninstall strips)

# --- Home / path resolution (synthetic-HOME aware) ------------------------------
agsec_home()            { printf '%s\n' "${AGENT_SECRETS_HOME:-$HOME}"; }
agsec_config_dir()      { printf '%s\n' "$(agsec_home)/.config/secrets"; }
agsec_store_file()      { printf '%s\n' "$(agsec_config_dir)/secrets.env"; }
agsec_manifest_toml()   { printf '%s\n' "$(agsec_config_dir)/manifest.toml"; }
agsec_age_key_file()    { printf '%s\n' "$(agsec_config_dir)/age.key"; }   # 0600 fallback custody
agsec_age_pub_file()    { printf '%s\n' "$(agsec_config_dir)/age.pub"; }   # public recipient (non-secret)
agsec_sops_config()     { printf '%s\n' "$(agsec_config_dir)/.sops.yaml"; }
agsec_state_dir()       { printf '%s\n' "$(agsec_home)/.local/state/agent-secrets"; }
agsec_install_manifest(){ printf '%s\n' "$(agsec_state_dir)/install-manifest.json"; }
agsec_wizard_state()    { printf '%s\n' "$(agsec_state_dir)/wizard-state.json"; }
agsec_bin_dir()         { printf '%s\n' "$(agsec_home)/bin"; }

# Status glyphs (✓/⚠/✗) — available before ui.sh is sourced. These are a command's RESULT rows (doctor,
# smoke), so they stay on stdout; a receipt of something done goes to stderr.
agsec_ok()   { printf '%s\n' "${C_GREEN}✓${C_RESET} $*"; }
agsec_attn() { printf '%s\n' "${C_YELLOW}⚠${C_RESET} $*"; }
agsec_bad()  { printf '%s\n' "${C_RED}✗${C_RESET} $*"; }
agsec_receipt()      { printf '%s\n' "${E_GREEN}✓${E_RESET} $*" >&2; }
agsec_receipt_attn() { printf '%s\n' "${E_YELLOW}⚠${E_RESET} $*" >&2; }
agsec_receipt_bad()  { printf '%s\n' "${E_RED}✗${E_RESET} $*" >&2; }

# --- Logging (names/digests only — NEVER values), all to STDERR -----------------
agsec_log()  { printf '%s\n' "$*" >&2; }
agsec_note() { printf '%s%s%s\n' "$E_DIM" "$*" "$E_RESET" >&2; }
agsec_plan() { printf '%s\n' "$*" >&2; }   # previews, consequences, prompts: never faint
agsec_warn() { printf '%s\n' "${E_YELLOW}WARN${E_RESET} $*" >&2; }

# --- Errors: one registry, one renderer, text or JSON -----------------------------
# `:-` so a cmd script re-sourcing this file keeps what the dispatcher's scan already decided.
AGSEC_OUTPUT="${AGSEC_OUTPUT:-text}"
AGSEC_WARNINGS="${AGSEC_WARNINGS:-}"   # comma-joined objects: "[$AGSEC_WARNINGS]" is the warnings array

# Call before parsing, so even a usage error comes out in the right format. `--format json` (space) is
# deliberately not recognized: no command accepts that spelling.
agsec_scan_json() {
  local a
  for a in "$@"; do
    case "$a" in
      --) return 0 ;;
      --json|--format=json) AGSEC_OUTPUT=json ;;
    esac
  done
  return 0
}

# Pure bash so doctor and the error document never need jq. The replacements stay quoted variables:
# unquoted, bash 5.x drops the backslash (measured on 5.3) while 3.2 keeps it.
# shellcheck disable=SC2059  # the format is the \xHH escape being built
agsec_js() {
  local s="${1:-}" bs=\\ dq=\" rep c hex
  rep="$bs$bs";  s=${s//"$bs"/"$rep"}
  rep="$bs$dq";  s=${s//"$dq"/"$rep"}
  rep="${bs}n";  s=${s//$'\n'/"$rep"}
  rep="${bs}r";  s=${s//$'\r'/"$rep"}
  rep="${bs}t";  s=${s//$'\t'/"$rep"}
  rep="${bs}b";  s=${s//$'\b'/"$rep"}
  rep="${bs}f";  s=${s//$'\f'/"$rep"}
  for hex in 01 02 03 04 05 06 07 0b 0e 0f 10 11 12 13 14 15 16 17 18 19 1a 1b 1c 1d 1e 1f 7f; do
    printf -v c "\\x$hex"
    rep="${bs}u00$hex"; s=${s//"$c"/"$rep"}
  done
  printf '%s' "$s"
}

# Prints "<exit> <status>". undecryptable, not_found, conflict, network, partial and error take the default.
_agsec_reason() {
  case "${1:-}" in
    usage|missing_command)               printf '2 error\n' ;;
    missing_input|confirmation_required) printf '2 action_required\n' ;;
    canceled)                            printf '130 error\n' ;;
    *)                                   printf '1 error\n' ;;
  esac
}

# A recovery command is plain words with no quoting, so splitting on spaces is its argv.
_agsec_argv_json() {
  local rest="${1:-}" word out=""
  while [ -n "$rest" ]; do
    word="${rest%% *}"
    case "$rest" in *" "*) rest="${rest#* }" ;; *) rest="" ;; esac
    [ -n "$word" ] || continue
    out="${out:+$out,}\"$(agsec_js "$word")\""
  done
  printf '[%s]' "$out"
}

_agsec_emit_error() {  # REASON STATUS MSG [RECOVERY_CMD] [INSTRUCTION]
  local reason="${1:-error}" status="${2:-error}" msg="${3:-}" cmd="${4:-}" how="${5:-}" extra=""
  if [ "${AGSEC_OUTPUT:-text}" = json ]; then
    [ -z "$cmd" ] || extra=",\"next\":[{\"command\":\"$(agsec_js "$cmd")\",\"argv\":$(_agsec_argv_json "$cmd")}]"
    [ -z "${AGSEC_WARNINGS:-}" ] || extra="$extra,\"warnings\":[$AGSEC_WARNINGS]"
    printf '{"status":"%s","reason":"%s","message":"%s"%s}\n' \
      "$(agsec_js "$status")" "$(agsec_js "$reason")" "$(agsec_js "$msg")" "$extra" >&2
    return 0
  fi
  printf '%s\n' "${E_RED}ERROR${E_RESET} $msg" >&2
  [ -z "$cmd" ] || printf '\n%s:\n    %s\n' "${how:-Run}" "$cmd" >&2
}

agsec_fail() {  # REASON MSG [RECOVERY_CMD] [INSTRUCTION]
  local reason="${1:-error}" spec
  spec="$(_agsec_reason "$reason")"
  _agsec_emit_error "$reason" "${spec#* }" "${2:-}" "${3:-}" "${4:-}"
  exit "${spec%% *}"
}
agsec_die() {  # MSG [CODE] [RECOVERY_CMD] [INSTRUCTION]
  local rc="${2:-1}" reason="${AGSEC_REASON:-}" spec
  if [ -z "$reason" ]; then
    case "$rc" in 2) reason=usage ;; 130) reason=canceled ;; *) reason=error ;; esac
  fi
  spec="$(_agsec_reason "$reason")"
  _agsec_emit_error "$reason" "${spec#* }" "${1:-}" "${3:-}" "${4:-}"
  exit "$rc"
}
agsec_canceled() { agsec_fail canceled "${1:-}" "${2:-}" "${3:-}"; }
agsec_need_confirmation() {  # WHAT FLAG CMD
  agsec_fail confirmation_required "Can't ${1:-} without ${2:-} in non-interactive mode." "${3:-}" "Re-run with ${2:-}"
}
# Names only: a value typo'd onto a flag (--import-envv=VALUE) or a surplus positional (add NAME VALUE)
# would otherwise land in a transcript, so the first prints only the flag and the second no token at all.
agsec_unknown_option() {  # CMD TOKEN
  local token="${2:-}"
  agsec_fail usage "Unknown option '${token%%=*}' for ${1:-}." "agent-secrets ${1:-} --help" "See the options"
}
agsec_unexpected_argument() {  # CMD
  agsec_fail usage "Unexpected argument for ${1:-}." "agent-secrets ${1:-} --help" "See the options"
}

# Queued in JSON mode so stderr stays empty on success; the result document or error document carries it.
agsec_warn_json() {  # REASON MSG
  if [ "${AGSEC_OUTPUT:-text}" != json ]; then agsec_warn "${2:-}"; return 0; fi
  AGSEC_WARNINGS="${AGSEC_WARNINGS:+$AGSEC_WARNINGS,}{\"reason\":\"$(agsec_js "${1:-warning}")\",\"message\":\"$(agsec_js "${2:-}")\"}"
}
agsec_deprecated() {  # OLD NEW — once per process, per OLD
  local old="${1:-}"
  case " ${_AGSEC_DEPRECATED_SEEN:-} " in *" $old "*) return 0 ;; esac
  _AGSEC_DEPRECATED_SEEN="${_AGSEC_DEPRECATED_SEEN:-} $old"
  agsec_warn_json deprecated "$old is deprecated; use ${2:-}."
}

_agsec_json_signal() {
  trap - INT TERM
  _agsec_emit_error canceled error "Canceled by signal."
  exit "${1:-130}"
}
agsec_json_signal_traps() {
  [ "${AGSEC_OUTPUT:-text}" = json ] || return 0
  trap '_agsec_json_signal 130' INT
  trap '_agsec_json_signal 143' TERM
}

# Called after parsing and before any store read, TTY attach, prompt or write.
agsec_parse_only_exit() { [ -z "${AGSEC_PARSE_ONLY:-}" ] || exit 0; }

# Log a value's identity without the value (redaction discipline).
# 48-bit truncation (first 12 hex = sha256: + substr 1,12): an ACCIDENTAL-MISMATCH human-readback
# floor ONLY — NOT a substitution/content-address/tamper-evidence defense (48 bits is far too narrow
# for that). share/receive feed it the base64-DECODED age ciphertext bytes (the caller pipes
# `base64 -D | agsec_digest`), never the armored text — reflow-stable across benign re-wrapping.
agsec_digest() { shasum -a 256 2>/dev/null | awk '{print "sha256:"substr($1,1,12)}'; }

# --- Guards ---------------------------------------------------------------------
agsec_have()    { command -v "$1" >/dev/null 2>&1; }

# agsec_have is NOT a safe test for a developer tool on macOS. The system ships INERT STUBS at
# /usr/bin for git, python3, clang, make, swift, lldb and friends — verified byte-identical
# (sha256 7f30f076…, 118864 bytes each) and embedding "com.apple.dt.xcode_select.tool-shim". On a
# Mac WITHOUT the Xcode Command Line Tools those stubs still exist, so `command -v git` SUCCEEDS,
# and then the first real invocation posts a GUI "install the developer tools" dialog and exits
# non-zero — a blocking modal in the middle of a terminal command.
#
# `xcode-select -p` is the honest probe: it is a real binary (not a stub), it never shows a dialog,
# and it fails exactly when no toolchain is installed. A copy of the tool OUTSIDE /usr/bin
# (Homebrew, etc.) is real by definition and needs no probe.
agsec_have_devtool() {
  agsec_have "$1" || return 1
  case "$(command -v "$1")" in
    /usr/bin/*) xcode-select -p >/dev/null 2>&1 || return 1 ;;
  esac
  return 0
}
agsec_require_devtool() {
  agsec_have_devtool "$1" && return 0
  agsec_die "$1 is not usable on this Mac. macOS ships a placeholder at /usr/bin/$1 that only offers to install Apple's developer tools. Install them once with:  xcode-select --install"
}
agsec_require() { agsec_have "$1" || agsec_die "required command not found: $1 — run: agent-secrets doctor"; }

# True iff PATH1 is a readable CONTROLLING TERMINAL — the share/receive agent-exfil boundary. `( : <
# file )` openability is NOT enough: it passes for ANY readable regular file (and /dev/null), so an
# `env -u CLAUDECODE …` agent could point AGSEC_CONFIRM_SRC at a "y" file and slip past. `[ -t ]` on the
# opened fd is the real test; the subshell isolates a failed open (an exec redirection error would
# otherwise exit the caller).
#
# The file-based confirm seam for bats is honored ONLY under AGSEC_TEST_CONFIRM=1 AND when operating on
# a SYNTHETIC store (AGENT_SECRETS_HOME set to a sandbox that is NOT the real $HOME). That second clause
# is the load-bearing hardening: an env-controlling attacker cannot set AGSEC_TEST_CONFIRM=1 to defeat
# the gate against the REAL store, because enabling the seam requires pointing AGENT_SECRETS_HOME at a
# throwaway dir — which holds no real secret to exfiltrate. Production (real store, HOME default) ALWAYS
# requires a genuine controlling terminal. (An attacker who already runs as you can read the store
# directly via the age key regardless — that is the documented honest ceiling, not this gate's job.)
agsec_src_is_tty() {
  # Canonicalize both dirs before comparing so a trivial alias (AGENT_SECRETS_HOME="$HOME/", "$HOME/.",
  # a symlink) cannot pass the "synthetic store" check while still resolving to the REAL store. An empty
  # canonical HOME dir (unset/nonexistent AGENT_SECRETS_HOME) leaves the seam OFF → real tty required.
  if [ -n "${AGSEC_TEST_CONFIRM:-}" ]; then
    local _h _real
    _h="$(cd -P "${AGENT_SECRETS_HOME:-/nonexistent-agsec}" 2>/dev/null && pwd -P)" || _h=""
    _real="$(cd -P "${HOME:-/nonexistent-home}" 2>/dev/null && pwd -P)" || _real=""
    if [ -n "$_h" ] && [ "$_h" != "$_real" ]; then ( : < "$1" ) 2>/dev/null; return; fi
  fi
  ( exec 3<"$1"; [ -t 3 ] ) 2>/dev/null
}

# Refuse secret-bearing key ceremonies inside an agent session
# (~/.claude/projects transcripts capture stdout in plaintext).
agsec_in_agent_session() {
  [ -n "${CLAUDECODE:-}" ] && return 0
  [ -n "${CLAUDE_CODE:-}" ] && return 0
  [ -n "${CURSOR_AGENT:-}" ] && return 0
  [ -n "${CURSOR_TRACE_ID:-}" ] && return 0
  case "${TERM_PROGRAM:-}" in *[Cc]ursor*) return 0 ;; esac
  return 1
}

# --- Color per stream (design: NO_COLOR + --plain + adaptive; ui.sh enriches) -----
# Each stream decides for itself: `cmd >file` still colors errors on a terminal, and `cmd 2>log` keeps the
# log free of ANSI. FORCE_COLOR is ignored inside an agent session so captures never get ANSI.
agsec_color_on() {  # FD
  [ -z "${AGENT_SECRETS_PLAIN:-}" ] || return 1
  [ -z "${NO_COLOR:-}" ] || return 1
  case "${FORCE_COLOR:-}" in
    '') ;;
    0)  return 1 ;;
    *)  agsec_in_agent_session || return 0 ;;
  esac
  [ -t "${1:-1}" ] && [ "${TERM:-}" != dumb ]
}
agsec_use_plain() { ! agsec_color_on 1; }
if agsec_color_on 1; then
  C_RESET=$'\033[0m' ; C_DIM=$'\033[2m' ; C_BOLD=$'\033[1m'
  C_GREEN=$'\033[32m' ; C_YELLOW=$'\033[33m' ; C_RED=$'\033[31m' ; C_BLUE=$'\033[34m'
else
  C_RESET='' ; C_DIM='' ; C_BOLD='' ; C_GREEN='' ; C_YELLOW='' ; C_RED='' ; C_BLUE=''
fi
if agsec_color_on 2; then
  E_RESET=$'\033[0m' ; E_DIM=$'\033[2m' ; E_BOLD=$'\033[1m'
  E_GREEN=$'\033[32m' ; E_YELLOW=$'\033[33m' ; E_RED=$'\033[31m' ; E_BLUE=$'\033[34m'
else
  E_RESET='' ; E_DIM='' ; E_BOLD='' ; E_GREEN='' ; E_YELLOW='' ; E_RED='' ; E_BLUE=''
fi

agsec_stdout_is_tty() { [ -t 1 ]; }
# Takes a JSON document on stdin. Without jq it passes through, because doctor must never require jq.
agsec_json_out() {
  if ! agsec_have jq; then cat; return; fi
  if agsec_stdout_is_tty; then jq .; else jq -c .; fi
}

# --- Mode: the one place that decides whether a prompt may run --------------------
# Non-interactive mode never grants consent; it only turns a prompt into a refusal.
agsec_stdin_is_tty() { [ -t 0 ]; }   # only where stdin decides where a PAYLOAD comes from
agsec_noninteractive_requested() {
  [ "${AGENT_SECRETS_NONINTERACTIVE:-}" = 1 ] || [ -n "${CI:-}" ]
}
agsec_noninteractive() {
  agsec_noninteractive_requested && return 0
  [ -n "${AGENT_SECRETS_UNATTENDED:-}" ] && return 0
  [ "${AGSEC_OUTPUT:-text}" = json ] && return 0
  agsec_in_agent_session && return 0
  { [ -t 0 ] && [ -t 2 ]; } && return 1
  return 0
}
agsec_interactive() { ! agsec_noninteractive; }

# --- Atomic write and lock --------------------------------------------------------
agsec_tmp_sibling() { mktemp "$(dirname "${1:-}")/.$(basename "${1:-}").XXXXXX"; }

# Takes MODE, else the existing target's mode, else keeps mktemp's 0600. A symlinked target is written
# through rather than replaced, so a dotfile manager's link survives (not atomic, like _manifest_replace).
# On any failure TMP is removed and the target is untouched, except that a write-through can fail midway.
agsec_commit() {  # TMP TARGET [MODE]
  local tmp="${1:-}" target="${2:-}" mode="${3:-}"
  [ -n "$mode" ] || mode="$(stat -L -f %Lp "$target" 2>/dev/null)" || mode=""
  if [ -L "$target" ]; then
    if { [ -z "$mode" ] || [ ! -e "$target" ] || chmod "$mode" "$target"; } \
      && ( umask 077; cat "$tmp" >"$target" ) 2>/dev/null \
      && { [ -z "$mode" ] || chmod "$mode" "$target"; }; then
      rm -f "$tmp"; return 0
    fi
  elif [ ! -d "$target" ] && { [ -z "$mode" ] || chmod "$mode" "$tmp"; } && mv -f "$tmp" "$target"; then
    return 0
  fi
  rm -f "$tmp"
  return 1
}

# Only for producers that cannot fail (printf): a failed producer piped in would commit truncated output.
# Fallible producers (jq, sops) write to agsec_tmp_sibling first and then call agsec_commit.
agsec_atomic_write() {  # TARGET [MODE]
  local tmp
  tmp="$(agsec_tmp_sibling "${1:-}")" || return 1
  cat >"$tmp" || { rm -f "$tmp"; return 1; }
  agsec_commit "$tmp" "${1:-}" "${2:-}"
}

# Removes a stale lock only if it still holds the pid its caller judged dead. The mutex stops a second
# waiter from deleting the fresh lock of the waiter that just stole it, which would let both hold it.
_agsec_lock_steal() {  # DIR SEEN_PID
  mkdir "${1:-}.steal" 2>/dev/null || return 1
  if [ "$(cat "${1:-}/pid" 2>/dev/null)" = "${2:-}" ]; then
    rm -f "${1:-}/pid"
    rmdir "${1:-}" 2>/dev/null || true
  fi
  rmdir "${1:-}.steal" 2>/dev/null || true
  return 0
}

# mkdir is the atomic step. The pid comes from a child's PPID because that is right inside a subshell and
# bash 3.2 has no BASHPID. A lock whose pid stays unreadable for 5 s lost its owner between the mkdir and
# the pid write. Returns 1 at the timeout, and the caller picks the error message. Time is wall clock, not
# a poll count, so both bounds stay true on a loaded machine.
# shellcheck disable=SC2016  # $PPID belongs to the child sh
agsec_lock() {  # DIR [TIMEOUT_S=10]
  local dir="${1:-}" timeout="${2:-10}" pid no_pid_since="" deadline
  [ -n "$dir" ] || return 1
  # SECONDS ticks in whole seconds, so the +1 stops a nonzero timeout from expiring early.
  deadline=$((SECONDS + timeout))
  [ "$timeout" -eq 0 ] || deadline=$((deadline + 1))
  while :; do
    if mkdir "$dir" 2>/dev/null; then
      pid="$(exec sh -c 'echo "$PPID"')"
      if printf '%s\n' "$pid" 2>/dev/null >"$dir/pid"; then return 0; fi
      rm -f "$dir/pid"; rmdir "$dir" 2>/dev/null || true
      return 1
    fi
    pid="$(cat "$dir/pid" 2>/dev/null)" || pid=""
    case "$pid" in
      ''|*[!0-9]*)
        [ -n "$no_pid_since" ] || no_pid_since=$SECONDS
        if [ $((SECONDS - no_pid_since)) -ge 5 ] && _agsec_lock_steal "$dir" "$pid"; then no_pid_since=""; continue; fi ;;
      *)
        no_pid_since=""
        if ! kill -0 "$pid" 2>/dev/null && _agsec_lock_steal "$dir" "$pid"; then continue; fi ;;
    esac
    [ "$SECONDS" -lt "$deadline" ] || return 1
    sleep 0.1
  done
}
agsec_unlock() {  # DIR
  [ -n "${1:-}" ] || return 0
  rm -f "${1:-}/pid"
  rmdir "${1:-}" 2>/dev/null || true
}

# --- Remote text ------------------------------------------------------------------
# Stdin filter: strips ESC and other C0 controls, C1, bidi and zero-width characters so remote text cannot
# steer a terminal or disguise itself. Decodes with Encode rather than perl -CS, which dies on malformed
# UTF-8 and loses the whole text (measured on /usr/bin/perl); an invalid byte becomes U+FFFD.
# shellcheck disable=SC2016  # $_ belongs to perl
agsec_sanitize() {
  if [ -x /usr/bin/perl ]; then
    LC_ALL=C tr -d '\000-\010\013-\037\177' | /usr/bin/perl -MEncode -pe '$_ = Encode::decode("UTF-8", $_); s/[\x{80}-\x{9f}\x{200b}-\x{200f}\x{202a}-\x{202e}\x{2066}-\x{2069}\x{feff}]//g; $_ = Encode::encode("UTF-8", $_)'
  else
    LC_ALL=C tr -d '\000-\010\013-\037\177'
  fi
}

# --- Interactive stdin recovery (`curl … | bash`) --------------------------------
# A human running the README one-liner as `curl … | bash` has stdin bound to the PIPE, not the
# terminal — so every `[ -t 0 ]` gate reads "no human here" while a real terminal sits right in
# front of them. That is how the single most widely-known install idiom degraded into a two-command
# flow, and how a hidden prompt could read EOF and store an empty value.
#
# agsec_have_tty: is there a real controlling terminal we could prompt on, regardless of stdin?
# agsec_attach_tty: rebind THIS shell's stdin to it, once, and report success.
#
# SECURITY: this is deliberately NOT a bypass of the agent-session refusal. An agent session's
# /dev/tty is the agent's own pty and its transcript is secret-bearing, so callers MUST check
# agsec_in_agent_session FIRST and refuse — attaching is only ever for a human at a real terminal.
# The test seam mirrors agsec_src_is_tty's: honored only on a SYNTHETIC store, which holds no real
# secret, so it can never weaken the production path.
agsec_have_tty() {
  [ -t 0 ] && return 0
  agsec_src_is_tty /dev/tty
}
agsec_attach_tty() {
  [ -t 0 ] && return 0
  agsec_src_is_tty /dev/tty || return 1
  exec 0</dev/tty || return 1
  [ -t 0 ]
}

# umask for secret-bearing writes: owner-only (0600 files, 0700 dirs).
agsec_secure_umask() { umask 077; }

# The resolved absolute path to the installed agent-secrets dispatcher. Pinned into machine-wide rule
# FILES so an agent invokes THIS binary, not an impostor an attacker may have planted earlier on PATH
# (PATH-hijack of `run`/`add`). AGENT_SECRETS_BIN wins (installer + tests); else derived from the lib dir.
# shellcheck disable=SC2153  # AGENT_SECRETS_LIB is set by the dispatcher; not a misspelling of _BIN
agsec_bin_path() {
  if [ -n "${AGENT_SECRETS_BIN:-}" ]; then printf '%s\n' "$AGENT_SECRETS_BIN"; return 0; fi
  printf '%s\n' "$(agsec_root)/bin/agent-secrets"
}

# The install root. AGENT_SECRETS_LIB (dispatcher-set) wins; otherwise fall back to the root this
# file resolved from at load time. Both references are :--guarded so `set -u` in a caller can never
# turn a missing variable into a fatal "unbound variable" — the failure mode B2 documented.
# shellcheck disable=SC2153  # AGENT_SECRETS_LIB is dispatcher-set; not a misspelling
agsec_root() {
  if [ -n "${AGENT_SECRETS_LIB:-}" ]; then printf '%s\n' "${AGENT_SECRETS_LIB%/lib}"; return 0; fi
  printf '%s\n' "${AGSEC_SELF_ROOT:-}"
}
# Tool version, for staleness detection of an installed rule block (embedded in the block's integrity
# marker; doctor compares it to this).
agsec_version() { printf '%s\n' "$AGENT_SECRETS_VERSION"; }

# The four golden rules — the SINGLE source of rule DATA, rendered per surface so the wording can never
# drift. <bin> = the command an agent should invoke: bare `agent-secrets` for a user-PASTED surface
# (Cursor User Rules), the RESOLVED ABSOLUTE path for a written FILE (so an impostor earlier on PATH
# cannot intercept `run`/`add`). Names-only: `<NAME>` is a template, never a real value. Rule 3
# advertises NEITHER an inline `printf "$VALUE"` NOR a bare form an agent might fill with a literal — it
# routes value entry to a human terminal (an agent substituting a literal secret into its command leaks
# it into the transcript, the exact failure this tool prevents).
_agsec_rule_lines() {
  local bin="${1:-agent-secrets}"
  printf '%s\n' \
    'NEVER write a secret to a .env, export it in plaintext, or print a secret VALUE.' \
    "Run tools WITH secrets injected, process-scoped: $bin run -- <cmd>" \
    "To add or rotate a secret, ask the USER to run: $bin add <NAME>  — in a real terminal, never a secret value in a command." \
    "Names / health / manifest: $bin list · doctor · help --json"
}

# Render the golden rules for a target surface:
#   plain               → "- <rule>" bullets, BARE command name (Cursor User Rules paste / clipboard / TTY)
#   claude-md|agents-md → a markdown FILE section: a self-guard ("ignore unless this binary exists" — so a
#                         dotfile/settings-synced copy is INERT on a machine that lacks the tool), the
#                         rules pinned to the ABSOLUTE binary, and an invisible version+integrity marker
#                         (HTML comment — Claude Code strips it before injecting, so it is a disk-level
#                         tamper/staleness target only, never seen by the agent). <bin> defaults to the
#                         resolved install path; pass one to override (installer passes the real path).
# shellcheck disable=SC2016  # backticks in the markdown header are literal, not command substitution
agsec_render_rules() {
  local fmt="${1:-plain}" bin="${2:-}"
  case "$fmt" in
    plain)
      _agsec_rule_lines "agent-secrets" | while IFS= read -r _r; do printf -- '- %s\n' "$_r"; done ;;
    claude-md|agents-md)
      [ -n "$bin" ] || bin="$(agsec_bin_path)"
      local body
      body="$(
        printf '## Secrets: use `agent-secrets` (never plaintext)\n'
        printf 'This machine has `agent-secrets` — encrypted (sops+age), names-only secret management for coding agents.\n'
        printf 'Ignore this entire section unless the file `%s` exists on THIS machine (these rules may have been synced from another machine that has the tool).\n' "$bin"
        _agsec_rule_lines "$bin" | while IFS= read -r _r; do printf -- '- %s\n' "$_r"; done
      )"
      printf '%s\n' "$body"
      printf '<!-- agent-secrets:version=%s sha256=%s -->\n' "$(agsec_version)" "$(printf '%s' "$body" | shasum -a 256 | awk '{print $1}')" ;;
    *) agsec_die "agsec_render_rules: unknown format '$fmt'" ;;
  esac
}

# Back-compat name — the plain four rules. setup's done-screen + Cursor clipboard call THIS.
agsec_agent_rules() { agsec_render_rules plain; }

# Given the full block body extracted from a written surface (between our markers, INCLUDING the trailing
# integrity marker), report its integrity: prints "ok <version>" if the embedded sha256 matches a
# recompute over the body-minus-marker, "tampered" if it mismatches, "unmarked" if no marker is present
# (a legacy block or a hand-authored one). Used by doctor to distinguish TAMPERED from benign STALE.
agsec_block_integrity() {
  local block="$1" line sha ver body recompute
  line="$(printf '%s\n' "$block" | grep -oE '<!-- agent-secrets:version=[^ ]+ sha256=[0-9a-f]{64} -->' | tail -1)"
  [ -n "$line" ] || { printf 'unmarked\n'; return 0; }
  ver="$(printf '%s' "$line" | sed -E 's/.*version=([^ ]+) .*/\1/')"
  sha="$(printf '%s' "$line" | sed -E 's/.* sha256=([0-9a-f]{64}) -->/\1/')"
  body="$(printf '%s\n' "$block" | grep -vF "$line")"
  # The body used for the hash had NO trailing newline (printf '%s' in the renderer); strip one here.
  recompute="$(printf '%s' "$body" | shasum -a 256 | awk '{print $1}')"
  if [ "$recompute" = "$sha" ]; then printf 'ok %s\n' "$ver"; else printf 'tampered\n'; fi
}
