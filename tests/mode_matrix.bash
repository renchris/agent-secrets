# shellcheck shell=bash
# shellcheck disable=SC2034  # mm_status, mm_stdout, mm_stderr and mm_pty are read by the calling test.
# tests/mode_matrix.bash — run one command in each of the modes a CLI can find itself in.
# `load mode_matrix`. CMD must be an executable, not a shell function: it crosses `script` or perl.
#
#   mm_run MODE -- CMD…   sets $mm_status, $mm_stdout, $mm_stderr and, in the terminal modes, $mm_pty
#   mm_no_ctty CMD…       runs CMD with no controlling terminal
#   mm_styles CMD…        checks that color changes nothing but color (returns 1 and says what differs)
#
#   MODE                stdin      stdout     stderr     terminal  also
#   tty                 pty        pty        pty        yes       only $mm_pty is set
#   stdout-redirected   pty        file       pty        yes       $mm_pty holds stderr
#   stdin-piped         MM_INPUT   file       file       no
#   json-tty            as tty                                     CMD must carry --json
#   noninteractive-tty  as tty                                     AGENT_SECRETS_NONINTERACTIVE=1
#   ci-tty              as tty                                     CI=1
#   agent               /dev/null  file       file       no        CLAUDECODE=1
#
# The terminal modes type nothing: `script` delivers one EOF to the pty and stops reading, even ahead of
# input from a regular file (measured), so a prompt that needs an answer needs an expect drive. A second
# read on that pty never returns. MM_TIMEOUT (seconds, default 300) bounds that in every mode: the run is
# killed and $mm_status is 142.

# shellcheck disable=SC2016  # perl's variables, not the shell's
_MM_SETSID='POSIX::setsid() or die "setsid: $!\n"; exec { $ARGV[0] } @ARGV; exit 127'

# Without a detach, a local run would attach the developer's real terminal and hang on a prompt.
mm_no_ctty() { perl -MPOSIX -e "$_MM_SETSID" -- "$@"; }

# A pending alarm survives exec, so this bounds whatever CMD becomes.
_mm_bound() { perl -e 'alarm shift; exec { $ARGV[0] } @ARGV; exit 127' -- "${MM_TIMEOUT:-300}" "$@"; }

_mm_tmpdir() { mktemp -d "${BATS_TEST_TMPDIR:-${TMPDIR:-/tmp}}/mm.XXXXXX"; }

# `script` writes CRLF, and its EOF on an empty stdin echoes as ^D plus two backspaces.
_mm_clean_pty() { perl -pe 's/\r//g; s/\^D\x08\x08//g' "$1"; }

mm_run() {
  local mode="${1:-}"
  if [ "${2:-}" != "--" ] || [ "$#" -lt 3 ]; then
    printf 'usage: mm_run MODE -- CMD...\n' >&2
    return 2
  fi
  shift 2
  local -a e tty_env
  e=(env -u CLAUDECODE -u CLAUDE_CODE -u CURSOR_AGENT -u CURSOR_TRACE_ID -u TERM_PROGRAM -u CI)
  tty_env=(-u AGSEC_TEST_CONFIRM -u AGSEC_CONFIRM_SRC TERM=xterm)
  case "$mode" in
    tty|stdout-redirected) e+=("${tty_env[@]}") ;;
    json-tty)
      case " $* " in
        *" --json "*) ;;
        *) printf 'mm_run json-tty: CMD must carry --json, or this is plain tty\n' >&2; return 2 ;;
      esac
      e+=("${tty_env[@]}") ;;
    noninteractive-tty) e+=("${tty_env[@]}" AGENT_SECRETS_NONINTERACTIVE=1) ;;
    ci-tty)             e+=("${tty_env[@]}" CI=1) ;;
    stdin-piped) ;;
    agent)              e+=(CLAUDECODE=1) ;;
    *) printf 'mm_run: unknown mode %s\n' "$mode" >&2; return 2 ;;
  esac

  mm_status=0; mm_stdout=''; mm_stderr=''; mm_pty=''
  local d; d="$(_mm_tmpdir)"
  case "$mode" in
    stdin-piped)
      printf '%s' "${MM_INPUT:-}" \
        | _mm_bound "${e[@]}" perl -MPOSIX -e "$_MM_SETSID" -- "$@" >"$d/out" 2>"$d/err" || mm_status=$?
      mm_stdout="$(cat "$d/out")"; mm_stderr="$(cat "$d/err")" ;;
    agent)
      _mm_bound "${e[@]}" perl -MPOSIX -e "$_MM_SETSID" -- "$@" </dev/null >"$d/out" 2>"$d/err" || mm_status=$?
      mm_stdout="$(cat "$d/out")"; mm_stderr="$(cat "$d/err")" ;;
    stdout-redirected)
      : >"$d/out"
      # shellcheck disable=SC2016  # expanded by the inner bash
      _mm_bound "${e[@]}" script -q /dev/null bash -c 'out="$1"; shift; exec "$@" >"$out"' _ "$d/out" "$@" \
        </dev/null >"$d/pty" 2>&1 || mm_status=$?
      mm_stdout="$(cat "$d/out")"; mm_pty="$(_mm_clean_pty "$d/pty")" ;;
    *)
      _mm_bound "${e[@]}" script -q /dev/null "$@" </dev/null >"$d/pty" 2>&1 || mm_status=$?
      mm_pty="$(_mm_clean_pty "$d/pty")" ;;
  esac
  rm -f "$d"/*
  rmdir "$d"
}

# mm_styles CMD…: CMD runs detached with stdin at EOF, so it should not prompt. --no-color and --json are
# appended, so CMD must accept them last. The plain runs must equal the FORCE_COLOR run with ANSI
# stripped, on both streams and in exit status; --json stdout must stay free of ESC under FORCE_COLOR.
mm_styles() {
  local d rc=0 label stream
  d="$(_mm_tmpdir)"
  local -a e
  e=(env -u AGENT_SECRETS_PLAIN -u NO_COLOR -u FORCE_COLOR -u CLAUDECODE -u CLAUDE_CODE -u CURSOR_AGENT
     -u CURSOR_TRACE_ID -u TERM_PROGRAM -u CI)
  _mm_style_run() {
    local p="$d/$1" s=0; shift
    _mm_bound perl -MPOSIX -e "$_MM_SETSID" -- "$@" </dev/null >"$p.out" 2>"$p.err" || s=$?
    printf '%s\n' "$s" >"$p.status"
  }
  _mm_style_run force    "${e[@]}" FORCE_COLOR=1 "$@"
  _mm_style_run no_color "${e[@]}" NO_COLOR=1 "$@"
  _mm_style_run dumb     "${e[@]}" TERM=dumb "$@"
  _mm_style_run flag     "${e[@]}" "$@" --no-color
  _mm_style_run json     "${e[@]}" FORCE_COLOR=1 "$@" --json
  unset -f _mm_style_run

  for stream in out err; do
    perl -pe 's/\e\[[0-9;]*[A-Za-z]//g' "$d/force.$stream" >"$d/stripped.$stream"
    for label in no_color dumb flag; do
      if ! cmp -s "$d/stripped.$stream" "$d/$label.$stream"; then
        printf 'mm_styles: %s std%s differs from the stripped FORCE_COLOR run:\n' "$label" "$stream" >&2
        diff "$d/stripped.$stream" "$d/$label.$stream" >&2 || true
        rc=1
      fi
    done
  done
  for label in no_color dumb flag; do
    if ! cmp -s "$d/force.status" "$d/$label.status"; then
      printf 'mm_styles: %s exit status differs from the FORCE_COLOR run\n' "$label" >&2
      rc=1
    fi
  done
  if grep -q "$(printf '\033')" "$d/json.out"; then
    printf 'mm_styles: --json stdout has ESC under FORCE_COLOR\n' >&2
    rc=1
  fi
  rm -f "$d"/*
  rmdir "$d"
  return "$rc"
}
