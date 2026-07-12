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

AGENT_SECRETS_VERSION="0.1.0"
AGENT_SECRETS_KC_SERVICE="agent-age-key"              # Keychain service: the bootstrap age key
AGENT_SECRETS_KC_PREFIX="agent-"                      # uninstall enumerates Keychain by this prefix
AGENT_SECRETS_CANARY_NAME="AWS_BACKUP_ACCESS_KEY_ID"  # in-store canary (plausible name)
# The canary ships as this INERT decoy value — it provides breach detection only after the operator
# ARMS it by replacing the value with a real tripwire token (e.g. a canarytokens.org token bound to
# their own alert). setup offers to arm it; doctor warns while it is still the placeholder.
AGENT_SECRETS_CANARY_PLACEHOLDER="canary-INERT-arm-me-with-a-real-tripwire-token"
AGENT_SECRETS_ROTATE_DAYS_DEFAULT=180                 # age key rotation cadence
AGSEC_SHARE_ENVELOPE_VERSION="v1"                     # colleague-share envelope; receive rejects unknown versions

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

# --- Plain mode / colors (design: NO_COLOR + --plain + adaptive; ui.sh enriches) -
agsec_use_plain() {
  [ -n "${AGENT_SECRETS_PLAIN:-}" ] && return 0
  [ -n "${NO_COLOR:-}" ] && return 0
  [ ! -t 1 ] && return 0
  return 1
}
if agsec_use_plain; then
  C_RESET='' ; C_DIM='' ; C_BOLD='' ; C_GREEN='' ; C_YELLOW='' ; C_RED='' ; C_BLUE=''
else
  C_RESET=$'\033[0m' ; C_DIM=$'\033[2m' ; C_BOLD=$'\033[1m'
  C_GREEN=$'\033[32m' ; C_YELLOW=$'\033[33m' ; C_RED=$'\033[31m' ; C_BLUE=$'\033[34m'
fi

# Status glyphs (✓/⚠/✗) — available before ui.sh is sourced (used by doctor).
agsec_ok()   { printf '%s\n' "${C_GREEN}✓${C_RESET} $*"; }
agsec_attn() { printf '%s\n' "${C_YELLOW}⚠${C_RESET} $*"; }
agsec_bad()  { printf '%s\n' "${C_RED}✗${C_RESET} $*"; }

# --- Logging (names/digests only — NEVER values), all to STDERR -----------------
agsec_log()  { printf '%s\n' "$*" >&2; }
agsec_note() { printf '%s%s%s\n' "$C_DIM" "$*" "$C_RESET" >&2; }
agsec_warn() { printf '%s\n' "${C_YELLOW}WARN${C_RESET} $*" >&2; }
agsec_die()  { printf '%s\n' "${C_RED}ERROR${C_RESET} ${1:-}" >&2; exit "${2:-1}"; }
# Log a value's identity without the value (redaction discipline).
# 48-bit truncation (first 12 hex = sha256: + substr 1,12): an ACCIDENTAL-MISMATCH human-readback
# floor ONLY — NOT a substitution/content-address/tamper-evidence defense (48 bits is far too narrow
# for that). share/receive feed it the base64-DECODED age ciphertext bytes (the caller pipes
# `base64 -D | agsec_digest`), never the armored text — reflow-stable across benign re-wrapping.
agsec_digest() { shasum -a 256 2>/dev/null | awk '{print "sha256:"substr($1,1,12)}'; }

# --- Guards ---------------------------------------------------------------------
agsec_have()    { command -v "$1" >/dev/null 2>&1; }
agsec_require() { agsec_have "$1" || agsec_die "required command not found: $1 — run: agent-secrets doctor"; }

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

# umask for secret-bearing writes: owner-only (0600 files, 0700 dirs).
agsec_secure_umask() { umask 077; }
