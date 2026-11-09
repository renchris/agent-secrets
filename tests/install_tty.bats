#!/usr/bin/env bats
# tests/install_tty.bats — install.sh on a real pty: the consent prompt, the discovery offer after the
# result, mode parity with setup, the mode matrix, and every command install prints parses.
# Drives follow tests/wizard_interactive.bats: one 15-minute wall-clock bound per drive, no per-expect
# timeout, and a signal death is a failure (exit 92). rc 99 means expect is missing: a skip, which the
# gate counts and requires to be 0.
load test_helper
load install_helper
load mode_matrix

# A human at a terminal: no agent, CI or unattended marker from the developer's shell, no test seams.
_TTY=(env -u CLAUDECODE -u CLAUDE_CODE -u CURSOR_AGENT -u CURSOR_TRACE_ID -u TERM_PROGRAM -u CI
      -u AGSEC_TEST_CONFIRM -u AGSEC_CONFIRM_SRC -u AGENT_SECRETS_UNATTENDED -u AGENT_SECRETS_NONINTERACTIVE
      -u AGENT_SECRETS_BASE_URL -u CLAUDE_CONFIG_DIR -u CODEX_HOME TERM=xterm)

# Prompt patterns, matched exactly.
CONSENT='[Y/n] '
OFFER='Enter = skip]: '
OFFER_TEXT='Make every coding agent'

# _on PATTERN REPLY: queue one answer for the next _drive. An EOF before PATTERN fails the drive (91).
_STEPS=""
_on() {
  # Unbraced on purpose: the one-braced-argument form of expect substitutes its body again, and an
  # -ex pattern holding [Y/n] then never matches (measured: the drive hangs until its bound).
  _STEPS="$_STEPS$(printf 'expect -ex {%s} { send "%s" } eof { puts "\\nDESYNC-EOF"; exit 91 }' "$1" "$2")"$'\n'
}
# The wizard's whole minimum path (tests/one_command.bats): recovery save later, first secret skipped.
_wizard() { _on 'Save it off this Mac now?' 'n\r'; _on 'choose [1-4, Enter = 1]:' '4\r'; }

# _drive CMD…: spawn CMD on an 80x24 pty in the human-at-a-terminal environment, answer the queued
# prompts, wait for EOF. Returns CMD's exit code; the transcript (CR stripped) is in $out.
_drive() {
  command -v expect >/dev/null 2>&1 || return 99
  local f="$BATS_TEST_TMPDIR/drive.exp" log="$BATS_TEST_TMPDIR/drive.log" rc=0
  {
    printf '%s\n' 'set timeout -1' 'after 900000 { puts "\nDESYNC-TIMEOUT"; exit 90 }' \
      'spawn -noecho {*}$argv' 'stty rows 24 columns 80 < $spawn_out(slave,name)'
    printf '%s' "$_STEPS"
    printf '%s\n' 'expect eof { }' 'catch wait result' \
      'if {[llength $result] > 4} { puts "\nKILLED $result"; exit 92 }' 'exit [lindex $result 3]'
  } >"$f"
  _STEPS=""
  expect "$f" "${_TTY[@]}" "$@" >"$log" 2>&1 || rc=$?
  out="$(_mm_clean_pty "$log")"
  return "$rc"
}
# _drive_status WANT CMD…: run the drive and require exit WANT; a missing expect skips.
_drive_status() {
  local want="$1" rc=0; shift
  _drive "$@" || rc=$?
  [ "$rc" -ne 99 ] || skip "expect not available"
  if [ "$rc" -ne "$want" ]; then printf 'drive: want exit %s, got %s\n%s\n' "$want" "$rc" "$out" >&2; return 1; fi
}

# A Ctrl-C kills install, and on macOS a session leader killed by a signal can sit in exit until its pty
# drains, so the spawn goes through this reaper: it outlives the child and exits 128+signal for it.
# shellcheck disable=SC2016  # perl's variables
_REAP='$p = fork; defined $p or die "fork: $!\n"; if (!$p) { exec { $ARGV[0] } @ARGV; exit 127 }
$SIG{INT} = "IGNORE"; waitpid $p, 0; $s = $?; exit(($s & 127) ? 128 + ($s & 127) : $s >> 8)'

_curl_log() { CURL_LOG="$BATS_TEST_TMPDIR/curl.log"; : >"$CURL_LOG"; export AGSEC_MOCK_CURL_LOG="$CURL_LOG"; }
_baked() { _build_mirror; BAKED="$(_bake_install)"; }
# Nothing was fetched or written: the decline happened before the download.
_untouched() {
  [ ! -s "$CURL_LOG" ] || { printf 'curl ran:\n%s\n' "$(cat "$CURL_LOG")" >&2; return 1; }
  [ ! -e "$AGENT_SECRETS_HOME/.agent-secrets" ] || return 1
  [ ! -e "$AGENT_SECRETS_HOME/bin" ] || return 1
  [ ! -e "$AGENT_SECRETS_HOME/.local" ] || return 1
}
# Line number of the first line containing TEXT in $out (empty when absent).
_line_of() { printf '%s\n' "$out" | grep -nF -- "$1" | head -1 | cut -d: -f1; }

# ---- consent on a pty (B9.5, B10.1) ---------------------------------------------------------------

@test "consent: n cancels with exit 130 and the receipt; nothing is fetched or written (baked mirror)" {
  _baked; _curl_log
  _on "$CONSENT" 'n\r'
  _drive_status 130 bash "$BAKED"
  [[ "$out" == *"Canceled. Nothing was changed."* ]] || return 1
  _untouched
}

@test "consent: an unclear answer asks again, then n cancels with exit 130" {
  _baked; _curl_log
  _on "$CONSENT" 'xyz\r'; _on "$CONSENT" 'n\r'
  _drive_status 130 bash "$BAKED"
  [[ "$out" == *"Please answer y or n."* ]] || return 1
  [[ "$out" == *"Canceled. Nothing was changed."* ]] || return 1
  _untouched
}

@test "consent: three unclear answers ask again, a fourth counts as a decline (exit 130)" {
  _baked; _curl_log
  _on "$CONSENT" 'xyz\r'; _on "$CONSENT" 'maybe\r'; _on "$CONSENT" '?\r'; _on "$CONSENT" 'later\r'
  _drive_status 130 bash "$BAKED"
  [ "$(printf '%s\n' "$out" | grep -c 'Please answer y or n.')" -eq 3 ]
  [ "$(printf '%s\n' "$out" | grep -cF "$CONSENT")" -eq 4 ]
  [[ "$out" == *"Canceled. Nothing was changed."* ]] || return 1
  _untouched
}

@test "consent: Ctrl-D at the prompt cancels with exit 130 and the receipt" {
  _baked; _curl_log
  _on "$CONSENT" '\004'
  _drive_status 130 bash "$BAKED"
  [[ "$out" == *"Canceled. Nothing was changed."* ]] || return 1
  _untouched
}

@test "consent: Ctrl-C at the prompt cancels with exit 130 and the receipt; nothing is fetched or written" {
  _baked; _curl_log
  # A SIGINT that lands while bash still waits on the subshell that printed the prompt is swallowed
  # (bash 3.2 deems it handled by that child, which exited normally) and bash goes on to block in read
  # (measured under load). So wait a second, and repeat the Ctrl-C every 20 s until install is gone.
  _STEPS='proc again {} { catch { send "\003" }; after 20000 again }'$'\n'
  _STEPS="$_STEPS"'expect -ex {[Y/n] } { sleep 1; send "\003"; after 20000 again } eof { puts "\nDESYNC-EOF"; exit 91 }'$'\n'
  _drive_status 130 perl -e "$_REAP" -- bash "$BAKED"
  [[ "$out" == *"Canceled. Nothing was changed."* ]] || return 1
  _untouched
}

@test "consent: --import-env on a terminal plans headless setup and names the import; n exits 130" {
  _curl_log
  _on "$CONSENT" 'n\r'
  _drive_status 130 bash "$REPO_ROOT/install.sh" --import-env B10_SEED
  [[ "$out" == *"run 'agent-secrets setup --headless' at the end"*"; import from env: B10_SEED"* ]] || return 1
  [[ "$out" != *"the interactive wizard"* ]] || return 1
  [[ "$out" != *"OFFER"* ]] || return 1
  _untouched
}

@test "curl | bash on a pty still prompts: stdin is a pipe, the controlling terminal answers" {
  _curl_log
  _on "$CONSENT" 'n\r'
  # shellcheck disable=SC2016  # expanded by sh
  _drive_status 130 sh -c 'cat "$1" | bash -s' _ "$REPO_ROOT/install.sh"
  [[ "$out" == *"Canceled. Nothing was changed."* ]] || return 1
  _untouched
}

# ---- the mode matrix for the consent prompt (R403) -----------------------------------------------
# The unbaked install.sh on the default URL refuses right after consent, so exit 1 with the refusal
# means "got past consent" and nothing is mutated.

@test "mode matrix: the consent prompt appears only where a human can answer it" {
  local tail='proceeding with the plan above' refuse='no baked release digest' m
  _curl_log
  mm_run tty -- bash "$REPO_ROOT/install.sh"
  [ "$mm_status" -eq 130 ]                                   # the prompt read the pty's EOF
  [[ "$mm_pty" == *"$CONSENT"* ]] || return 1
  mm_run stdout-redirected -- bash "$REPO_ROOT/install.sh"
  [ "$mm_status" -eq 130 ]
  [[ "$mm_pty" == *"$CONSENT"* ]] || return 1
  mm_run stdin-piped -- bash "$REPO_ROOT/install.sh"
  [ "$mm_status" -eq 1 ]
  [[ "$mm_stderr" == *"(no terminal: $tail"*"$refuse"* ]] || return 1
  [[ "$mm_stderr" != *"$CONSENT"* ]] || return 1
  mm_run agent -- bash "$REPO_ROOT/install.sh"
  [ "$mm_status" -eq 1 ]
  [[ "$mm_stderr" == *"(coding-agent session: $tail"*"$refuse"* ]] || return 1
  [[ "$mm_stderr" != *"$CONSENT"* ]] || return 1
  # CI and AGENT_SECRETS_NONINTERACTIVE=1 mean nobody answers, even on a terminal (B11).
  for m in ci-tty noninteractive-tty; do
    mm_run "$m" -- bash "$REPO_ROOT/install.sh"
    [ "$mm_status" -eq 1 ] || { printf '%s: exit %s\n' "$m" "$mm_status" >&2; return 1; }
    [[ "$mm_pty" == *"(non-interactive: $tail"*"$refuse"* ]] || return 1
    [[ "$mm_pty" != *"$CONSENT"* ]] || return 1
  done
  # install has no --json, and --non-interactive is not an install option until D10 is answered.
  mm_run json-tty -- bash "$REPO_ROOT/install.sh" --json
  [ "$mm_status" -eq 2 ]
  [[ "$mm_pty" == *"Unknown option '--json'"* ]] || return 1
  mm_run tty -- bash "$REPO_ROOT/install.sh" --non-interactive
  [ "$mm_status" -eq 2 ]
  [[ "$mm_pty" == *"Unknown option '--non-interactive'"* ]] || return 1
  _untouched
}

# ---- the discovery offer after the result (B9.6, B11.4, B10.2), real wizard, baked mirror -----------

@test "offer: y at consent runs the wizard; Enter at the offer writes no rules, exit 0, no 'Canceled.'" {
  _baked
  mkdir -p "$AGENT_SECRETS_HOME/.claude"                        # a surface, so the offer has targets
  _on "$CONSENT" 'y\r'; _wizard; _on "$OFFER" '\r'
  _drive_status 0 bash "$BAKED"
  [[ "$out" == *"run 'agent-secrets setup' at the end — the interactive wizard"* ]] || return 1
  [[ "$out" == *"== agent-secrets setup =="* ]] || return 1    # the plan's wizard is the setup that ran
  [[ "$out" != *"(headless)"* ]] || return 1
  [[ "$out" == *"You're set up"* ]] || return 1
  [[ "$out" == *"$OFFER_TEXT"* ]] || return 1
  [[ "$out" == *"skipped the agent rules. Add them later:"* ]] || return 1
  [[ "$out" != *"Canceled."* ]] || return 1
  [ ! -e "$AGENT_SECRETS_HOME/.claude/CLAUDE.md" ]
  [ -L "$AGENT_SECRETS_HOME/bin/agent-secrets" ]
}

@test "offer: y at the offer writes the block after setup's result" {
  _baked
  mkdir -p "$AGENT_SECRETS_HOME/.claude"
  _on "$CONSENT" '\r'; _wizard; _on "$OFFER" 'y\r'
  _drive_status 0 bash "$BAKED"
  local done_at offer_at aware_at
  done_at="$(_line_of "You're set up")"; offer_at="$(_line_of "$OFFER_TEXT")"; aware_at="$(_line_of '→ aware:')"
  { [ -n "$done_at" ] && [ -n "$offer_at" ] && [ -n "$aware_at" ]; } || return 1
  { [ "$done_at" -lt "$offer_at" ] && [ "$offer_at" -lt "$aware_at" ]; } || return 1
  grep -q 'agent-secrets' "$AGENT_SECRETS_HOME/.claude/CLAUDE.md"
}

@test "offer: --discovery on a terminal asks nothing, writes the rules, and still runs the wizard" {
  _baked
  mkdir -p "$AGENT_SECRETS_HOME/.claude"
  _on "$CONSENT" '\r'; _wizard
  _drive_status 0 bash "$BAKED" --discovery
  [[ "$out" == *"(--discovery, no offer)"* ]] || return 1
  [[ "$out" == *"== agent-secrets setup =="* ]] || return 1    # not setup's standalone --discovery screen
  [[ "$out" != *"setup --discovery =="* ]] || return 1
  [[ "$out" == *"You're set up"* ]] || return 1
  [[ "$out" != *"$OFFER_TEXT"* ]] || return 1
  grep -q 'agent-secrets' "$AGENT_SECRETS_HOME/.claude/CLAUDE.md"
}

@test "offer: --no-discovery on a terminal plans the skip, never offers, and writes no rules" {
  _baked
  mkdir -p "$AGENT_SECRETS_HOME/.claude"
  _on "$CONSENT" '\r'; _wizard
  _drive_status 0 bash "$BAKED" --no-discovery
  [[ "$out" == *"skip the machine-wide agent rules (--no-discovery)"* ]] || return 1
  [[ "$out" == *"You're set up"* ]] || return 1
  [[ "$out" != *"$OFFER_TEXT"* ]] || return 1
  [ ! -e "$AGENT_SECRETS_HOME/.claude/CLAUDE.md" ]
}

@test "offer: --import-env --no-discovery on a terminal runs headless setup and writes no rules" {
  _baked
  mkdir -p "$AGENT_SECRETS_HOME/.claude"
  export B10_SEED=fake-b10-seed-placeholder
  _on "$CONSENT" '\r'
  _drive_status 0 bash "$BAKED" --import-env B10_SEED --no-discovery
  [[ "$out" == *"setup --headless' at the end"*"; import from env: B10_SEED"* ]] || return 1
  [[ "$out" == *"== agent-secrets setup (headless) =="* ]] || return 1
  [[ "$out" == *"imported B10_SEED"* ]] || return 1
  [[ "$out" != *"$B10_SEED"* ]] || return 1
  [[ "$out" != *"$OFFER_TEXT"* ]] || return 1
  [ ! -e "$AGENT_SECRETS_HOME/.claude/CLAUDE.md" ]
}

# ---- mode parity with setup (B10.3) -----------------------------------------------------------------
# The plan's setup line and setup's own title must agree. The plain-terminal row (the wizard line and
# its first prompt) is the first offer test above; these are the rows where setup must go headless.

_headless_agree() {  # LABEL: the plan and the setup that ran both say headless, and no offer was made
  if [[ "$out" != *"run 'agent-secrets setup --headless' at the end"* ]] \
     || [[ "$out" != *"== agent-secrets setup (headless) =="* ]] \
     || [[ "$out" == *"the interactive wizard"* ]] || [[ "$out" == *"$OFFER_TEXT"* ]]; then
    printf '%s: the plan and setup disagree, or an offer was made:\n%s\n' "$1" "$out" >&2
    return 1
  fi
}

@test "mode parity on a pty: --headless, --import-env, agent, CI and 2>log all plan and run headless setup" {
  local row errlog="$BATS_TEST_TMPDIR/stderr.log"
  export B10_SEED=fake-b10-seed-placeholder
  _baked
  for row in headless import agent ci stderr-file; do
    rm -rf "$AGENT_SECRETS_HOME"; mkdir -p "$AGENT_SECRETS_HOME/.claude"
    case "$row" in
      # A human is present: Enter at consent, then setup must not prompt.
      headless) _on "$CONSENT" '\r'; _drive_status 0 bash "$BAKED" --headless || return 1 ;;
      import)   _on "$CONSENT" '\r'; _drive_status 0 bash "$BAKED" --import-env B10_SEED || return 1 ;;
      # Nobody answers: no step is queued, so any read blocks until the drive's bound and fails it.
      agent)    _drive_status 0 env CLAUDECODE=1 bash "$BAKED" || return 1 ;;
      ci)       _drive_status 0 env CI=1 bash "$BAKED" || return 1 ;;
      stderr-file)
        # shellcheck disable=SC2016  # expanded by the inner bash
        _drive_status 0 bash -c 'f="$1"; shift; exec "$@" 2>"$f"' _ "$errlog" bash "$BAKED" || return 1
        out="$(cat "$errlog")" ;;
    esac
    _headless_agree "$row" || return 1
    [[ "$out" != *"$CONSENT"* ]] || [ "$row" = headless ] || [ "$row" = import ] || return 1
    [[ "$out" != *"$B10_SEED"* ]] || return 1
    [ -L "$AGENT_SECRETS_HOME/bin/agent-secrets" ] || return 1
  done
}

@test "mode parity off a pty: no terminal at all plans and runs headless setup, with no prompt" {
  _baked
  mkdir -p "$AGENT_SECRETS_HOME/.claude"
  run mm_no_ctty "${_TTY[@]}" bash "$BAKED" </dev/null
  [ "$status" -eq 0 ]
  out="$output"
  _headless_agree no-terminal
  [[ "$out" == *"(no terminal: proceeding with the plan above"* ]] || return 1
  [[ "$out" != *"$CONSENT"* ]] || return 1
}

# ---- every command install prints parses (B10.4) --------------------------------------------------

_parse_ok() {  # CMDLINE: run the printed command under the parse-only seam: exit 0, no output, no fetch
  : >"$CURL_LOG"
  run env AGSEC_PARSE_ONLY=1 bash -c "$1"
  if [ "$status" -ne 0 ] || [ -n "$output" ] || [ -s "$CURL_LOG" ]; then
    printf 'printed command does not parse cleanly (exit %s): %s\n%s\n' "$status" "$1" "$output" >&2
    return 1
  fi
}

@test "parse: the dry run's next-step command, with its flags, passes install's parse-only seam" {
  local next
  _curl_log
  # A mirror makes the dry run print its next step; a space in the import list exercises its quoting.
  run mm_no_ctty "${_TTY[@]}" AGENT_SECRETS_BASE_URL=https://mirror.example \
      bash "$REPO_ROOT/install.sh" --dry-run --headless --import-env 'A B' --no-discovery --no-color </dev/null
  [ "$status" -eq 0 ]
  next="$(printf '%s\n' "$output" | grep -A1 '^Local checks passed' | sed -n '2s/^    //p')"
  [[ "$next" == "bash "*" --headless --import-env "*" --no-discovery --no-color" ]] || return 1
  _parse_ok "$next"
  run mm_no_ctty "${_TTY[@]}" AGENT_SECRETS_BASE_URL=https://mirror.example \
      bash "$REPO_ROOT/install.sh" --dry-run --discovery --debug </dev/null
  [ "$status" -eq 0 ]
  next="$(printf '%s\n' "$output" | grep -A1 '^Local checks passed' | sed -n '2s/^    //p')"
  [[ "$next" == *" --discovery --debug" ]] || return 1
  # --debug reports the parse on stderr, so its output is debug lines only.
  : >"$CURL_LOG"
  run env AGSEC_PARSE_ONLY=1 bash -c "$next"
  [ "$status" -eq 0 ]
  [ -z "$(printf '%s\n' "$output" | grep -v '^debug: ')" ]
  [ ! -s "$CURL_LOG" ]
}

@test "parse: _usage_die's --help line and the pipe-form re-run command run as printed" {
  local line dl="$BATS_TEST_TMPDIR/dl"
  _curl_log
  # File case: `bash <path> --help`.
  run bash "$REPO_ROOT/install.sh" --bogus
  [ "$status" -eq 2 ]
  line="$(printf '%s\n' "$output" | sed -n 's/^    //p' | tail -1)"
  [[ "$line" == "bash "*" --help" ]] || return 1
  : >"$CURL_LOG"
  run env AGSEC_PARSE_ONLY=1 bash -c "$line"
  [ "$status" -eq 0 ]
  [[ "$output" == "Usage: install.sh"* ]] || return 1
  [ ! -s "$CURL_LOG" ]
  # Pipe case under a mirror: a download-then-run line with AGENT_SECRETS_BASE_URL=<URL>. With a
  # synthetic URL in the placeholder it runs as printed; its own download is its only fetch.
  mkdir -p "$dl"; cp "$REPO_ROOT/install.sh" "$dl/install.sh"
  run mm_no_ctty "${_TTY[@]}" AGSEC_MOCK_KEYS_FILE="$REPO_ROOT/install.sh" AGENT_SECRETS_BASE_URL=https://mirror.example \
      sh -s -- --dry-run --headless --no-discovery <"$REPO_ROOT/install.sh"
  [ "$status" -eq 0 ]
  line="$(printf '%s\n' "$output" | grep -A1 '^Local checks passed' | sed -n '2s/^    //p')"
  [[ "$line" == *' && AGENT_SECRETS_BASE_URL=<URL> bash "$f" --headless --no-discovery' ]] || return 1
  line="${line/<URL>/https://mirror.example}"
  : >"$CURL_LOG"
  run env AGSEC_PARSE_ONLY=1 AGSEC_MOCK_DL_DIR="$dl" TMPDIR="$BATS_TEST_TMPDIR" bash -c "$line"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(grep -c . "$CURL_LOG")" -eq 1 ]
  grep -q '/install.sh -o ' "$CURL_LOG"
}

@test "parse: every dispatcher command install prints passes the dispatcher's parse-only seam" {
  local c
  # Each is printed by install.sh; the grep keeps this list from drifting away from the source.
  for c in ' setup --discovery"' '_AGSEC_BIN_CMD setup"' ' uninstall --dry-run"' '_AGSEC_BIN_CMD uninstall"' \
           'Run agent-secrets doctor later'; do
    grep -qF -- "$c" "$REPO_ROOT/install.sh" || { printf 'install.sh no longer prints: %s\n' "$c" >&2; return 1; }
  done
  for c in 'setup --discovery' setup 'uninstall --dry-run' uninstall doctor; do
    # shellcheck disable=SC2086  # the command's words are meant to split
    run env AGSEC_PARSE_ONLY=1 bash "$REPO_ROOT/bin/agent-secrets" $c </dev/null
    [ "$status" -eq 0 ] || { printf 'agent-secrets %s: exit %s\n%s\n' "$c" "$status" "$output" >&2; return 1; }
  done
}

@test "parse: negative controls — the seams run after validation, so a bad option still exits 2" {
  _curl_log
  run env AGSEC_PARSE_ONLY=1 bash "$REPO_ROOT/install.sh" --bogus </dev/null
  [ "$status" -eq 2 ]
  run env AGSEC_PARSE_ONLY=1 bash "$REPO_ROOT/bin/agent-secrets" setup --bogus </dev/null
  [ "$status" -eq 2 ]
  [ ! -s "$CURL_LOG" ]
}

# ---- transcripts (R401, R404) ---------------------------------------------------------------------

@test "transcripts: the plan renders on a pty at COLUMNS 40, 80 and 120 (kept under the test's tmpdir)" {
  local c
  for c in 40 80 120; do
    mm_run tty -- env COLUMNS="$c" bash "$REPO_ROOT/install.sh" --dry-run
    [ "$mm_status" -eq 0 ] || return 1
    [[ "$mm_pty" == *"agent-secrets installer — this will:"* ]] || return 1
    printf '%s\n' "$mm_pty" >"$BATS_TEST_TMPDIR/plan-$c.txt"
  done
}
