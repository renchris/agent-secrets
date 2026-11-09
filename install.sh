#!/usr/bin/env bash
# install.sh — one-command bootstrap (curl'd).
# FUNCTION-GUARDED (main(){…}; main "$@") so a truncated download can never partial-exec
# Consent gate is the FIRST screen; --dry-run renders the same plan and runs the local checks, but cannot
# check the download or the dependency steps. Consent tiers: a human at a terminal answers [Y/n]; with no
# terminal, or in a detected coding-agent or CI session (counted as no human present), the plan is the
# disclosure and running the installer is the consent.
# Install from a PINNED release tag (never main); SHA-256 verify the release tarball and every
# dependency binary before running it. This script is itself the trust root: the sh re-fetch below runs
# AGENT_SECRETS_INSTALL_URL's text unverified, so that override replaces the trust root.
# AGENT_SECRETS_BASE_URL overrides the source (private-repo / corporate mirror; the smoke test
# uses it). Records every TOOL artifact via lib/manifest.sh; no secret value ever handled.

# --- pinned tag, help and version (POSIX-clean: all of it runs before the bash guard) ---------------
# The ONE tag literal: the sh re-fetch URL, main's PINNED_TAG, --version and help all read it.
AGSEC_PINNED_TAG="v0.1.3"
_agsec_repo="renchris/agent-secrets"

# Mask userinfo (a mirror URL can carry credentials) and drop any query or fragment, for display only.
_agsec_show_url() { _u="$1"; case "$_u" in *://*@*) _u="${_u%%://*}://***@${_u##*@}" ;; esac; printf '%s\n' "${_u%%[?#]*}"; }

_agsec_usage() {
  # shellcheck disable=SC2016  # the help text names $HOME literally
  printf '%s\n' \
    'Usage: install.sh [options]' \
    '' \
    'Install agent-secrets and run setup.' \
    '' \
    'Options:' \
    '  --debug               Print extra step diagnostics on stderr (default: off).' \
    '  --discovery[=true|false]' \
    '                        Answer yes to the offer to write the machine-wide agent' \
    '                        rules (default: ask on a terminal; headless setup writes' \
    '                        them anyway).' \
    '  --dry-run[=true|false]' \
    '                        Show the plan and change nothing (default: false).' \
    '  -h, --help            Show this help and exit.' \
    '  --headless[=true|false]' \
    '                        Run setup prompt-free (default: automatic in an agent' \
    "                        session or with no terminal). Install's own consent" \
    '                        keypress still applies on a terminal.' \
    '  --import-env <NAME>[,<NAME>...]' \
    '                        Seed the store from env-var NAMES set in this shell,' \
    '                        never a value (default: none). An empty list is an' \
    '                        error.' \
    '  --no-color            Turn off color in setup; sets NO_COLOR=1 (default: off).' \
    '  --no-discovery[=true|false]' \
    '                        Do not write the machine-wide agent rules (default:' \
    '                        false; headless setup writes them).' \
    '  --no-dry-run          Same as --dry-run=false.' \
    '  --no-headless         Same as --headless=false: setup picks its own mode.' \
    '  -v, --version         Print the version and exit. With --json, print' \
    '                        {"version":"<version>"}.' \
    '' \
    'Repeating a flag: the last --import-env wins; Boolean flags are idempotent, and' \
    'a flag together with its opposite (--dry-run --no-dry-run) is an error.' \
    '' \
    'Environment (an empty value counts as unset):' \
    '  AGENT_SECRETS_HOME    Install under this home (default: $HOME). Paths derived' \
    '                        from it are written to the shell rc PATH block and the' \
    '                        launchd plist; the variable itself is not saved.' \
    '  AGENT_SECRETS_BASE_URL' \
    '                        Download the release tarball from this mirror (default:' \
    "                        https://github.com/${_agsec_repo})." \
    '  AGENT_SECRETS_INSTALL_URL' \
    '                        Re-fetch install.sh from this URL when run under sh.' \
    '  AGENT_SECRETS_DEPS_BASE_URL' \
    '                        Mirror for the pinned age, sops and jq downloads' \
    '                        (default: https://github.com).' \
    '  AGENT_SECRETS_DEPS_NO_BREW' \
    '                        Set to skip Homebrew when resolving age, sops and jq.' \
    '' \
    'Notes:' \
    '  Progress and prompts go to stderr. An agent session, CI or no terminal means' \
    '  headless setup.' \
    '' \
    'Examples:' \
    '  bash install.sh --headless --import-env OPENROUTER_API_KEY --no-discovery' \
    '  bash install.sh --dry-run' \
    '' \
    'Learn more:' \
    "  https://github.com/${_agsec_repo}/blob/${AGSEC_PINNED_TAG}/README.md"
}

# Help, then version, win over every other argument (an unknown flag or a missing value included) and
# never fetch or re-exec. The bare word `help` counts only as $1, so `--import-env help` stays a value.
for _a in "$@"; do
  case "$_a" in --) break ;; -h|--help) _agsec_usage; exit 0 ;; esac
done
if [ "${1:-}" = help ]; then _agsec_usage; exit 0; fi
_agsec_ver=0; _agsec_json=0
for _a in "$@"; do
  case "$_a" in --) break ;; -v|--version) _agsec_ver=1 ;; --json) _agsec_json=1 ;; esac
done
if [ "$_agsec_ver" = 1 ]; then
  if [ "$_agsec_json" = 1 ]; then printf '{"version":"%s"}\n' "${AGSEC_PINNED_TAG#v}"; else printf '%s\n' "${AGSEC_PINNED_TAG#v}"; fi
  exit 0
fi

# --- bash guard (must be POSIX-clean: NOTHING above this may use a bashism) -------------------
# The README one-liner runs this via `bash -c "$(curl…)"`. If a user instead pipes it to `sh`
# (`sh -c "$(curl…)"`, or `sh install.sh`), macOS runs it under /bin/sh, which sources lib/manifest.sh
# and dies on its process substitution (`< <(…)`) with "syntax error near unexpected token \`<'".
# Re-exec under a real bash so the install works whether the user typed `bash` OR `sh`.
# CRUCIAL: macOS /bin/sh IS bash 3.2 in POSIX mode — it SETS BASH_VERSION yet still rejects that syntax
# — so keying only on BASH_VERSION would SKIP the re-exec on the exact `sh` invocations we target
# (verified: /bin/sh has BASH_VERSION set AND `shopt -qo posix` true). Re-exec when there is no bash at
# all OR bash is in POSIX mode. AGSEC_REEXECED is a sentinel so the re-exec'd (non-POSIX) bash can never
# loop. File case ($0 is a real script path) re-execs in place; the curl-pipe case re-fetches (mirror
# override via AGENT_SECRETS_INSTALL_URL, which replaces the trust root and is run unverified).
# `shopt` never runs under a true POSIX sh: `[ -z BASH_VERSION ]` is true there and short-circuits the `||`.
if [ -z "${AGSEC_REEXECED:-}" ] && { [ -z "${BASH_VERSION:-}" ] || shopt -qo posix 2>/dev/null; }; then
  AGSEC_REEXECED=1; export AGSEC_REEXECED
  # Under `curl … | sh` (or `| /bin/sh`), $0 names the SHELL, and a file of that name in the cwd (a
  # planted ./sh) must never be run as the installer: a shell name always takes the re-fetch. The check is
  # on the basename, not on a slash, because `sh install.sh` has no slash and `| /bin/sh` has one.
  case "${0##*/}" in
    sh|-sh|ash|-ash|dash|-dash|bash|-bash|ksh|-ksh|mksh|zsh|-zsh|busybox) ;;
    *) if [ -f "$0" ]; then exec bash "$0" "$@"; fi ;;   # file case: re-exec in place, no re-download
  esac
  # curl-pipe case: re-fetch from the pinned raw-git channel and hand to bash.
  # Capture first so a failed re-fetch fails LOUD — `bash -c "$(curl…)"` inline would silently run an
  # empty program (exit 0) on a network error, a no-op masquerading as success.
  _agsec_self_url="${AGENT_SECRETS_INSTALL_URL:-https://raw.githubusercontent.com/${_agsec_repo}/${AGSEC_PINNED_TAG}/install.sh}"
  # No --retry on this `$(curl …)` capture: a retried stall after a partial body can exit 0 with the
  # partial text captured, and that text would reach `exec bash -c`.
  _agsec_src="$(curl -fsSL "$_agsec_self_url")" || _agsec_src=""
  # ASCII only: this runs before any helper, so it cannot pick glyphs.
  if [ -z "$_agsec_src" ]; then
    _agsec_u="$(_agsec_show_url "$_agsec_self_url")"
    printf 'ERROR: could not re-fetch install.sh to re-exec under bash.\n  URL: %s\n\nDownload it, then run it with bash (not sh):\n    curl -fsSLo install.sh %s && bash install.sh\n' "$_agsec_u" "$_agsec_u" >&2
    exit 1
  fi
  exec bash -c "$_agsec_src" bash "$@"
fi
# The sentinel has done its job (the re-exec'd bash skipped the guard). Exported, it would reach setup and
# everything it runs, so drop it here.
unset AGSEC_REEXECED

set -euo pipefail

# --- outcome reporting: one EXIT handler and one signal handler, both reading globals only ----------
# main()'s locals are gone by the time the EXIT trap fires while the shell unwinds through an `exit`
# (verified under bash 3.2), so a handler may read only these globals. Each step updates them:
# _AGSEC_CLEANUP_CMD holds %q-baked commands (rebuilt by each step), _AGSEC_PHASE names the step for
# the report, _AGSEC_SWAPPED turns 1 once the new tree replaces the live one, and _AGSEC_RECORDED turns 1
# once the manifest records the tool dir.
_AGSEC_CLEANUP_CMD=""; _AGSEC_PHASE=""; _AGSEC_RECORDED=0; _AGSEC_FRESH=0; _AGSEC_SWAPPED=0
_AGSEC_REPORTED=0; _AGSEC_SIGNALED=0; _AGSEC_RERUN=""; _AGSEC_TOOL_CMD=""; _AGSEC_BIN_CMD=""; _AGSEC_STATE_DIR=""
# A subshell per write: a closed stderr (`… 2>&1 | head -1`) then kills only the subshell, so the default
# SIGPIPE disposition, which skips the EXIT trap, never reaches this shell or its children.
_agsec_err() { ( printf '%s\n' "$@" >&2 ) || true; }
# Glyphs (C7.2). Rich only when stderr is a terminal and nothing asks for plain output: AGENT_SECRETS_PLAIN,
# NO_COLOR (--no-color sets it) or TERM=dumb. NO_COLOR alone selects plain glyphs, the contract AGENTS.md
# and lib/help.sh document (D26, option A). Every glyph goes to stderr, so the test is on fd 2. Inlined, as
# _agent_session is: lib/common.sh is not unpacked yet. Only templates use these; user data keeps its bytes.
_agsec_glyphs() {
  if [ -t 2 ] && [ -z "${AGENT_SECRETS_PLAIN:-}" ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-}" != dumb ]; then
    _G_RICH=1 _G_ARROW='→' _G_DOT='•' _G_BULLET='  • ' _G_SEP=' · ' _G_BAR='│' _G_ELL='…' _G_OK='✓ '
  else
    _G_RICH=0 _G_ARROW='->' _G_DOT='-' _G_BULLET='- ' _G_SEP=', ' _G_BAR='|' _G_ELL='...' _G_OK=''
  fi
}
_agsec_glyphs
_agsec_on_signal() {
  _AGSEC_SIGNALED=1
  case "$_AGSEC_PHASE" in
    download|verify) _agsec_err "Canceled. Nothing was changed." ;;
    setup) _agsec_err "Installed; setup was interrupted. Re-run it:" "    ${_AGSEC_BIN_CMD:-agent-secrets} setup" ;;
    *)
      if [ "$_AGSEC_RECORDED" -eq 1 ]; then
        _agsec_err "Stopped. Partly installed; every change is recorded in $_AGSEC_STATE_DIR/install-manifest.json." \
          "See what uninstall would undo:" "    $_AGSEC_TOOL_CMD uninstall --dry-run"
      elif [ "$_AGSEC_FRESH" -eq 1 ]; then
        _agsec_err "Stopped. Removed the partial install."
      elif [ "$_AGSEC_SWAPPED" -eq 0 ]; then
        _agsec_err "Stopped. Your existing install was not changed."
      else
        _agsec_err "Stopped. Your existing install may be partly updated. Re-run the installer:" "    $_AGSEC_RERUN"
      fi ;;
  esac
  exit "$1"
}
_agsec_on_exit() {
  local rc=$?
  set +e
  [ -z "$_AGSEC_CLEANUP_CMD" ] || eval "$_AGSEC_CLEANUP_CMD"
  if [ "$rc" -ne 0 ] && [ "$_AGSEC_SIGNALED" -eq 0 ] && [ "$_AGSEC_REPORTED" -eq 0 ]; then
    _agsec_err "✗ Failed to install agent-secrets: $_AGSEC_PHASE failed." "Re-run the installer:" "    $_AGSEC_RERUN"
    if [ "$_AGSEC_RECORDED" -eq 1 ]; then
      _agsec_err "Or see what uninstall would undo:" "    $_AGSEC_TOOL_CMD uninstall --dry-run"
    fi
    rc=1   # a raw tool code (curl 22 or 56, tar 2) means nothing to the caller
  fi
  exit "$rc"
}

main() {
  # --- pinned trust anchors ----------------------------------------------------
  # The tag is PINNED — never `main` (a moving ref is an unreviewed-code RCE). Repo-jacking guard:
  # if this project is ever renamed, the OLD GitHub name MUST be retained (a freed name can be
  # re-registered by an attacker and would serve this exact URL).
  local PINNED_TAG="$AGSEC_PINNED_TAG"
  local REPO="renchris/agent-secrets"   # keep the old name reserved forever on any future rename
  local BASE_URL="${AGENT_SECRETS_BASE_URL:-https://github.com/${REPO}}"
  # EXPECTED_SHA256 is BAKED IN at release-tag time by the release runbook (README "Cut a release").
  # THIS curl'd script travels the git-ref channel (raw.githubusercontent at the PINNED tag), so the
  # digest is the trust root — a channel DISTINCT from the swappable release-asset tarball it verifies.
  # It is empty on `main` (unreleased): the default production URL then REFUSES to install (a same-origin
  # .sha256 is no defense against a swapped asset); only a dev/mirror (AGENT_SECRETS_BASE_URL) falls back
  # to the sibling .sha256 for transport integrity. See the SHA-256 gate below.
  local EXPECTED_SHA256=""

  local HOME_DIR="${AGENT_SECRETS_HOME:-$HOME}"
  local INSTALL_DIR="$HOME_DIR/.agent-secrets"
  local BIN_DIR="$HOME_DIR/bin"
  local STATE_DIR="$HOME_DIR/.local/state/agent-secrets"
  local RC_FILE="$HOME_DIR/.zshenv"        # sourced by every zsh invocation incl. Cursor subshells
  # zsh is the macOS default, but a bash-login user never reads ~/.zshenv, so the PATH block would be
  # inert and `agent-secrets` unfound by name in every bash terminal (incl. agent subshells). When the
  # login shell is bash, ALSO write a block to the FIRST EXISTING of .bash_profile/.bash_login/.profile
  # (bash reads only the first of those) — creating .bash_profile when none exist would SHADOW an
  # existing ~/.profile, so pick the existing one.
  local BASH_RC_FILE=""
  case "${SHELL:-}" in
    */bash)
      BASH_RC_FILE="$HOME_DIR/.bash_profile"
      local _rc
      for _rc in .bash_profile .bash_login .profile; do
        if [ -f "$HOME_DIR/$_rc" ]; then BASH_RC_FILE="$HOME_DIR/$_rc"; break; fi
      done ;;
  esac
  local PATH_MARKER="agent-secrets"
  # (No install-local DISCOVERY_MARKER: the discovery marker has a SINGLE source — the
  # AGENT_SECRETS_DISCOVERY_MARKER constant in lib/common.sh — used by the registry in lib/discovery.sh.)
  local SMOKE_LABEL="com.agent-secrets.smoke"
  local SMOKE_PLIST="$HOME_DIR/Library/LaunchAgents/${SMOKE_LABEL}.plist"

  # Every write is a subshell (see _agsec_err): a closed stderr must never kill this shell mid-install.
  _say()  { ( printf '%s\n' "$*" >&2 ) || true; }
  # A step: "  → cmd" on a terminal, the bare command at column 0 in plain output.
  _step() {
    if [ "$_G_RICH" -eq 1 ]; then ( printf '  %s %s\n' "$_G_ARROW" "$*" >&2 ) || true
    else ( printf '%s\n' "$*" >&2 ) || true; fi
  }
  # shellcheck disable=SC2059  # a printf wrapper: the callers pass literal formats
  _eprintf() { ( printf "$@" >&2 ) || true; }
  # _die HEADLINE [LINE...]: the headline after the ERROR: prefix (kept until D6 is answered), then each
  # LINE as given: detail rows, a blank line, an instruction ending in ":", the command indented 4 (C7.1).
  _die()  { ( printf 'ERROR: %s\n' "$1" >&2; shift; [ "$#" -eq 0 ] || printf '%s\n' "$@" >&2 ) || true; exit 1; }
  _run()  { _step "$*"; "$@"; }
  _debug() { if [ "$DEBUG" -eq 1 ]; then ( printf 'debug: %s\n' "$*" >&2 ) || true; fi; }

  # The command that re-runs THIS installer, printed in hints (never run). A real script file re-runs
  # in place. Under `curl | bash` or the sh re-fetch there is no file, so print a download-then-run line;
  # a set AGENT_SECRETS_BASE_URL shows only as a placeholder, because a mirror URL can hold credentials.
  _self_cmd() {
    local base=""
    case "${0##*/}" in
      sh|-sh|ash|-ash|dash|-dash|bash|-bash|ksh|-ksh|mksh|zsh|-zsh|busybox) ;;
      *) if [ -f "$0" ]; then printf 'bash %q\n' "$0"; return 0; fi ;;
    esac
    [ -z "${AGENT_SECRETS_BASE_URL:-}" ] || base="AGENT_SECRETS_BASE_URL=<URL> "
    # shellcheck disable=SC2016  # the $(...) and "$f" are printed for the reader to run, not expanded here
    printf 'f="$(mktemp "${TMPDIR:-/tmp}/agent-secrets-install.XXXXXX")" && curl -fsSL %s -o "$f" && %sbash "$f"\n' \
      "$(_agsec_show_url "${AGENT_SECRETS_INSTALL_URL:-https://raw.githubusercontent.com/${_agsec_repo}/${AGSEC_PINNED_TAG}/install.sh}")" "$base"
  }
  # The published release's own installer (it carries the baked digest), as a download-then-run command.
  _release_cmd() {
    # shellcheck disable=SC2016  # printed for the reader to run, not expanded here
    printf 'f="$(mktemp "${TMPDIR:-/tmp}/agent-secrets-install.XXXXXX")" && curl -fsSL %s -o "$f" && bash "$f"\n' \
      "https://raw.githubusercontent.com/${_agsec_repo}/${AGSEC_PINNED_TAG}/install.sh"
  }
  # _wrap PREFIX CONT TEXT: on a terminal, TEXT after PREFIX wrapped at ${COLUMNS:-80}, with CONT before each
  # further piece; a word longer than the width (a long path) stays whole. Plain output keeps each row on
  # one physical row, so a log or a grep sees it whole.
  _wrap() {
    local prefix="$1" cont="$2" width="${COLUMNS:-80}" out w n=0
    shift 2
    if [ "$_G_RICH" -eq 0 ]; then _say "$prefix$*"; return 0; fi
    case "$width" in ''|*[!0-9]*) width=80 ;; esac
    local -a words=()
    read -r -a words <<<"$*" || true
    out="$prefix"
    for w in ${words[@]+"${words[@]}"}; do
      if [ "$n" -gt 0 ] && [ $(( ${#out} + 1 + ${#w} )) -gt "$width" ]; then
        _say "$out"; out="$cont"; n=0
      fi
      if [ "$n" -eq 0 ]; then out="$out$w"; else out="$out $w"; fi
      n=$((n + 1))
    done
    _say "$out"
  }
  _row() { _wrap "$_G_BULLET" "    " "$*"; }
  # A usage error exits 2 (the repo's convention: cmd/setup.sh, cmd/doctor.sh, lib/help.sh) and never
  # echoes a value. The parse runs before any EXIT trap is armed, so nothing can overwrite the 2.
  _usage_die() { printf 'ERROR: %s\n\nSee the options:\n    %s --help\n' "$*" "$(_self_cmd)" >&2; exit 2; }
  # At most one close name for an unknown long option; it is printed, never run.
  _close_option() {
    case "$1" in
      --deb*|--dbg*)                    printf '%s\n' --debug ;;
      --no-dry*|--nodry*)               printf '%s\n' --no-dry-run ;;
      --no-head*|--nohead*)             printf '%s\n' --no-headless ;;
      --no-disc*|--nodisc*)             printf '%s\n' --no-discovery ;;
      --no-col*|--nocol*)               printf '%s\n' --no-color ;;
      --dry*|--dr-*)                    printf '%s\n' --dry-run ;;
      --head*|--hed*)                   printf '%s\n' --headless ;;
      --disc*|--disk*)                  printf '%s\n' --discovery ;;
      --imp*|--inport*|--env*)          printf '%s\n' --import-env ;;
      --hel*|--hlp*)                    printf '%s\n' --help ;;
      --ver*|--vre*)                    printf '%s\n' --version ;;
    esac
  }
  # Same rule as cmd/setup.sh's _import_env_valid (common.sh is not sourced yet), plus at least one name:
  # setup's '' arm is dead, because word-splitting yields no iterations, so `,` alone would pass there.
  _import_env_valid() {
    local n count=0
    for n in $(printf '%s' "$1" | tr ',' ' '); do
      case "$n" in [A-Za-z_]*[!A-Za-z0-9_]* | [!A-Za-z_]* | '') return 1 ;; esac
      count=$((count + 1))
    done
    [ "$count" -gt 0 ]
  }

  # Flags. The setup-shaping ones are forwarded to `agent-secrets setup`, which owns their meaning (see
  # `agent-secrets setup --help`): --headless forces the prompt-free setup that an agent session / no-tty
  # install gets anyway; --import-env seeds the store from env-var NAMES already set in this process
  # (never a value on argv); --no-discovery skips the machine-wide agent rules that a headless setup
  # writes by default. --discovery is NEVER forwarded (setup --discovery is a standalone screen): it only
  # pre-answers install's own interactive offer, and headless setup writes the rules anyway.
  # Boolean flags take an optional =true|false; each is tri-state ("" = not given) so a flag and its
  # opposite together are a usage error, never last-wins (an appended flag must not turn a preview into
  # a mutation). Repeating the same value is idempotent.
  local DRY_RUN=0 HEADLESS=0 IMPORT_ENV="" NO_DISCOVERY=0 DISCOVERY_YES=0 DEBUG=0
  local _f_dry="" _f_headless="" _f_disc="" _f_import=0 _f_nocolor=0 _flag _val
  _bool() {  # FLAG VALUE-AFTER-= → prints 1 or 0, or dies
    case "$2" in true) printf '1' ;; false) printf '0' ;; *) _usage_die "Use $1=true or $1=false." ;; esac
  }
  _set_tri() {  # VAR NEW — VAR is one of _f_dry/_f_headless/_f_disc; $_flag names the flag in hand
    local cur; eval "cur=\"\${$1}\""
    if [ -n "$cur" ] && [ "$cur" != "$2" ]; then _usage_die "Can't use $_flag together with its opposite."; fi
    eval "$1=\"\$2\""
  }
  while [ "$#" -gt 0 ]; do
    _flag="${1%%=*}"
    case "$1" in
      --dry-run)         _set_tri _f_dry 1 ;;
      --no-dry-run)      _set_tri _f_dry 0 ;;
      --dry-run=*)       _val="$(_bool --dry-run "${1#*=}")" || exit 2; _set_tri _f_dry "$_val" ;;
      --headless)        _set_tri _f_headless 1 ;;
      --no-headless)     _set_tri _f_headless 0 ;;
      --headless=*)      _val="$(_bool --headless "${1#*=}")" || exit 2; _set_tri _f_headless "$_val" ;;
      --discovery)       _set_tri _f_disc 1 ;;
      --discovery=*)     _val="$(_bool --discovery "${1#*=}")" || exit 2; _set_tri _f_disc "$_val" ;;
      --no-discovery)    _set_tri _f_disc 0 ;;
      --no-discovery=*)  _val="$(_bool --no-discovery "${1#*=}")" || exit 2
                         _set_tri _f_disc "$((1 - _val))" ;;
      --import-env)      [ -n "${2:-}" ] || _usage_die "Can't use --import-env without <NAME>."
                         IMPORT_ENV="$2"; _f_import=1; shift ;;
      --import-env=*)    IMPORT_ENV="${1#--import-env=}"; _f_import=1
                         [ -n "$IMPORT_ENV" ] || _usage_die "Can't use --import-env without <NAME>." ;;
      --no-color)        NO_COLOR=1; export NO_COLOR; _f_nocolor=1 ;;
      --debug)           DEBUG=1 ;;
      -h|--help|help)    _agsec_usage; return 0 ;;   # the pre-scan above normally answers first
      --)                shift; [ "$#" -eq 0 ] || _usage_die "Unexpected argument for install.sh. It takes no positional arguments."; break ;;
      -*)                _val="$(_close_option "$_flag")"
                         _usage_die "Unknown option '$_flag' for install.sh.${_val:+ Did you mean $_val?}" ;;
      *)                 _usage_die "install.sh takes no positional arguments." ;;
    esac
    shift
  done
  [ "$_f_dry" != 1 ] || DRY_RUN=1
  [ "$_f_headless" != 1 ] || HEADLESS=1
  case "$_f_disc" in 1) DISCOVERY_YES=1 ;; 0) NO_DISCOVERY=1 ;; esac
  _agsec_glyphs   # again: --no-color has set NO_COLOR
  # Validated on the FINAL value (last one wins), before the plan can print it. Glob characters are
  # refused before the unquoted word-split, so the verdict never depends on what the cwd holds. Spaces
  # stay valid as separators, because setup's own word-split accepts them. The value is never echoed.
  if [ "$_f_import" -eq 1 ]; then
    case "$IMPORT_ENV" in
      *[!A-Za-z0-9_,[:space:]]*) _usage_die "--import-env takes env-var NAMES (letters, digits, _; not starting with a digit), comma-separated." ;;
    esac
    _import_env_valid "$IMPORT_ENV" \
      || _usage_die "--import-env takes env-var NAMES (letters, digits, _; not starting with a digit), comma-separated."
  fi
  _debug "parsed: dry_run=$DRY_RUN headless=$HEADLESS discovery=${_f_disc:-default} import_env=$([ "$_f_import" -eq 1 ] && printf given || printf none)"
  # Parse-only seam: validate the argv, then stop before any TTY attach, prompt, fetch or write.
  [ -z "${AGSEC_PARSE_ONLY:-}" ] || return 0

  # Is this a coding-agent session? Inlined (common.sh is not sourced until after unpack) and kept
  # identical in intent to agsec_in_agent_session — a transcript-bearing session must never be
  # prompted for, or handed, secret material.
  _agent_session() {
    [ -n "${CLAUDECODE:-}" ] && return 0
    [ -n "${CLAUDE_CODE:-}" ] && return 0
    [ -n "${CURSOR_AGENT:-}" ] && return 0
    [ -n "${CURSOR_TRACE_ID:-}" ] && return 0
    case "${TERM_PROGRAM:-}" in *[Cc]ursor*) return 0 ;; esac
    return 1
  }

  # The mode resolves in two steps: AGENT before the attach (the attach must never run in an agent
  # session), the terminal state after it (the attach rebinds stdin).
  local AGENT=0 INTERACTIVE=0 MODE_WHY=""
  if _agent_session; then AGENT=1; fi

  # `curl … | bash` binds stdin to the PIPE, so every `[ -t 0 ]` gate reads "no human here" while a
  # real terminal sits in front of the user — which is how the most widely-known install idiom
  # silently degraded into a two-command flow. Rebind stdin to the controlling terminal so the one
  # command stays one command. NEVER inside an agent session: there /dev/tty is the agent's own pty
  # and its transcript is secret-bearing. Nor when the run says nobody answers (UNATTENDED, CI,
  # AGENT_SECRETS_NONINTERACTIVE=1): the rebind would also discard a piped seed line.
  _attach_tty() {
    [ "$AGENT" -eq 0 ] || return 1
    if [ -n "${AGENT_SECRETS_UNATTENDED:-}" ] || [ -n "${CI:-}" ] || [ "${AGENT_SECRETS_NONINTERACTIVE:-}" = 1 ]; then
      return 1
    fi
    [ -t 0 ] && return 0
    ( exec 3</dev/tty; [ -t 3 ] ) 2>/dev/null || return 1
    exec 0</dev/tty || return 1
    [ -t 0 ]
  }
  # The one interactive decision (consent keypress, plan wording, discovery offer). It mirrors
  # setup_resolve_mode (cmd/setup.sh), so the plan names the setup mode that really runs; the terminal
  # tests and the CI read live only here and in _attach_tty (tests/install_plan.bats checks both).
  _resolve_mode() {
    INTERACTIVE=0
    if [ "$AGENT" -eq 1 ]; then MODE_WHY="coding-agent session"
    elif [ -n "${AGENT_SECRETS_UNATTENDED:-}" ]; then MODE_WHY="unattended"
    elif [ -n "${CI:-}" ] || [ "${AGENT_SECRETS_NONINTERACTIVE:-}" = 1 ]; then MODE_WHY="non-interactive"
    elif [ ! -t 0 ]; then MODE_WHY="no terminal"
    elif [ ! -t 2 ]; then MODE_WHY="stderr is not a terminal"
    else INTERACTIVE=1
    fi
  }
  if _attach_tty; then _debug "stdin: a terminal"; else _debug "stdin: not attached to a terminal"; fi
  _resolve_mode
  _debug "mode: ${MODE_WHY:-interactive}"
  # Setup runs its wizard only on this path; anywhere else it runs headless.
  _wizard_path() { [ "$INTERACTIVE" -eq 1 ] && [ "$HEADLESS" -eq 0 ] && [ -z "$IMPORT_ENV" ]; }

  # --- the plan (rendered identically for consent + dry-run) -------------------
  # Dot-separated numeric compare for the reinstall rows (bash 3.2 has no sort -V): prints lt, eq or gt.
  _ver_cmp() {
    local a="$1." b="$2." x y
    while [ -n "$a" ] || [ -n "$b" ]; do
      x="${a%%.*}"; y="${b%%.*}"; a="${a#*.}"; b="${b#*.}"
      x=$((10#${x:-0})); y=$((10#${y:-0}))
      if [ "$x" -lt "$y" ]; then printf 'lt\n'; return 0; fi
      if [ "$x" -gt "$y" ]; then printf 'gt\n'; return 0; fi
    done
    printf 'eq\n'
  }
  # The unpacked VERSION of an existing install, or "unknown" when it does not read as a version.
  _installed_version() {
    local v; v="$(head -n 1 "$INSTALL_DIR/VERSION" 2>/dev/null)" || v=""
    v="${v//[[:space:]]/}"; v="${v#v}"
    case "$v" in ''|*[!0-9.]*|.*|*.|*..*) printf 'unknown\n' ;; *) printf '%s\n' "$v" ;; esac
  }
  # Plan text only (lib/ is not unpacked yet): a ~/bin target is foreign when it exists, or is a link,
  # and is not already our own link. The write itself decides what is backed up.
  _target_is_foreign() {
    local t="$BIN_DIR/$1"
    { [ -e "$t" ] || [ -L "$t" ]; } || return 1
    if [ -L "$t" ] && [ "$(readlink "$t")" = "$INSTALL_DIR/bin/$1" ]; then return 1; fi
    return 0
  }
  # The files the agent rules can go to, resolved as lib/discovery.sh resolves them (inlined: the lib
  # is not unpacked yet). The registry decides at write time which of them are present.
  _plan_discovery_paths() {
    local claude codex gate="(if that tool's config dir exists)"
    if [ -n "${AGENT_SECRETS_HOME:-}" ]; then
      claude="$AGENT_SECRETS_HOME/.claude"; codex="$AGENT_SECRETS_HOME/.codex"
    else
      claude="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"; codex="${CODEX_HOME:-$HOME/.codex}"
    fi
    local c="        "
    _wrap "      " "$c" "$claude/CLAUDE.md   (Claude Code and VS Code Copilot, if either is present)"
    [ "$claude" = "$HOME_DIR/.claude" ] || _wrap "      " "$c" "$HOME_DIR/.claude/CLAUDE.md   (the copy VS Code Copilot reads)"
    _wrap "      " "$c" "$codex/AGENTS.md   $gate"
    _wrap "      " "$c" "$HOME_DIR/.gemini/GEMINI.md   $gate"
    _wrap "      " "$c" "$HOME_DIR/.config/zed/AGENTS.md   $gate"
    _wrap "      " "$c" "$HOME_DIR/.agents/AGENTS.md   $gate"
    _wrap "      " "$c" "(nothing is written on an org/MDM-managed machine: its managed layer owns these rules)"
  }
  _render_plan() {
    local f old replacing=0 at=""
    _say ""
    _say "The agent-secrets installer will:"
    if [ -n "${AGENT_SECRETS_BASE_URL:-}" ]; then _wrap "  " "    " "Source: $(_agsec_show_url "$BASE_URL") (AGENT_SECRETS_BASE_URL)"; fi
    if [ -n "${AGENT_SECRETS_HOME:-}" ]; then _wrap "  " "    " "Source: $HOME_DIR (AGENT_SECRETS_HOME)"; fi
    if [ -f "$INSTALL_DIR/VERSION" ]; then
      replacing=1
      old="$(_installed_version)"
      if [ "$old" = unknown ]; then
        _wrap "  " "    " "agent-secrets is already installed at $INSTALL_DIR (version unknown). Replacing it with $PINNED_TAG."
      else
        case "$(_ver_cmp "$old" "${PINNED_TAG#v}")" in
          eq) _wrap "  " "    " "agent-secrets $PINNED_TAG is already installed. Re-applying it to repair dependencies, wiring and agent rules." ;;
          lt) _say "  Upgrading agent-secrets v$old to $PINNED_TAG." ;;
          gt) _say "  Warning: this downgrades agent-secrets v$old to $PINNED_TAG." ;;
        esac
      fi
    fi
    _row "ensure age, sops and jq: reuse yours, else 'brew install' any missing one when Homebrew is present, else download pinned, SHA-256-verified binaries (no sudo)"
    # Trust keys on the baked digest, not on the mirror: a baked digest is verified even on a mirror.
    if [ -n "$EXPECTED_SHA256" ]; then
      _row "install the tool under $INSTALL_DIR   (pinned $PINNED_TAG, SHA-256 verified)"
      _row "verify the download against the baked SHA-256 digest"
    elif [ -n "${AGENT_SECRETS_BASE_URL:-}" ]; then
      _row "install the tool under $INSTALL_DIR   (pinned $PINNED_TAG; checked only against the mirror's own .sha256)"
      _row "verify against the mirror's .sha256 (transport integrity only, not tamper evidence)"
    else
      _row "install the tool under $INSTALL_DIR   (pinned $PINNED_TAG)"
      _row "REFUSE: this install.sh has no baked release digest; install from a published release tag"
    fi
    _row "symlink the command + wrappers into $BIN_DIR   (agent-secrets, claude-agent, cursor-agent, apiKeyHelper)"
    for f in agent-secrets claude-agent cursor-agent apiKeyHelper; do
      _target_is_foreign "$f" || continue
      if [ -L "$BIN_DIR/$f" ]; then
        _row "replace your existing symlink $BIN_DIR/$f (backed up to $STATE_DIR/$f.preinstall.bak; uninstall restores it)"
      elif [ -f "$BIN_DIR/$f" ]; then
        _row "replace your existing $BIN_DIR/$f (backed up to $STATE_DIR/$f.preinstall.bak; uninstall restores it)"
      fi
    done
    _row "add a marker-delimited PATH block to $RC_FILE${BASH_RC_FILE:+ (and to $BASH_RC_FILE, because your login shell is bash)}"
    _row "install a weekly launchd smoke job ($SMOKE_LABEL)"
    # lib/wire.sh writes under the install home and ignores CLAUDE_CONFIG_DIR, so name that path.
    [ "$HOME_DIR" = "$HOME" ] || at=" (at $HOME_DIR/.claude/settings.json)"
    _row "back up an existing ~/.claude/settings.json$at as the revert point for setup's apiKeyHelper edit"
    _row "wire apiKeyHelper into that settings.json only once ANTHROPIC_API_KEY is stored"
    _row "record each file, PATH block, launchd job and settings.json edit in $STATE_DIR/install-manifest.json ('agent-secrets uninstall' rolls back recorded entries; Homebrew-installed tools are not recorded)"
    if _wizard_path; then
      _row "run 'agent-secrets setup' at the end: the interactive wizard (keys, first secret, wiring)"
    else
      _row "run 'agent-secrets setup --headless' at the end: real keys, Keychain custody, wiring, no prompts and no secret on any output${IMPORT_ENV:+; import from env: $IMPORT_ENV}"
    fi
    if [ "$NO_DISCOVERY" -eq 1 ]; then
      _row "skip the machine-wide agent rules (--no-discovery)"
    elif _wizard_path && [ "$DISCOVERY_YES" -eq 1 ]; then
      _row "after setup, add agent rules so agents in every repo know to use it: advisory; recorded in the manifest (--discovery, no offer)"
      _plan_discovery_paths
    elif _wizard_path; then
      _row "after setup, offer (opt-in) to add agent rules so agents in every repo know to use it, to:"
      _plan_discovery_paths
    else
      _row "add agent rules so agents in every repo know to use it: advisory; recorded in the manifest; --no-discovery skips"
      _plan_discovery_paths
    fi
    if [ "$replacing" -eq 1 ]; then
      _say ""
      _wrap "" "    " "Some effects cannot be undone: the existing $INSTALL_DIR is replaced, with no backup."
    fi
    _say ""
  }
  # The flags this run was given, rebuilt from the parsed state (names only) for the printed command.
  _rerun_flags() {
    local s=""
    [ "$HEADLESS" -eq 0 ] || s="$s --headless"
    [ -z "$IMPORT_ENV" ] || s="$s --import-env $(printf '%q' "$IMPORT_ENV")"
    [ "$NO_DISCOVERY" -eq 0 ] || s="$s --no-discovery"
    [ "$DISCOVERY_YES" -eq 0 ] || s="$s --discovery"
    [ "$_f_nocolor" -eq 0 ] || s="$s --no-color"
    [ "$DEBUG" -eq 0 ] || s="$s --debug"
    printf '%s' "$s"
  }

  # --- preflight: a regular file (or dangling symlink) where we need a directory --------------------
  # `mkdir -p` below would die "File exists" under set -e AFTER partially creating siblings, leaving
  # residue with no manifest to roll back. Catch it pre-network, pre-mutation, and name every conflict
  # (at most 5). The `if`-form is load-bearing: a `[ … ] && [ … ] && …` chain returns nonzero on the
  # healthy (dir-absent) path and would abort the install under set -e. A symlink TO a directory passes
  # (`[ ! -d ]` follows links), so a legitimately symlinked ~/bin is unaffected. The ancestors are listed
  # because `[ -e ]` is false beneath a regular-file parent. The rc files take the inverse test: only a
  # directory there is a conflict (a symlinked ~/.zshenv is healthy).
  _preflight_dirs() {
    local d n=0 list="" mv=""
    for d in "$HOME_DIR/.local" "$HOME_DIR/.local/state" "$STATE_DIR" "$HOME_DIR/Library" \
             "$HOME_DIR/Library/LaunchAgents" "$INSTALL_DIR" "$BIN_DIR"; do
      if { [ -e "$d" ] || [ -L "$d" ]; } && [ ! -d "$d" ]; then
        n=$((n + 1))
        if [ "$n" -le 5 ]; then
          list="$list  $d already exists and is not a directory"$'\n'
          mv="$mv    mv $(printf '%q %q' "$d" "$d.bak")"$'\n'
        fi
      fi
    done
    for d in "$RC_FILE" ${BASH_RC_FILE:+"$BASH_RC_FILE"}; do
      if [ -d "$d" ]; then
        n=$((n + 1))
        if [ "$n" -le 5 ]; then
          list="$list  $d is a directory, where the PATH block needs a file"$'\n'
          mv="$mv    mv $(printf '%q %q' "$d" "$d.bak")"$'\n'
        fi
      fi
    done
    if [ "$n" -gt 0 ]; then
      _eprintf "ERROR: Can't install agent-secrets: %s path(s) are in the way.\n%s" "$n" "$list"
      if [ "$n" -gt 5 ]; then _eprintf '  %sand %s more\n' "$_G_ELL" "$((n - 5))"; fi
      _eprintf '\nMove each aside:\n%sThen re-run the installer:\n    %s\n' "$mv" "$(_self_cmd)$(_rerun_flags)"
      exit 1
    fi
  }

  # --- consent gate — FIRST screen, nothing mutates before it ------------------
  if [ "$DRY_RUN" -eq 1 ]; then
    _say "Showing the install plan. Nothing will change."
    _render_plan
    _preflight_dirs
    # Only the local checks ran: the download and the dependency steps need network and writes.
    if [ -z "$EXPECTED_SHA256" ] && [ -z "${AGENT_SECRETS_BASE_URL:-}" ]; then
      _say "Install from a published release tag, or set AGENT_SECRETS_BASE_URL."
    else
      _wrap "" "    " "Local checks passed. To install with this plan (download and dependency steps were not checked):"
      _say "    $(_self_cmd)$(_rerun_flags)"
    fi
    return 0
  fi
  _render_plan
  # Consent tiers. A human at a terminal (INTERACTIVE) answers [Y/n]: Enter or yes installs; no, q or
  # EOF cancels with exit 130 (nothing is written before this point); a 4th unclear answer counts as a
  # decline. Inline, because lib/ui.sh is not unpacked yet. With no terminal, or in a detected agent or
  # CI session, nobody is there to answer: the plan just shown is the disclosure and running the
  # installer is the consent. Blocking on `read` there would abort under `set -e` on EOF (closed stdin)
  # or hang forever (open pipe). --dry-run is the way to look without installing.
  if [ "$INTERACTIVE" -eq 1 ]; then
    local reply="" bad=0
    # Nothing is written before the answer, so Ctrl-C here is a decline: same receipt, same 130. The
    # phase traps (_agsec_on_signal) are armed only after the work dir exists.
    trap '_eprintf "\n"; _say "Canceled. Nothing was changed."; exit 130' INT
    while :; do
      _eprintf 'Install agent-secrets to %s and edit %s? [Y/n] ' "$INSTALL_DIR" "$RC_FILE"
      if ! read -r reply; then reply=n; _eprintf '\n'; fi
      case "$reply" in
        ''|y|Y|yes) break ;;
        n|N|no|q)   _say "Canceled. Nothing was changed."; exit 130 ;;
      esac
      bad=$((bad + 1))
      if [ "$bad" -ge 4 ]; then _say "Canceled. Nothing was changed."; exit 130; fi
      _say "Please answer y or n."
    done
    trap - INT
  else
    _say "($MODE_WHY: proceeding with the plan above; --dry-run previews, --no-discovery skips the agent rules)"
  fi

  _preflight_dirs
  # Refuse before any download: on the default production URL a missing baked digest can never pass the
  # SHA-256 gate below. After consent (the plan is the first screen) and after the dry-run return.
  if [ -z "$EXPECTED_SHA256" ] && [ -z "${AGENT_SECRETS_BASE_URL:-}" ]; then
    _die "Can't verify this installer. It carries no baked release digest." \
      "  Why: EXPECTED_SHA256 is empty, so this copy was not cut by the release runbook, and a .sha256 from" \
      "       the same origin cannot detect a swapped release asset." \
      "" "Install the published release:" "    $(_release_cmd)" \
      "Or install from a mirror you control:" "    AGENT_SECRETS_BASE_URL=<MIRROR_URL> bash install.sh"
  fi

  # --- toolchain: resolved AFTER unpack, from the tool's own lib/deps.sh -----------------------------
  # (This USED to `brew install age sops jq` behind a sudo-gated Homebrew bootstrap — the #1
  #  corporate blocker in ONE_COMMAND_INSTALL_FEEDBACK.md. deps_ensure below now resolves each tool
  #  NO-SUDO: reuse a PATH copy → Homebrew if already present → else a pinned, SHA-256-verified static
  #  binary. It lives in lib/deps.sh, so it can only run once the tarball is unpacked — hence the move.)

  # --- download + SHA-256 verify (never execute an unverified artifact) --------
  # One curl budget for every download: 15 s to connect, 120 s per attempt, 3 retries of the transient
  # failures curl itself classifies (never --retry-all-errors, which retries a 404), 300 s overall. The
  # URL stays in curl's argv (tests/mocks/curl reads it there); only the display is redacted (D25).
  _AGSEC_CURL_QUIET=""
  _fetch() {
    local rc=0
    if [ -z "$_AGSEC_CURL_QUIET" ]; then
      # --no-progress-meter (curl 7.67.0+) keeps curl's "Will retry" lines, which -sS hides.
      if curl --no-progress-meter --version >/dev/null 2>&1; then _AGSEC_CURL_QUIET=--no-progress-meter; else _AGSEC_CURL_QUIET=-sS; fi
    fi
    _step "curl $(_agsec_show_url "$1") -o $2"
    curl -fL "$_AGSEC_CURL_QUIET" --connect-timeout 15 --max-time 120 --retry 3 --retry-connrefused --retry-max-time 300 \
      "$1" -o "$2" 2>&1 | _retry_notice || rc=$?
    return "$rc"
  }
  # curl's stderr, with each retry warning rewritten and a retry count after a final `curl: (N)` line.
  _retry_notice() {
    local line="" last="" n=0
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        *"Will retry"*) n=$((n + 1)); _say "Retrying automatically$_G_ELL" ;;
        *) _say "$line" ;;
      esac
      last="$line"; line=""
    done
    case "$last" in "curl: ("*) if [ "$n" -gt 0 ]; then _say "Retries: $n"; fi ;; esac
    return 0
  }
  # Only 6, 7 and 28 say why it failed (no DNS, no connection, timeout); any other code (a 404 is 22 on
  # the mock and 56 on the real host, README.md:70) gets the raw code and the redacted URL instead.
  _fetch_die() {
    local host="${1#*://}" file="${1##*/}"
    host="${host%%/*}"; host="${host##*@}"; host="${host%%[?#]*}"; file="${file%%[?#]*}"
    case "$2" in
      6|7|28) _say "ERROR: Couldn't reach $host." ;;
      *) _agsec_err "ERROR: Couldn't download $file from $host." "  curl exit: $2" "  URL: $(_agsec_show_url "$1")" ;;
    esac
    exit 1
  }

  _AGSEC_RERUN="$(_self_cmd)$(_rerun_flags)"
  _AGSEC_STATE_DIR="$STATE_DIR"
  _AGSEC_PHASE=download
  local work; work="$(mktemp -d)"
  # From here every exit runs _agsec_on_exit: the work dir always goes, and the steps below add to the
  # cleanup string what they create. Signals print where the run stopped, then exit 129, 130 or 143.
  printf -v _AGSEC_CLEANUP_CMD 'rm -rf -- %q' "$work"
  local _work_rm="$_AGSEC_CLEANUP_CMD"
  trap '_agsec_on_exit' EXIT
  trap '_agsec_on_signal 130' INT
  trap '_agsec_on_signal 143' TERM
  trap '_agsec_on_signal 129' HUP
  local pkg="$work/agent-secrets-${PINNED_TAG}.tar.gz"
  local url="$BASE_URL/releases/download/${PINNED_TAG}/agent-secrets-${PINNED_TAG}.tar.gz"
  _say "Downloading ${PINNED_TAG}$_G_ELL"
  _fetch "$url" "$pkg" || _fetch_die "$url" "$?"
  _AGSEC_PHASE=verify
  local got expect
  got="$(shasum -a 256 "$pkg" | awk '{print $1}')"
  if [ -n "$EXPECTED_SHA256" ]; then
    # Production path: the digest was baked into THIS script (git-ref channel) at release-tag time, so a
    # swapped release-asset tarball fails here — real release-asset tamper-evidence, not same-origin trust.
    expect="$EXPECTED_SHA256"; _debug "digest: baked into this install.sh"
  elif [ -n "${AGENT_SECRETS_BASE_URL:-}" ]; then
    # Dev/mirror convenience ONLY (BASE_URL overridden): trust a sibling .sha256 from the mirror you
    # control. This is transport integrity (corruption/partial-download), NOT release-asset tamper-evidence.
    _AGSEC_PHASE=download
    _fetch "$url.sha256" "$pkg.sha256" || _fetch_die "$url.sha256" "$?"
    _AGSEC_PHASE=verify
    expect="$(awk '{print $1}' "$pkg.sha256")"; _debug "digest: the mirror's sibling .sha256 (AGENT_SECRETS_BASE_URL is set)"
  fi
  if [ "$got" != "$expect" ]; then
    _AGSEC_REPORTED=1   # this report carries its own recovery; the EXIT handler still cleans up
    _die "Couldn't verify $(basename "$pkg"). SHA-256 mismatch." \
      "  URL:      $(_agsec_show_url "$url")" "  Expected: $expect" "  Actual:   $got" \
      "" "Nothing was installed. Re-run the installer:" "    $_AGSEC_RERUN" \
      "If it fails the same way again, report it:" "    https://github.com/renchris/agent-secrets/issues"
  fi
  if [ -n "$EXPECTED_SHA256" ]; then
    _say "SHA-256 verified."
  else
    _say "Checked only against the mirror's own .sha256: transport integrity, not tamper evidence."
  fi

  # --- unpack the tool ---------------------------------------------------------
  # The pre-manifest window: from the lock below until the manifest records $INSTALL_DIR, an abort (a
  # tar failure, the layout check, a REQUIRED dependency that can't be fetched on a locked-down network)
  # would strand the unpacked tool with NO manifest to roll back. So the cleanup string grows here to
  # remove ONLY what this run creates: the staging tree, $INSTALL_DIR when it is fresh (a re-run over a
  # live install must never be deleted by an abort, RT6), and each directory this run makes on the way to
  # $STATE_DIR and $BIN_DIR, deepest first (a pre-existing empty ~/bin is not ours to remove). Once the
  # manifest records $INSTALL_DIR the string drops back to the work dir and the lock release, so the
  # success path and uninstall are unaffected. The paths are %q-baked now because the handler cannot
  # read main()'s locals. Each piece is kept apart so every rebuild keeps the order: work dir, lock
  # release (before the state dir it lives in is removed), staging, tool dir, state dir, created dirs.
  # A string, not an array: an empty array under set -u aborts on bash 3.2.
  local _created=""
  _note_new() {
    local p="$1" q
    while [ "$p" != "$HOME_DIR" ] && [ ! -e "$p" ] && [ ! -L "$p" ]; do
      printf -v q '%q' "$p"; _created="$_created $q"; p="$(dirname "$p")"
    done
  }
  _note_new "$STATE_DIR"; _note_new "$BIN_DIR"
  local _q _lock_rm="" _stage_rm="" _tool_rm="" _state_rm="" _dirs_rm=""
  # A state dir this run creates holds only this run's files (the lock and, once initialised, the manifest).
  if [ ! -e "$STATE_DIR" ]; then printf -v _q '%q' "$STATE_DIR"; _state_rm="; rm -rf -- $_q"; fi
  if [ -n "$_created" ]; then _dirs_rm="; rmdir --$_created 2>/dev/null || true"; fi
  _AGSEC_CLEANUP_CMD="$_work_rm$_state_rm$_dirs_rm"

  # --- one install at a time -----------------------------------------------------------------------
  # Two installs at once would unpack over each other, and an aborting fresh one removes the tool dir
  # under its sibling; setup's key mint races the same way. So the rest of the run, setup included,
  # holds a lock dir (mkdir is the atomic step). Inline, because lib/common.sh's agsec_lock is not
  # unpacked yet; the steal follows its rules: a dead pid is reclaimed at once, a lock whose pid stays
  # unreadable for 5 s lost its owner between the mkdir and the pid write, and the .steal mutex stops a
  # second waiter from removing the lock the first waiter just took. Time is wall clock (SECONDS).
  # The lock is released through the cleanup string, never a second trap.
  local lock="$STATE_DIR/install.lock" holder="" no_pid_since="" said=0 deadline=$((SECONDS + 61))
  _install_lock_steal() {  # SEEN_PID
    mkdir "$lock.steal" 2>/dev/null || return 1
    if [ "$(cat "$lock/pid" 2>/dev/null)" = "$1" ]; then rm -f "$lock/pid"; rmdir "$lock" 2>/dev/null || true; fi
    rmdir "$lock.steal" 2>/dev/null || true
    return 0
  }
  while :; do
    mkdir -p "$STATE_DIR" || _die "Couldn't create $STATE_DIR."
    if mkdir "$lock" 2>/dev/null; then
      printf -v _q '%q' "$lock"; _lock_rm="; rm -f -- $_q/pid; rmdir -- $_q 2>/dev/null"
      _AGSEC_CLEANUP_CMD="$_work_rm$_lock_rm$_state_rm$_dirs_rm"
      printf '%s\n' "$$" >"$lock/pid" || _die "Couldn't write the install lock $lock/pid."
      break
    fi
    holder="$(cat "$lock/pid" 2>/dev/null)" || holder=""
    case "$holder" in
      ''|*[!0-9]*)
        [ -n "$no_pid_since" ] || no_pid_since=$SECONDS
        if [ $((SECONDS - no_pid_since)) -ge 5 ] && _install_lock_steal "$holder"; then no_pid_since=""; continue; fi ;;
      *)
        no_pid_since=""
        if ! kill -0 "$holder" 2>/dev/null && _install_lock_steal "$holder"; then continue; fi ;;
    esac
    if [ "$SECONDS" -ge "$deadline" ]; then
      _AGSEC_REPORTED=1
      _agsec_err "ERROR: Another agent-secrets install is running (pid ${holder:-unknown}); waited 60 s for it to finish." \
        "Re-run the installer when it finishes:" "    $_AGSEC_RERUN"
      exit 1
    fi
    if [ "$said" -eq 0 ]; then
      _say "Another agent-secrets install is running (pid ${holder:-unknown}); waiting up to 60 s for it to finish$_G_ELL"
      said=1
    fi
    sleep 1
  done

  # A run stopped between the two renames of the swap below leaves only $INSTALL_DIR.old: put it back
  # before the fresh-install test, so that test sees the install that exists.
  local old_tree="$INSTALL_DIR.old"
  if [ ! -e "$INSTALL_DIR" ] && [ ! -L "$INSTALL_DIR" ] && [ -d "$old_tree" ] && [ ! -L "$old_tree" ]; then
    _run mv "$old_tree" "$INSTALL_DIR"
    _say "Recovered $INSTALL_DIR from an interrupted install."
  fi
  local FRESH_INSTALL=0; [ -d "$INSTALL_DIR" ] || FRESH_INSTALL=1
  _debug "fresh install: $FRESH_INSTALL (1 = an abort removes the unpacked tool)"
  if [ "$FRESH_INSTALL" -eq 1 ]; then printf -v _q '%q' "$INSTALL_DIR"; _tool_rm="; rm -rf -- $_q"; fi
  _AGSEC_FRESH="$FRESH_INSTALL"
  _AGSEC_PHASE=unpack
  # Staged unpack: the new version is unpacked and checked beside the live tree, then swapped in, so an
  # interrupt or a mis-cut tarball never mixes versions in a live install, and files a newer version
  # dropped do not linger. Same filesystem as $INSTALL_DIR, so the swap is two renames.
  local staging
  staging="$(mktemp -d "$HOME_DIR/.agent-secrets.staging.XXXXXX")" || _die "Couldn't create a staging directory in $HOME_DIR."
  printf -v _q '%q' "$staging"; _stage_rm="; rm -rf -- $_q"
  _AGSEC_CLEANUP_CMD="$_work_rm$_lock_rm$_stage_rm$_tool_rm$_state_rm$_dirs_rm"
  _run mkdir -p "$BIN_DIR" "$STATE_DIR"
  _run tar -xzf "$pkg" -C "$staging" --strip-components=1 \
    || _die "Couldn't unpack $(basename "$pkg") into $INSTALL_DIR."
  # Fail LOUDLY on a mis-cut tarball (wrong/missing top-level prefix flattens the layout and would
  # dangle every wrapper symlink) instead of a cryptic `set -e` abort on the first source below. The
  # release runbook pins `git archive --prefix=agent-secrets-${TAG}/` to guarantee the single prefix dir.
  # Check BOTH a lib and the dispatcher: a tarball missing bin/agent-secrets would otherwise dangle the
  # dispatcher symlink, and manifest_record_file (which follows the link) returns 1 → set -e abort AFTER
  # the cleanup trap is disarmed → half-wired install with no rollback. Checked on staging, so a bad
  # tarball never touches a live install.
  { [ -f "$staging/lib/common.sh" ] && [ -f "$staging/bin/agent-secrets" ]; } \
    || _die "This release is mis-cut (unexpected tarball layout)." \
      "  Expected: one top-level directory holding bin/ and lib/" \
      "" "Report it, so the release can be re-cut:" "    https://github.com/renchris/agent-secrets/issues" \
      "If you run a mirror, rebuild with:" \
      "    git archive --prefix=agent-secrets-$PINNED_TAG/ -o agent-secrets-$PINNED_TAG.tar.gz $PINNED_TAG"
  # The vendored jq, age and sops live in the tool dir (lib/deps.sh), not in the tarball: carry them over.
  if [ -d "$INSTALL_DIR/vendor" ] && [ ! -e "$staging/vendor" ]; then
    _run cp -Rp "$INSTALL_DIR/vendor" "$staging/vendor" \
      || _die "Couldn't copy $INSTALL_DIR/vendor into the new version."
  fi
  # mktemp -d makes 0700; the manifest records the tool dir's mode, so keep the live mode, or for a fresh
  # install the mode mkdir would give.
  local dmode
  if [ "$FRESH_INSTALL" -eq 1 ]; then
    dmode="$(printf '%o' $((0777 & ~$(umask))))"
  else
    dmode="$(stat -f '%Lp' "$INSTALL_DIR")"
  fi
  _run chmod "$dmode" "$staging"
  # A shell cannot exchange two directories atomically: a wrapper started between the two renames fails.
  # An abort in that gap puts the old tree back; a stop that skips the trap leaves .old, recovered above.
  if [ "$FRESH_INSTALL" -eq 0 ]; then
    if [ -e "$old_tree" ] || [ -L "$old_tree" ]; then _run rm -rf -- "$old_tree"; fi   # a finished swap's leftover
    local _oq _iq
    printf -v _oq '%q' "$old_tree"; printf -v _iq '%q' "$INSTALL_DIR"
    _AGSEC_CLEANUP_CMD="$_work_rm$_lock_rm; [ -e $_iq ] || mv -- $_oq $_iq$_stage_rm$_tool_rm$_state_rm$_dirs_rm"
    _run mv "$INSTALL_DIR" "$old_tree" || _die "Couldn't move $INSTALL_DIR aside for the new version."
  fi
  _run mv "$staging" "$INSTALL_DIR" || _die "Couldn't move the new version into place at $INSTALL_DIR."
  _AGSEC_SWAPPED=1
  _AGSEC_CLEANUP_CMD="$_work_rm$_lock_rm$_tool_rm$_state_rm$_dirs_rm"
  if [ "$FRESH_INSTALL" -eq 0 ]; then _run rm -rf -- "$old_tree" || true; fi

  # From here on the tool's own libs exist — source them to record artifacts.
  # shellcheck source=/dev/null
  . "$INSTALL_DIR/lib/common.sh"
  # The same subshell-per-write for the lib's printers in this process (deps_ensure writes through them
  # in the pre-manifest window). Each original is kept under a _agsec_raw_ name and called in a subshell.
  local _fn
  for _fn in agsec_log agsec_note agsec_plan agsec_warn agsec_ok agsec_attn agsec_bad \
             agsec_receipt agsec_receipt_attn agsec_receipt_bad _agsec_emit_error; do
    declare -F "$_fn" >/dev/null || continue
    eval "_agsec_raw_$(declare -f "$_fn")"
    eval "$_fn() { ( _agsec_raw_$_fn \"\$@\" ) || true; }"
  done
  _AGSEC_PHASE=toolchain
  # Resolve the toolchain NO-SUDO before anything below needs it: manifest.sh + every artifact-record
  # call use jq, and setup/store need age+sops. deps_ensure reuses a PATH copy → Homebrew if present →
  # else fetches pinned SHA-256-verified binaries into $INSTALL_DIR/vendor/bin (inside the recorded
  # install dir, so uninstall removes them) and puts that dir on PATH for the rest of this install
  # (common.sh re-adds it at runtime for the wrappers).
  # shellcheck source=/dev/null
  . "$INSTALL_DIR/lib/deps.sh"
  export AGENT_SECRETS_VENDOR_BIN="$INSTALL_DIR/vendor/bin"
  deps_ensure
  # shellcheck source=/dev/null
  . "$INSTALL_DIR/lib/manifest.sh"
  # shellcheck source=/dev/null
  . "$INSTALL_DIR/lib/discovery.sh"   # data-driven machine-wide agent-discovery registry (opt-in below)
  agsec_secure_umask
  manifest_init

  # Wire the bin dispatcher + wrappers as SYMLINKS onto PATH (they follow the link back to their
  # sibling lib/ under $INSTALL_DIR — a plain copy would strand them from lib/). Record each symlink
  # for rollback, and record $INSTALL_DIR itself so uninstall removes the unpacked tool (no residue).
  # The `||` context is load-bearing: the record is on a directory, so the shasum inside it exits 1, and
  # only the `||` keeps errexit from aborting there; the status still reflects the append. A failed
  # record dies while the pre-manifest cleanup is still armed, so the fresh tool dir goes too.
  manifest_record_file "$INSTALL_DIR" >/dev/null 2>&1 || _die "Couldn't record $INSTALL_DIR in the install manifest."
  # $INSTALL_DIR is recorded → uninstall can roll it back; the cleanup drops back to the work dir and
  # the lock release.
  _AGSEC_CLEANUP_CMD="$_work_rm$_lock_rm"; _AGSEC_RECORDED=1
  printf -v _AGSEC_TOOL_CMD '%q' "$INSTALL_DIR/bin/agent-secrets"
  _AGSEC_PHASE="wire PATH"
  # Anything at a target that is not our own link is the USER'S: a file, a link elsewhere, a dangling
  # link or a link to a directory. The link below replaces it and uninstall's `rm -f` of the `file`
  # record would finish the loss, so manifest_backup_user_target copies it (a link as a link) and
  # appends an `edit` record BEFORE the file record: LIFO rollback removes our link first, then restores
  # theirs. A changed user file refreshes the backup and keeps the earlier one, timestamped. A failed
  # backup or record stops before the link. `ln -n` replaces a link to a directory instead of dropping
  # a stray link inside that directory.
  _wire_bin() {
    local t="$BIN_DIR/$1"
    manifest_backup_user_target "$t" "$1.preinstall.bak" "$INSTALL_DIR/bin/$1" >/dev/null \
      || _die "Couldn't record the backup of $t; nothing replaced. Your file is unchanged."
    _run ln -sfn "$INSTALL_DIR/bin/$1" "$t"
    manifest_record_file "$t" || _die "Couldn't record $t in the install manifest."
  }
  local f
  _wire_bin agent-secrets
  for f in claude-agent cursor-agent apiKeyHelper; do
    [ -f "$INSTALL_DIR/bin/$f" ] || continue
    _wire_bin "$f"
  done

  # Idempotent, marker-delimited PATH block → shell rc (recorded for total rollback). The path is
  # escaped for the double quotes it sits in, so a `"`, `$`, backquote or backslash in it stays literal
  # when the rc is sourced; an ordinary path is unchanged.
  _dq_escape() { local s=$1; s=${s//\\/\\\\}; s=${s//\"/\\\"}; s=${s//\$/\\\$}; s=${s//\`/\\\`}; printf '%s' "$s"; }
  local path_line; path_line="export PATH=\"$(_dq_escape "$BIN_DIR"):\$PATH\""
  manifest_pathblock_install "$RC_FILE" "$PATH_MARKER" "$path_line"
  # Bash-login users also get the block in their login rc (see BASH_RC_FILE above); recorded → uninstall
  # strips it via the same _manifest_rb_pathblock.
  if [ -n "$BASH_RC_FILE" ]; then
    manifest_pathblock_install "$BASH_RC_FILE" "$PATH_MARKER" "$path_line"
  fi

  # Weekly launchd smoke job. Written from the tool's own template.
  _AGSEC_PHASE=launchd
  _run mkdir -p "$HOME_DIR/Library/LaunchAgents"
  _install_smoke_plist "$SMOKE_PLIST" "$SMOKE_LABEL" "$INSTALL_DIR" || _die "Couldn't write $SMOKE_PLIST."
  # A failed bootout is the normal first-install case. A failed bootstrap is legitimate over SSH or with
  # no GUI session, so it warns and goes on (doctor classes the job as optional) unless the job is
  # loaded anyway, the check doctor uses. The plist is recorded either way: uninstall needs the record.
  local smoke_loaded=1
  launchctl bootout "gui/$(id -u)/$SMOKE_LABEL" >/dev/null 2>&1 || true
  if ! launchctl bootstrap "gui/$(id -u)" "$SMOKE_PLIST" >/dev/null 2>&1 \
     && ! launchctl list "$SMOKE_LABEL" >/dev/null 2>&1; then
    smoke_loaded=0
    _say "! Couldn't load the weekly smoke job ($SMOKE_LABEL). Run agent-secrets doctor later."
    _say "  This command failed: launchctl bootstrap gui/$(id -u) $(printf '%q' "$SMOKE_PLIST")"
  fi
  manifest_record_launchd "$SMOKE_LABEL" "$SMOKE_PLIST"

  # The ~/.claude/settings.json apiKeyHelper edit + its revert point are owned SOLELY by `setup`
  # (_wire_tools): it records a write-once backup when the file pre-existed, or a `created` marker when
  # it did not (rollback then deletes the tool-made file instead of leaving an empty {}). Recording it
  # here too would double the revert record, so the installer intentionally does not.

  # Pin AGENT_SECRETS_BIN to the PATH command so the discovery preview and the write share one abs-path
  # (the rendered rules reference THIS binary, not a PATH impostor). Exported before setup, so the
  # headless setup this installer chains into renders the SAME path when it writes discovery itself.
  AGENT_SECRETS_BIN="$BIN_DIR/agent-secrets"; export AGENT_SECRETS_BIN

  # --- finish: setup, in the mode this environment can run ----------------------------------------
  # ONE command means setup runs HERE, in every environment. A human at a terminal gets the wizard.
  # An agent session or a no-tty install used to be told "open Terminal.app and run agent-secrets
  # setup" — the human became the runtime. Now `setup` itself detects that nobody can be prompted and
  # runs HEADLESS: real keys minted to files, the Keychain populated over a pipe, no first secret
  # unless --import-env names one already in this environment, and only names/paths/status printed —
  # nothing a transcript could capture. UNATTENDED (tests/CI) still runs with fake values.
  # Setup stays a child, not an exec and not in the background (D19): control returns for the outcome
  # and the offer below, and a background child would start with SIGINT ignored. A TERM or HUP sent to
  # this pid alone is handled once setup returns. A failed setup is reported here with its own exit
  # code, and the run stops before the offer.
  _say ""
  local -a setup_args=()
  if [ "$HEADLESS" -eq 1 ]; then setup_args+=(--headless); fi
  if [ -n "$IMPORT_ENV" ]; then setup_args+=(--import-env "$IMPORT_ENV"); fi
  if [ "$NO_DISCOVERY" -eq 1 ]; then setup_args+=(--no-discovery); fi
  local not_loaded=""
  [ "$smoke_loaded" -eq 1 ] || not_loaded=" (weekly smoke job not loaded)"
  _say "Tool installed at $INSTALL_DIR$not_loaded. Changes recorded in $(agsec_install_manifest). Running setup$_G_ELL"
  _debug "setup flags: ${setup_args[*]+${setup_args[*]}}"
  printf -v _AGSEC_BIN_CMD '%q' "$BIN_DIR/agent-secrets"
  _AGSEC_PHASE=setup
  local setup_rc=0
  _run "$BIN_DIR/agent-secrets" setup ${setup_args[@]+"${setup_args[@]}"} || setup_rc=$?
  if [ "$setup_rc" -ne 0 ]; then
    _AGSEC_REPORTED=1
    case "$setup_rc" in
      129|130|143) _agsec_err "Installed; setup was interrupted. Re-run it:" "    $_AGSEC_BIN_CMD setup" ;;
      1)
        # Setup ran to the end but its health check found a ✗ row: it records `checked`, never `done`
        # (cmd/setup.sh, F28). Any other exit 1 is a step that failed.
        if [ "$(cat "$(agsec_wizard_state)" 2>/dev/null)" = checked ]; then
          _say "Setup finished with problems. Run: agent-secrets doctor"
          _say "    $_AGSEC_BIN_CMD doctor   (by path, until you open a new shell)"
        else
          _say "✗ Setup failed (exit $setup_rc). The tool is installed but not configured."
          _say "Finish setup:"
          _say "    $_AGSEC_BIN_CMD setup"
          _say "Or remove it:"
          _say "    $_AGSEC_BIN_CMD uninstall"
        fi ;;
      *)
        _say "✗ Setup failed (exit $setup_rc). The tool is installed but not configured."
        _say "Finish setup:"
        _say "    $_AGSEC_BIN_CMD setup"
        _say "Or remove it:"
        _say "    $_AGSEC_BIN_CMD uninstall" ;;
    esac
    exit "$setup_rc"
  fi
  _AGSEC_PHASE="agent rules"

  # --- OPT-IN: machine-wide agent discovery, offered after the result ----------------------------
  # A marker block in ~/.claude/CLAUDE.md teaches agents everywhere this Mac has agent-secrets: Claude
  # Code loads it in EVERY repo, AND VS Code Copilot reads it by default (chat.useClaudeMdFile) — so ONE
  # file covers both readers (user-home ~/.claude/rules is NOT default-read by Copilot on stable VS Code).
  # The registry (lib/discovery.sh) also covers any OTHER agent CLI present on this Mac (Codex/Gemini/
  # Zed/Cline, each its own file), DEFERS on any org/MDM-managed machine, and SKIPS unwritable targets.
  # Consent is INFORMED: the prompt NAMES each file it would write + previews the block — never a blind
  # one-keypress fan-out. Offered only on the wizard path, where setup defaults to writing no rules, so a
  # decline holds. Every other path runs headless setup, which writes them itself by default (naming each
  # file first; --no-discovery skips): a piped or agent install is never asked, and never silently skipped.
  # A decline is not a cancel: exit 0, no "Canceled.".
  if _wizard_path && [ "$NO_DISCOVERY" -eq 0 ]; then
    local _plan; _plan="$(agsec_discovery_plan)"
    if [ -z "$_plan" ]; then
      _say "  $_G_ARROW no writable agent surfaces detected (or all are org/MDM-managed), so no agent rules were written"
    else
      local dreply=''
      if [ "$DISCOVERY_YES" -eq 1 ]; then
        dreply=y   # --discovery pre-answered the offer, so it is not asked
      else
        _eprintf '\nMake every coding agent on this Mac aware of agent-secrets?\n'
        _eprintf 'This writes a short, advisory block into each of these files (recorded in the manifest; agent-secrets uninstall removes recorded blocks):\n'
        printf '%s\n' "$_plan" | while IFS="$(printf '\t')" read -r _lbl _pth; do _eprintf '   %s %s\n' "$_G_DOT" "$_pth"; done
        _eprintf 'The agent rules block (advisory: it makes agents aware of the tool; not an enforced guarantee):\n'
        # The block itself is agsec_render_rules output, byte for byte (it carries an integrity marker);
        # only the gutter in front of each of its rows is ours.
        agsec_render_rules claude-md | sed "s/^/     $_G_BAR /" >&2 || true
        _eprintf '[y = yes, write them (recommended)%sEnter = skip (default)]: ' "$_G_SEP"
        read -r dreply || dreply=''
      fi
      case "$dreply" in
        [yY]*)
          local _wrote; _wrote="$(agsec_discovery_install_all)"
          if [ -n "$_wrote" ]; then
            printf '%s\n' "$_wrote" | while IFS= read -r _l; do _say "  $_G_ARROW aware: $_l"; done
          else
            _say "  $_G_ARROW nothing written (targets became unwritable)"
          fi ;;
        *)
          _say "  $_G_ARROW skipped the agent rules. Add them later:"
          _say "      $(printf '%q' "$BIN_DIR/agent-secrets") setup --discovery" ;;
      esac
    fi
  fi
  _say "${_G_OK}Installed agent-secrets $PINNED_TAG."
  return 0
}

# The ~/.claude/CLAUDE.md discovery block is rendered by agsec_render_rules claude-md (lib/common.sh),
# the SINGLE source shared with setup's done-screen + Cursor clipboard — see the call at the opt-in
# block above. install.sh sources lib/common.sh at the top of the install flow, so the renderer is in
# scope here. (The former hand-maintained _discovery_block was deleted: it had silently drifted from
# the canonical rule text, and doctor could not detect the drift.)

# Weekly smoke launchd plist (runs the tool's own smoke command; no value ever printed). Written to a
# sibling temp file and moved into place, or written through a symlinked plist (agsec_commit) so a
# dotfile manager's link survives. The temp file goes on failure and on a stop, or uninstall's rmdir of
# LaunchAgents would find the directory non-empty. The install dir is XML-escaped (sed, because `&` in a
# ${x//…} replacement means the match under newer bash); $label is a constant and needs none.
_install_smoke_plist() {
  local plist="$1" label="$2" install_dir="$3" install_dir_xml tmp q
  install_dir_xml="$(printf '%s' "$install_dir" | LC_ALL=C sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g')" || return 1
  tmp="$(mktemp "$(dirname "$plist")/.smoke.XXXXXX")" || return 1
  printf -v q '%q' "$tmp"; _AGSEC_CLEANUP_CMD="$_AGSEC_CLEANUP_CMD; rm -f -- $q"
  if ! cat >"$tmp" <<PLIST; then
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${label}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${install_dir_xml}/bin/agent-secrets</string>
    <string>smoke</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>${install_dir_xml}/vendor/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>
  <key>StartCalendarInterval</key>
  <dict><key>Weekday</key><integer>1</integer><key>Hour</key><integer>9</integer></dict>
</dict>
</plist>
PLIST
    rm -f "$tmp"; return 1
  fi
  agsec_commit "$tmp" "$plist" 0644
}

main "$@"
