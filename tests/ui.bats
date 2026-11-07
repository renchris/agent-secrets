#!/usr/bin/env bats
# lib/ui.sh streams and prompts, the mode-matrix helper, and the curl and launchctl mock knobs.
# Names-only: no real value appears here.
bats_require_minimum_version 1.5.0
load test_helper
load mode_matrix

# This suite decides mode and color, so the runner's own agent session must not leak in. CI is set on
# purpose: setup() must remove it before any test body runs (see "test_helper unsets CI").
unset CLAUDECODE CLAUDE_CODE CURSOR_AGENT CURSOR_TRACE_ID TERM_PROGRAM FORCE_COLOR \
  AGENT_SECRETS_NONINTERACTIVE AGENT_SECRETS_UNATTENDED AGSEC_OUTPUT
export CI=true

UI='. "$REPO_ROOT/lib/common.sh"; . "$REPO_ROOT/lib/ui.sh";'

@test "test_helper unsets CI" {
  [ -z "${CI+x}" ]
}

# ---- streams ------------------------------------------------------------------------------------

@test "ui_say/ui_title/ui_step write to stderr; ui_menu prints only the pick on stdout" {
  run --separate-stderr bash -c "$UI"' ui_title TITLE; ui_say SAY; ui_step 1 2 STEP; ui_ok OK; ui_warn WARN; ui_bad BAD'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  local w
  for w in "== TITLE ==" SAY "[1/2] STEP" "✓ OK" "⚠ WARN" "✗ BAD"; do
    [[ "$stderr" == *"$w"* ]] || return 1
  done
  run --separate-stderr bash -c "$UI"' printf "2\n" | ui_menu Pick ONE TWO'
  [ "$status" -eq 0 ]
  [ "$output" = TWO ]
  [[ "$stderr" == *Pick* ]] || return 1
  [[ "$stderr" == *ONE* ]] || return 1
}

@test "ui_title and ui_step color follows stderr, not stdout" {
  local f="$AGENT_SECRETS_HOME/err"
  # stdout on the pty, stderr to a file before sourcing, which fixes the palette.
  run env -u AGENT_SECRETS_PLAIN -u NO_COLOR TERM=xterm script -q /dev/null \
    bash -c "exec 2>'$f'; $UI ui_title T; ui_step 1 2 S" </dev/null
  [ "$status" -eq 0 ]
  grep -q '== T ==' "$f"
  run grep -c "$(printf '\033')" "$f"
  [ "$output" = 0 ]
  # stderr on the pty, stdout discarded: colored.
  mm_run tty -- env -u AGENT_SECRETS_PLAIN -u NO_COLOR bash -c "$UI"' ui_title T >/dev/null'
  [ "$mm_status" -eq 0 ]
  [[ "$mm_pty" == *$'\e['* ]] || return 1
}

@test "ui_read_secret's hint is never faint, and its value goes only to stdout" {
  mm_run tty -- env -u AGENT_SECRETS_PLAIN -u NO_COLOR bash -c "$UI"' ui_read_secret V'
  [ "$mm_status" -eq 0 ]
  [[ "$mm_pty" == *"nothing appears as you type"* ]] || return 1
  [[ "$mm_pty" != *$'\e[2m'* ]] || return 1
  run --separate-stderr bash -c "$UI"' printf "fake-placeholder\n" | ui_read_secret V'
  [ "$output" = fake-placeholder ]
  [[ "$stderr" != *fake-placeholder* ]] || return 1
}

# ---- ui_menu ------------------------------------------------------------------------------------

@test "ui_menu: '9' then '2' picks option 2 and says 'Enter a number from 1 to 2'" {
  run --separate-stderr bash -c "$UI"' printf "9\n2\n" | ui_menu Pick ONE TWO'
  [ "$status" -eq 0 ]
  [ "$output" = TWO ]
  [[ "$stderr" == *"Enter a number from 1 to 2."* ]] || return 1
}

@test "ui_menu: answers that only look like a pick are refused" {
  local bad
  for bad in 2x 0 02 -1 3 " 2" 99999999999999999999; do
    run --separate-stderr bash -c "$UI"' printf "%s\n1\n" "$1" | ui_menu Pick ONE TWO' _ "$bad"
    [ "$status" -eq 0 ]
    [ "$output" = ONE ]
    [[ "$stderr" == *"Enter a number from 1 to 2."* ]] || return 1
  done
}

@test "ui_menu: EOF returns 1 with empty stdout" {
  run --separate-stderr bash -c "$UI"' ui_menu Pick ONE TWO </dev/null'
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  # An unterminated answer is also EOF, not a pick.
  run --separate-stderr bash -c "$UI"' printf 2 | ui_menu Pick ONE TWO'
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "ui_menu: four bad answers return 1" {
  run --separate-stderr bash -c "$UI"' printf "a\nb\nc\nd\n2\n" | ui_menu Pick ONE TWO'
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  # Three bad answers still leave a fourth try.
  run --separate-stderr bash -c "$UI"' printf "a\nb\nc\n2\n" | ui_menu Pick ONE TWO'
  [ "$status" -eq 0 ]
  [ "$output" = TWO ]
}

@test "ui_menu: Enter still picks option 1 and the choose line is unchanged" {
  run --separate-stderr bash -c "$UI"' printf "\n" | ui_menu Pick ONE TWO'
  [ "$status" -eq 0 ]
  [ "$output" = ONE ]
  [[ "$stderr" == *"1) ONE   (default)"* ]] || return 1
  # bats trims the trailing space off a captured stream, so match up to the colon (the expect drives
  # match the same prefix).
  local want=$'\n(Ctrl-D cancels)\nchoose [1-2, Enter = 1]:'
  [[ "$stderr" == *"$want"* ]] || return 1
}

# ---- ui_confirm ---------------------------------------------------------------------------------

@test "ui_confirm without a prompt is a programming error; omitted default is n" {
  run --separate-stderr bash -c "$UI"' (ui_confirm </dev/null; echo survived); echo "rc=$?"'
  [ "$status" -eq 0 ]
  [[ "$output" != *survived* ]] || return 1
  [ "$output" != rc=0 ]
  [[ "$stderr" == *"ui_confirm: PROMPT required"* ]] || return 1
  run --separate-stderr bash -c "$UI"' printf "\n" | ui_confirm Go?'
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"Go? [y/N]"* ]] || return 1
  run --separate-stderr bash -c "$UI"' printf "\n" | ui_confirm Go? y'
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"Go? [Y/n]"* ]] || return 1
}

# ---- mode matrix --------------------------------------------------------------------------------

@test "mode_matrix: each mode reports the TTY state it promises" {
  # Leak everything a mode must clear, so a pass shows the helper cleared it.
  export CLAUDECODE=leak CLAUDE_CODE=leak CURSOR_AGENT=leak CURSOR_TRACE_ID=leak TERM_PROGRAM=leak CI=leak
  local probe='for f in 0 1 2; do [ -t $f ] && echo T || echo F; done
[ -e /dev/tty ] && (exec 3</dev/tty) 2>/dev/null && echo CTTY || echo NOCTTY
echo "env=${CLAUDECODE:-}|${CLAUDE_CODE:-}|${CURSOR_AGENT:-}|${CURSOR_TRACE_ID:-}|${TERM_PROGRAM:-}|${CI:-}|${AGENT_SECRETS_NONINTERACTIVE:-}|${AGSEC_TEST_CONFIRM:-}"'
  local onpty=$'T\nT\nT\nCTTY' detached=$'F\nF\nF\nNOCTTY'
  mm_run tty -- sh -c "$probe"
  [ "$mm_pty" = "$onpty"$'\nenv=|||||||' ]
  [ -z "$mm_stdout$mm_stderr" ]
  mm_run json-tty -- sh -c "$probe" _ --json
  [ "$mm_pty" = "$onpty"$'\nenv=|||||||' ]
  mm_run noninteractive-tty -- sh -c "$probe"
  [ "$mm_pty" = "$onpty"$'\nenv=||||||1|' ]
  mm_run ci-tty -- sh -c "$probe"
  [ "$mm_pty" = "$onpty"$'\nenv=|||||1||' ]
  mm_run stdout-redirected -- sh -c "$probe"
  [ "$mm_stdout" = $'T\nF\nT\nCTTY\nenv=|||||||' ]
  mm_run stdin-piped -- sh -c "$probe"
  [ "$mm_stdout" = "$detached"$'\nenv=|||||||1' ]
  mm_run agent -- sh -c "$probe"
  [ "$mm_stdout" = "$detached"$'\nenv=1|||||||1' ]
}

@test "mode_matrix: status and streams are reported per mode, and MM_INPUT reaches stdin" {
  local cmd='read -r a; echo "out=$a"; echo err >&2; exit 7'
  MM_INPUT=$'piped\n' mm_run stdin-piped -- sh -c "$cmd"
  [ "$mm_status" -eq 7 ]
  [ "$mm_stdout" = out=piped ]
  [ "$mm_stderr" = err ]
  mm_run tty -- sh -c "$cmd"
  [ "$mm_status" -eq 7 ]
  [ "$mm_pty" = $'out=\nerr' ]
  mm_run stdout-redirected -- sh -c "$cmd"
  [ "$mm_status" -eq 7 ]
  [ "$mm_stdout" = out= ]
  [ "$mm_pty" = err ]
  mm_run agent -- sh -c "$cmd"
  [ "$mm_status" -eq 7 ]
  [ "$mm_stdout" = out= ]
}

@test "mode_matrix: a misuse is refused rather than run in the wrong mode" {
  run mm_run nosuch -- true
  [ "$status" -eq 2 ]
  run mm_run tty true
  [ "$status" -eq 2 ]
  run mm_run json-tty -- true
  [ "$status" -eq 2 ]
}

@test "mode_matrix: a second read on the pty is killed by MM_TIMEOUT instead of hanging the suite" {
  MM_TIMEOUT=60 mm_run tty -- sh -c 'read -r a; read -r b; echo unreachable'
  [ "$mm_status" -eq 142 ]
  [[ "$mm_pty" != *unreachable* ]] || return 1
}

@test "mm_no_ctty reports NOCTTY and passes the status through" {
  run mm_no_ctty sh -c '[ -e /dev/tty ] && (exec 3</dev/tty) 2>/dev/null && echo CTTY || echo NOCTTY; exit 7'
  [ "$status" -eq 7 ]
  [ "$output" = NOCTTY ]
}

@test "mm_styles accepts the real helpers, and catches copy that changes or ESC in JSON" {
  mm_styles bash -c "$UI"' ui_title T; ui_step 1 2 S; ui_ok O; ui_warn W; ui_bad B
    case "$*" in *--json*) ;; *) agsec_ok row ;; esac' _
  run mm_styles sh -c 'if [ -n "${FORCE_COLOR:-}" ]; then printf "\033[32mok\033[0m more\n"; else printf "ok\n"; fi' _
  [ "$status" -eq 1 ]
  [[ "$output" == *"no_color stdout differs"* ]] || return 1
  run mm_styles sh -c 'case "$*" in *--no-color*) exit 3 ;; esac' _
  [ "$status" -eq 1 ]
  [[ "$output" == *"flag exit status differs"* ]] || return 1
  run mm_styles sh -c 'case "$*" in *--json*) printf "\033[32m{}\033[0m\n" ;; esac' _
  [ "$status" -eq 1 ]
  [[ "$output" == *"--json stdout has ESC"* ]] || return 1
}

# ---- mocks --------------------------------------------------------------------------------------

@test "curl mock logs calls and honours AGSEC_MOCK_CURL_EXIT" {
  local log="$AGENT_SECRETS_HOME/curl.log" out="$AGENT_SECRETS_HOME/dl"
  export AGSEC_MOCK_CURL_LOG="$log"
  run curl -fsS --max-time 5 https://example.invalid/one
  [ "$status" -eq 0 ]
  [ "$(cat "$log")" = "-fsS --max-time 5 https://example.invalid/one" ]
  AGSEC_MOCK_CURL_EXIT=28 run curl -fsS -o "$out" https://example.invalid/two
  [ "$status" -eq 28 ]
  [ ! -e "$out" ]
  [ "$(wc -l <"$log" | tr -d ' ')" = 2 ]
  [ "$(tail -1 "$log")" = "-fsS -o $out https://example.invalid/two" ]
}

@test "curl mock: AGSEC_MOCK_CURL_RETRY_NOTE warns on stderr and still serves the file" {
  local dir="$AGENT_SECRETS_HOME/mirror" out="$AGENT_SECRETS_HOME/dl"
  mkdir -p "$dir"; printf 'tarball\n' >"$dir/a.tgz"
  export AGSEC_MOCK_DL_DIR="$dir"
  AGSEC_MOCK_CURL_RETRY_NOTE=1 run --separate-stderr curl -o "$out" https://example.invalid/a.tgz
  [ "$status" -eq 0 ]
  [ "$stderr" = "Warning: Problem : timeout. Will retry..." ]
  [ "$(cat "$out")" = tarball ]
  run --separate-stderr curl -o "$out" https://example.invalid/a.tgz
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
}

@test "curl mock: AGSEC_MOCK_CURL_SLEEP waits before answering" {
  local start=$SECONDS
  AGSEC_MOCK_CURL_SLEEP=2 AGSEC_MOCK_CURL_EXIT=6 run curl https://example.invalid/x
  [ "$status" -eq 6 ]
  [ $((SECONDS - start)) -ge 1 ]
}

@test "launchctl mock: the bootstrap knob fails bootstrap and list, and nothing else" {
  local db="$AGENT_SECRETS_HOME/.mock-launchd"
  AGSEC_MOCK_LAUNCHCTL_BOOTSTRAP_FAIL=1 run launchctl bootstrap gui/501 x.plist
  [ "$status" -eq 5 ]
  [ ! -e "$db" ]
  AGSEC_MOCK_LAUNCHCTL_BOOTSTRAP_FAIL=1 run launchctl list x
  [ "$status" -eq 113 ]
  run launchctl list x
  [ "$status" -eq 0 ]
  run launchctl bootstrap gui/501 x.plist
  [ "$status" -eq 0 ]
  grep -q loaded "$db"
}
