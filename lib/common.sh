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
_agsec_root="$(cd -P "$(dirname "${BASH_SOURCE[0]:-$0}")/.." >/dev/null 2>&1 && pwd)"
if [ -n "${_agsec_root:-}" ] && [ -d "$_agsec_root/vendor/bin" ]; then
  case ":$PATH:" in
    *":$_agsec_root/vendor/bin:"*) : ;;
    *) PATH="$_agsec_root/vendor/bin:$PATH"; export PATH ;;
  esac
fi
unset _agsec_root

# Disable sops's online "is this the latest?" update-check. By default `sops --version` calls
# api.github.com with NO client timeout, so on a locked-down corporate network (the exact target — the
# firewall may allow the release CDN but black-hole api.github.com) every version probe hangs 60-120s:
# in deps.sh's version gate + verify-by-exec, and in `doctor`'s toolchain check. This env var (honored
# by every sops that ships the check) makes `--version` return instantly; runtime decrypt calls never
# checked anyway. Unknown to an ancient sops → harmlessly ignored. Exported so child sops calls inherit it.
export SOPS_DISABLE_VERSION_CHECK=1

AGENT_SECRETS_VERSION="0.1.0"
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

# umask for secret-bearing writes: owner-only (0600 files, 0700 dirs).
agsec_secure_umask() { umask 077; }

# The four golden rules an agent (in any IDE) must follow — the SINGLE source of rule DATA, rendered
# per surface by agsec_render_rules so the wording can never drift. Consumed by setup's done-screen +
# Cursor clipboard (plain) AND install.sh's ~/.claude/CLAUDE.md discovery block (claude-md) — one
# source, zero drift. (Regression this closes: install.sh's hand-maintained _discovery_block had
# textually diverged from this rule text despite a comment asserting the two were identical.)
# Names-only: `<NAME>` is a paste template, never a real value. Rule 3 deliberately DROPS the old
# inline `printf … "$VALUE" | add` example — an AGENT lacking $VALUE as a shell variable would
# substitute the LITERAL secret into its command, leaking it into the transcript (the exact failure
# this tool exists to prevent). `add` reads the value from STDIN only (never argv), so the safe
# programmatic path is still available; the rule just stops advertising the leak-prone form.
_agsec_rule_lines() {
  printf '%s\n' \
    'NEVER write a secret to a .env, export it in plaintext, or print a secret VALUE.' \
    'Run tools WITH secrets injected, process-scoped: agent-secrets run -- <cmd>' \
    'To add a secret, run agent-secrets add <NAME> in a terminal, or pipe it from a variable — never place a value literally in a command.' \
    'Names/health/manifest: agent-secrets list · doctor · help --json'
}

# Render the golden rules for a target surface:
#   plain      → "- <rule>" bullet lines (Cursor User Rules paste / clipboard / terminal display)
#   claude-md  → a markdown section for ~/.claude/CLAUDE.md, ~/.claude/rules/*, AGENTS.md, GEMINI.md, …
# shellcheck disable=SC2016  # the backticks in the markdown header are literal, not command substitution
agsec_render_rules() {
  case "${1:-plain}" in
    plain)
      _agsec_rule_lines | while IFS= read -r _r; do printf -- '- %s\n' "$_r"; done ;;
    claude-md|agents-md)
      printf '## Secrets: use `agent-secrets` (never plaintext)\n'
      printf 'This machine has `agent-secrets` — encrypted (sops+age), names-only secret management for coding agents.\n'
      _agsec_rule_lines | while IFS= read -r _r; do printf -- '- %s\n' "$_r"; done ;;
    *) agsec_die "agsec_render_rules: unknown format '${1:-}'" ;;
  esac
}

# Back-compat name — the plain four rules. setup's done-screen + Cursor clipboard call THIS.
agsec_agent_rules() { agsec_render_rules plain; }
