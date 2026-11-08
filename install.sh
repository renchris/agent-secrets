#!/usr/bin/env bash
# install.sh — one-command bootstrap (curl'd).
# FUNCTION-GUARDED (main(){…}; main "$@") so a truncated download can never partial-exec
# Consent gate is the FIRST screen; --dry-run = plan-then-apply (the rendered
# plan is exactly what executes). STOP-ASK gates have NO --force/env bypass.
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
  _agsec_src="$(curl -fsSL "$_agsec_self_url")" || _agsec_src=""
  [ -n "$_agsec_src" ] || { printf 'ERROR: could not re-fetch install.sh to re-exec under bash. Re-run the README one-liner with bash (not sh) — it curl-pipes this URL: %s\n' "$_agsec_self_url" >&2; exit 1; }
  exec bash -c "$_agsec_src" bash "$@"
fi
# The sentinel has done its job (the re-exec'd bash skipped the guard). Exported, it would reach setup and
# everything it runs, so drop it here.
unset AGSEC_REEXECED

set -euo pipefail

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

  _say()  { printf '%s\n' "$*" >&2; }
  _step() { printf '  → %s\n' "$*" >&2; }
  _die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
  _run()  { if [ "$DRY_RUN" -eq 1 ]; then _step "$*"; else _step "$*"; "$@"; fi; }
  _debug() { if [ "$DEBUG" -eq 1 ]; then printf 'debug: %s\n' "$*" >&2; fi; }

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
  local _f_dry="" _f_headless="" _f_disc="" _f_import=0 _flag _val
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
      --no-color)        NO_COLOR=1; export NO_COLOR ;;
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

  # `curl … | bash` binds stdin to the PIPE, so every `[ -t 0 ]` gate reads "no human here" while a
  # real terminal sits in front of the user — which is how the most widely-known install idiom
  # silently degraded into a two-command flow. Rebind stdin to the controlling terminal so the one
  # command stays one command. NEVER inside an agent session: there /dev/tty is the agent's own pty
  # and its transcript is secret-bearing, so that case still defers to a real terminal (below).
  _attach_tty() {
    [ -t 0 ] && return 0
    _agent_session && return 1
    ( exec 3</dev/tty; [ -t 3 ] ) 2>/dev/null || return 1
    exec 0</dev/tty || return 1
    [ -t 0 ]
  }
  if _attach_tty; then _debug "stdin: a terminal"; else _debug "stdin: no terminal (setup will run headless)"; fi

  # --- the plan (rendered identically for consent + dry-run) -------------------
  _render_plan() {
    _say ""
    _say "agent-secrets installer — this will:"
    _say "  • ensure age, sops, jq (reuse yours · Homebrew if present · else pinned, SHA-256-verified downloads — no sudo)"
    _say "  • install the tool under $INSTALL_DIR   (pinned $PINNED_TAG, SHA-256 verified)"
    _say "  • symlink the command + wrappers into $BIN_DIR   (agent-secrets, claude-agent, cursor-agent, apiKeyHelper)"
    _say "  • add a marker-delimited PATH block to $RC_FILE${BASH_RC_FILE:+ (and $BASH_RC_FILE — your login shell is bash)}"
    _say "  • install a weekly launchd smoke job ($SMOKE_LABEL)"
    _say "  • (via 'agent-secrets setup') back up an existing ~/.claude/settings.json as the revert point for its apiKeyHelper edit (wired only once ANTHROPIC_API_KEY is stored)"
    if [ -t 0 ] && [ "$HEADLESS" -eq 0 ] && [ "$DISCOVERY_YES" -eq 1 ]; then
      _say "  • add agent-secrets rules to ~/.claude/CLAUDE.md (+ each present agent CLI's file) so agents in EVERY repo know to use it — advisory, reversible (--discovery, no offer)"
    elif [ -t 0 ] && [ "$HEADLESS" -eq 0 ]; then
      _say "  • OFFER (opt-in) to add agent-secrets rules to ~/.claude/CLAUDE.md so agents in EVERY repo know to use it"
    elif [ "$NO_DISCOVERY" -eq 1 ]; then
      _say "  • skip the machine-wide agent rules (--no-discovery)"
    else
      _say "  • add agent-secrets rules to ~/.claude/CLAUDE.md (+ each present agent CLI's file) so agents in EVERY repo know to use it — advisory, reversible; --no-discovery skips"
    fi
    _say "  • record every change to $STATE_DIR/install-manifest.json (one-command uninstall)"
    if [ -t 0 ] && [ "$HEADLESS" -eq 0 ]; then
      _say "  • run 'agent-secrets setup' at the end — the interactive wizard (keys, first secret, wiring)"
    else
      _say "  • run 'agent-secrets setup --headless' at the end — real keys, Keychain custody, wiring, NO prompts and no secret on any output${IMPORT_ENV:+; import from env: $IMPORT_ENV}"
    fi
    _say ""
  }

  # --- consent gate — FIRST screen, nothing mutates before it ------------------
  if [ "$DRY_RUN" -eq 1 ]; then
    _say "DRY RUN — showing the plan, changing nothing."
    _render_plan
    _say "Re-run without --dry-run to apply exactly this plan."
    return 0
  fi
  _render_plan
  # Consent is an interactive, human gate (no --force/env bypass). When stdin is a TTY, require the
  # keypress. When it is NOT a tty — a piped `curl … | bash`, or a coding-agent session whose stdin is
  # /dev/null or an open-but-empty pipe — there is no human at the terminal: the plan was just shown
  # (the disclosure) and running the installer IS the consent, so proceed. Blocking on `read` here would
  # otherwise abort under `set -e` on EOF (closed stdin) or hang forever (open pipe) — and, for an agent
  # session, would never reach the exit-0 key-ceremony deferral below.
  if [ -t 0 ]; then
    printf '[Enter] continue · [d] show the full dry-run first · Ctrl-C stop: ' >&2
    local reply=""; read -r reply || reply=""
    if [ "$reply" = "d" ] || [ "$reply" = "D" ]; then
      DRY_RUN=1; _render_plan; DRY_RUN=0
      printf '[Enter] continue · Ctrl-C stop: ' >&2; read -r reply || reply=""
    fi
  else
    if _agent_session; then
      _say "(coding-agent session — proceeding with the plan above; setup runs headless)"
    else
      _say "(no terminal on stdin — proceeding with the plan above; setup runs headless)"
    fi
  fi

  # --- preflight: a regular file (or dangling symlink) where we need a directory --------------------
  # `mkdir -p` below would die "File exists" under set -e AFTER partially creating siblings, leaving
  # residue with no manifest to roll back. Catch it here — pre-network, pre-mutation — and name the
  # conflict. The `if`-form is load-bearing: a `[ … ] && [ … ] && _die` chain returns nonzero on the
  # healthy (dir-absent) path and would abort the install under set -e. A symlink TO a directory passes
  # (`[ ! -d ]` follows links), so a legitimately symlinked ~/bin is unaffected.
  local _d
  for _d in "$INSTALL_DIR" "$BIN_DIR" "$STATE_DIR"; do
    if { [ -e "$_d" ] || [ -L "$_d" ]; } && [ ! -d "$_d" ]; then
      _die "$_d already exists and is not a directory — move it aside, then re-run the installer"
    fi
  done

  # --- toolchain: resolved AFTER unpack, from the tool's own lib/deps.sh -----------------------------
  # (This USED to `brew install age sops jq` behind a sudo-gated Homebrew bootstrap — the #1
  #  corporate blocker in ONE_COMMAND_INSTALL_FEEDBACK.md. deps_ensure below now resolves each tool
  #  NO-SUDO: reuse a PATH copy → Homebrew if already present → else a pinned, SHA-256-verified static
  #  binary. It lives in lib/deps.sh, so it can only run once the tarball is unpacked — hence the move.)

  # --- download + SHA-256 verify (never execute an unverified artifact) --------
  local work; work="$(mktemp -d)"
  local pkg="$work/agent-secrets-${PINNED_TAG}.tar.gz"
  local url="$BASE_URL/releases/download/${PINNED_TAG}/agent-secrets-${PINNED_TAG}.tar.gz"
  _say "Downloading ${PINNED_TAG}…"
  _run curl -fsSL "$url" -o "$pkg"
  local got expect
  got="$(shasum -a 256 "$pkg" | awk '{print $1}')"
  if [ -n "$EXPECTED_SHA256" ]; then
    # Production path: the digest was baked into THIS script (git-ref channel) at release-tag time, so a
    # swapped release-asset tarball fails here — real release-asset tamper-evidence, not same-origin trust.
    expect="$EXPECTED_SHA256"; _debug "digest: baked into this install.sh"
  elif [ -n "${AGENT_SECRETS_BASE_URL:-}" ]; then
    # Dev/mirror convenience ONLY (BASE_URL overridden): trust a sibling .sha256 from the mirror you
    # control. This is transport integrity (corruption/partial-download), NOT release-asset tamper-evidence.
    _run curl -fsSL "$url.sha256" -o "$pkg.sha256"
    expect="$(awk '{print $1}' "$pkg.sha256")"; _debug "digest: the mirror's sibling .sha256 (AGENT_SECRETS_BASE_URL is set)"
  else
    _die "this install.sh carries no baked release digest (EXPECTED_SHA256 empty) — it was not cut by the release runbook. Refusing a same-origin .sha256 fallback on the default production URL (it cannot detect a swapped release asset). Install from a published release tag, or set AGENT_SECRETS_BASE_URL to use a dev/mirror."
  fi
  [ "$got" = "$expect" ] || _die "SHA-256 mismatch — refusing to run the downloaded artifact"
  _say "SHA-256 verified."

  # --- unpack the tool ---------------------------------------------------------
  # Was $INSTALL_DIR created by THIS run? A re-run over an existing (live) install must never have its
  # tool dir deleted by the pre-manifest abort trap below (RT6), so only arm that trap when fresh.
  local FRESH_INSTALL=0; [ -d "$INSTALL_DIR" ] || FRESH_INSTALL=1
  _debug "fresh install: $FRESH_INSTALL (1 = an abort removes the unpacked tool)"
  _run mkdir -p "$INSTALL_DIR" "$BIN_DIR" "$STATE_DIR"
  _run tar -xzf "$pkg" -C "$INSTALL_DIR" --strip-components=1
  # Fail LOUDLY on a mis-cut tarball (wrong/missing top-level prefix flattens the layout and would
  # dangle every wrapper symlink) instead of a cryptic `set -e` abort on the first source below. The
  # release runbook pins `git archive --prefix=agent-secrets-${TAG}/` to guarantee the single prefix dir.
  # Check BOTH a lib and the dispatcher: a tarball missing bin/agent-secrets would otherwise dangle the
  # dispatcher symlink, and manifest_record_file (which follows the link) returns 1 → set -e abort AFTER
  # the cleanup trap is disarmed → half-wired install with no rollback.
  [ "$DRY_RUN" -eq 1 ] || { [ -f "$INSTALL_DIR/lib/common.sh" ] && [ -f "$INSTALL_DIR/bin/agent-secrets" ]; } \
    || _die "unexpected tarball layout (need one top-level prefix dir with bin/ + lib/) — re-cut with: git archive --prefix=agent-secrets-\${TAG}/ \${TAG}"

  # Cleanup trap for the pre-manifest window: from here until $INSTALL_DIR is recorded, an abort — e.g. a
  # REQUIRED dependency that can't be fetched on a locked-down network (deps_ensure below) — would strand
  # the unpacked tool with NO manifest to roll back (the residue regression the reorder introduced).
  # Remove ONLY what we just created: $INSTALL_DIR (removed only when created fresh THIS run — a re-run
  # over a live install must never be deleted by an abort) plus the two tool dirs if still empty (rmdir
  # is a no-op on a pre-existing ~/bin holding the user's files). Disarmed the instant the manifest
  # records $INSTALL_DIR, so the success path + uninstall are unaffected.
  # The paths MUST be baked in NOW (%q-quoted so any shell metacharacter in an exotic AGENT_SECRETS_HOME
  # stays safe): a named handler is NOT an option — main()'s locals are already out of scope by the time
  # the EXIT trap fires while the shell unwinds through an `exit` on an abort (verified under bash 3.2).
  if [ "$FRESH_INSTALL" -eq 1 ]; then
    local _cleanup_cmd
    printf -v _cleanup_cmd 'rm -rf -- %q; rmdir -- %q %q 2>/dev/null || true' "$INSTALL_DIR" "$STATE_DIR" "$BIN_DIR"
    # shellcheck disable=SC2064  # expand-now via the pre-built %q string is DELIBERATE (see above)
    trap "$_cleanup_cmd" EXIT
  fi

  # From here on the tool's own libs exist — source them to record artifacts.
  # shellcheck source=/dev/null
  . "$INSTALL_DIR/lib/common.sh"
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
  manifest_record_file "$INSTALL_DIR" >/dev/null 2>&1 || true
  trap - EXIT   # $INSTALL_DIR is now recorded → uninstall can roll it back; disarm the pre-manifest cleanup
  # A pre-existing NON-symlink at a target on PATH is the USER'S own file — `ln -sf` clobbers it and
  # uninstall's `rm -f` of the `file` record would finish the loss. Write-once backup + an `edit` record
  # (appended BEFORE the file record: LIFO rollback removes the symlink first, then restores the file).
  _bak_user_target() {
    local t="$1" b
    if [ -f "$t" ] && [ ! -L "$t" ]; then
      b="$STATE_DIR/$(basename "$t").preinstall.bak"
      [ -f "$b" ] || cp -p "$t" "$b"
      manifest_record_edit "$t" "$b" >/dev/null 2>&1 || true
    fi
  }
  local f
  _bak_user_target "$BIN_DIR/agent-secrets"
  _run ln -sf "$INSTALL_DIR/bin/agent-secrets" "$BIN_DIR/agent-secrets"
  manifest_record_file "$BIN_DIR/agent-secrets"
  for f in claude-agent cursor-agent apiKeyHelper; do
    [ -f "$INSTALL_DIR/bin/$f" ] || continue
    _bak_user_target "$BIN_DIR/$f"
    _run ln -sf "$INSTALL_DIR/bin/$f" "$BIN_DIR/$f"
    manifest_record_file "$BIN_DIR/$f"
  done

  # Idempotent, marker-delimited PATH block → shell rc (recorded for total rollback).
  manifest_pathblock_install "$RC_FILE" "$PATH_MARKER" "export PATH=\"$BIN_DIR:\$PATH\""
  # Bash-login users also get the block in their login rc (see BASH_RC_FILE above); recorded → uninstall
  # strips it via the same _manifest_rb_pathblock.
  if [ -n "$BASH_RC_FILE" ]; then
    manifest_pathblock_install "$BASH_RC_FILE" "$PATH_MARKER" "export PATH=\"$BIN_DIR:\$PATH\""
  fi

  # Weekly launchd smoke job. Written from the tool's own template.
  _run mkdir -p "$HOME_DIR/Library/LaunchAgents"
  _install_smoke_plist "$SMOKE_PLIST" "$SMOKE_LABEL" "$INSTALL_DIR"
  if [ "$DRY_RUN" -eq 0 ]; then
    launchctl bootout "gui/$(id -u)/$SMOKE_LABEL" >/dev/null 2>&1 || true
    launchctl bootstrap "gui/$(id -u)" "$SMOKE_PLIST" >/dev/null 2>&1 || true
    manifest_record_launchd "$SMOKE_LABEL" "$SMOKE_PLIST"
  fi

  # The ~/.claude/settings.json apiKeyHelper edit + its revert point are owned SOLELY by `setup`
  # (_wire_tools): it records a write-once backup when the file pre-existed, or a `created` marker when
  # it did not (rollback then deletes the tool-made file instead of leaving an empty {}). Recording it
  # here too would double the revert record, so the installer intentionally does not.

  # --- OPT-IN: machine-wide agent discovery ------------------------------------
  # A marker block in ~/.claude/CLAUDE.md teaches agents everywhere this Mac has agent-secrets: Claude
  # Code loads it in EVERY repo, AND VS Code Copilot reads it by default (chat.useClaudeMdFile) — so ONE
  # file covers both readers (user-home ~/.claude/rules is NOT default-read by Copilot on stable VS Code).
  # The registry (lib/discovery.sh) also covers any OTHER agent CLI present on this Mac (Codex/Gemini/
  # Zed/Cline, each its own file), DEFERS on any org/MDM-managed machine, and SKIPS unwritable targets.
  # Consent is INFORMED: the prompt NAMES each file it would write + previews the block — never a blind
  # one-keypress fan-out. Interactive stdin only — a piped/CI install NEVER silently edits a global file.
  # Pin AGENT_SECRETS_BIN to the PATH command so the preview and the write share one abs-path (the
  # rendered rules reference THIS binary, not a PATH impostor). Exported, so the headless setup this
  # installer chains into renders the SAME path when it writes discovery itself.
  AGENT_SECRETS_BIN="$BIN_DIR/agent-secrets"; export AGENT_SECRETS_BIN
  # Interactive stdin only, and not under --headless: a headless setup writes discovery ITSELF (by
  # default, announcing every file first; --no-discovery skips) — so a piped/agent install is never
  # asked, and never silently skipped either.
  if [ -t 0 ] && [ "$HEADLESS" -eq 0 ] && [ "$DRY_RUN" -eq 0 ]; then
    local _plan; _plan="$(agsec_discovery_plan)"
    if [ -z "$_plan" ]; then
      _say "  → no writable agent surfaces detected (or all are org/MDM-managed) — machine-wide discovery skipped"
    else
      local dreply=''
      if [ "$DISCOVERY_YES" -eq 1 ]; then
        dreply=y   # --discovery pre-answered the offer, so it is not asked
      else
        printf '\nMake every coding agent on this Mac aware of agent-secrets?\n' >&2
        printf 'This writes a short, reversible, advisory block into EACH of these files (uninstall removes them):\n' >&2
        printf '%s\n' "$_plan" | while IFS="$(printf '\t')" read -r _lbl _pth; do printf '   • %s\n' "$_pth" >&2; done
        printf 'The block (advisory — makes agents aware of the tool; not an enforced guarantee):\n' >&2
        agsec_render_rules claude-md | sed 's/^/     │ /' >&2
        printf '[y = yes, write them (recommended) · Enter = skip]: ' >&2
        read -r dreply || dreply=''
      fi
      case "$dreply" in
        [yY]*)
          local _wrote; _wrote="$(agsec_discovery_install_all)"
          if [ -n "$_wrote" ]; then
            printf '%s\n' "$_wrote" | while IFS= read -r _l; do _say "  → aware: $_l"; done
          else
            _say "  → nothing written (targets became unwritable)"
          fi ;;
        *)
          _say "  → skipped the agent rules. Add them later:"
          _say "      $(printf '%q' "$BIN_DIR/agent-secrets") setup --discovery" ;;
      esac
    fi
  fi

  # --- finish: setup, in the mode this environment can run ----------------------------------------
  # ONE command means setup runs HERE, in every environment. A human at a terminal gets the wizard.
  # An agent session or a no-tty install used to be told "open Terminal.app and run agent-secrets
  # setup" — the human became the runtime. Now `setup` itself detects that nobody can be prompted and
  # runs HEADLESS: real keys minted to files, the Keychain populated over a pipe, no first secret
  # unless --import-env names one already in this environment, and only names/paths/status printed —
  # nothing a transcript could capture. UNATTENDED (tests/CI) still runs with fake values.
  _say ""
  local -a setup_args=()
  if [ "$HEADLESS" -eq 1 ]; then setup_args+=(--headless); fi
  if [ -n "$IMPORT_ENV" ]; then setup_args+=(--import-env "$IMPORT_ENV"); fi
  if [ "$NO_DISCOVERY" -eq 1 ]; then setup_args+=(--no-discovery); fi
  _say "Installed. Running setup…"
  _debug "setup flags: ${setup_args[*]+${setup_args[*]}}"
  _run "$BIN_DIR/agent-secrets" setup ${setup_args[@]+"${setup_args[@]}"}
}

# The ~/.claude/CLAUDE.md discovery block is rendered by agsec_render_rules claude-md (lib/common.sh),
# the SINGLE source shared with setup's done-screen + Cursor clipboard — see the call at the opt-in
# block above. install.sh sources lib/common.sh at the top of the install flow, so the renderer is in
# scope here. (The former hand-maintained _discovery_block was deleted: it had silently drifted from
# the canonical rule text, and doctor could not detect the drift.)

# Weekly smoke launchd plist (runs the tool's own smoke command; no value ever printed).
_install_smoke_plist() {
  local plist="$1" label="$2" install_dir="$3"
  if [ "${DRY_RUN:-0}" -eq 1 ]; then _step "write launchd plist: $plist"; return 0; fi
  cat >"$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${label}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${install_dir}/bin/agent-secrets</string>
    <string>smoke</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>${install_dir}/vendor/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>
  <key>StartCalendarInterval</key>
  <dict><key>Weekday</key><integer>1</integer><key>Hour</key><integer>9</integer></dict>
</dict>
</plist>
PLIST
  chmod 0644 "$plist"
}

main "$@"
