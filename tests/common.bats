#!/usr/bin/env bats
# lib/common.sh: per-stream presentation, the error document, mode, atomic write and lock.
# Names-only: every fixture value here is a fake placeholder.
bats_require_minimum_version 1.5.0
load test_helper

# This suite decides mode and color, so the runner's own agent session or CI must not leak in.
unset CLAUDECODE CLAUDE_CODE CURSOR_AGENT CURSOR_TRACE_ID TERM_PROGRAM CI FORCE_COLOR \
  AGENT_SECRETS_NONINTERACTIVE AGENT_SECRETS_UNATTENDED AGSEC_OUTPUT AGSEC_PARSE_ONLY

src() { . "$REPO_ROOT/lib/common.sh"; }

# Runs bash -c "$1" on a pty, with stdin at EOF. The color vars are cleared so the pty decides.
on_pty() {
  env -u AGENT_SECRETS_PLAIN -u NO_COLOR TERM=xterm script -q /dev/null bash -c "$1" </dev/null
}

@test "receipts go to stderr; ok/attn/bad stay on stdout" {
  src
  local f
  for f in agsec_receipt agsec_receipt_attn agsec_receipt_bad agsec_plan; do
    run --separate-stderr "$f" x
    [ -z "$output" ]
    [[ "$stderr" == *x ]] || return 1
  done
  run --separate-stderr agsec_ok x
  [ "$output" = "✓ x" ]
  [ -z "$stderr" ]
  run --separate-stderr agsec_attn x
  [ "$output" = "⚠ x" ]
  run --separate-stderr agsec_bad x
  [ "$output" = "✗ x" ]
}

@test "stderr color follows stderr's TTY, not stdout's" {
  # stderr on the pty, stdout discarded: colored.
  run on_pty '. "$REPO_ROOT/lib/common.sh"; agsec_note hi 2>&1 >/dev/null'
  [ "$status" -eq 0 ]
  [[ "$output" == *$'\e['* ]] || return 1
  # stdout on the pty, stderr to a file before sourcing (the palette is fixed at source time):
  # stdout's palette colored, the file clean.
  local f="$AGENT_SECRETS_HOME/err"
  run on_pty "exec 2>'$f'; . \"\$REPO_ROOT/lib/common.sh\"; agsec_note hi; agsec_ok row"
  [ "$status" -eq 0 ]
  [[ "$output" == *$'\e['* ]] || return 1
  grep -q hi "$f"
  run grep -c $'\033' "$f"
  [ "$output" = "0" ]
}

@test "FORCE_COLOR colors a pipe; FORCE_COLOR=0, NO_COLOR, --plain, an agent session and TERM=dumb turn it off" {
  local probe='. "$REPO_ROOT/lib/common.sh"; agsec_ok x'
  run env -u AGENT_SECRETS_PLAIN -u NO_COLOR FORCE_COLOR=1 bash -c "$probe"
  [[ "$output" == *$'\e['* ]] || return 1
  run env -u AGENT_SECRETS_PLAIN -u NO_COLOR bash -c "$probe"
  [ "$output" = "✓ x" ]
  run env -u AGENT_SECRETS_PLAIN -u NO_COLOR FORCE_COLOR=0 bash -c "$probe"
  [ "$output" = "✓ x" ]
  run env -u AGENT_SECRETS_PLAIN FORCE_COLOR=1 NO_COLOR=1 bash -c "$probe"
  [ "$output" = "✓ x" ]
  run env -u NO_COLOR FORCE_COLOR=1 AGENT_SECRETS_PLAIN=1 bash -c "$probe"
  [ "$output" = "✓ x" ]
  run env -u AGENT_SECRETS_PLAIN -u NO_COLOR FORCE_COLOR=1 CLAUDECODE=1 bash -c "$probe"
  [ "$output" = "✓ x" ]
  # TERM=dumb is a TTY-branch rule, so it needs a pty to mean anything.
  run on_pty '. "$REPO_ROOT/lib/common.sh"; agsec_ok x'
  [[ "$output" == *$'\e['* ]] || return 1
  run env -u AGENT_SECRETS_PLAIN -u NO_COLOR TERM=dumb script -q /dev/null bash -c "$probe" </dev/null
  [[ "$output" != *$'\e['* ]] || return 1
}

@test "agsec_json_out is compact on a pipe and passes through without jq" {
  src
  run agsec_json_out <<<'{ "a": 1 }'
  [ "$output" = '{"a":1}' ]
  local nojq="$AGENT_SECRETS_HOME/nojq"
  mkdir -p "$nojq"; ln -s "$(command -v cat)" "$nojq/cat"
  run bash -c '. "$REPO_ROOT/lib/common.sh"; PATH="$1"; agsec_json_out' _ "$nojq" <<<'{ "a": 1 }'
  [ "$status" -eq 0 ]
  [ "$output" = '{ "a": 1 }' ]
}

@test "agsec_js escapes every control byte" {
  src
  [ "$(agsec_js $'a\nb\tc\x01"\\')" = 'a\nb\tc\u0001\"\\' ]
  # jq is the independent decoder: every byte below 0x20, plus 0x7f, survives a round trip.
  local i o c input encoded
  for i in $(seq 1 31) 127; do
    printf -v o '%03o' "$i"
    printf -v c "\\$o"
    input="a${c}b"
    encoded="$(agsec_js "$input")"
    [ "$(printf '%s' "$encoded" | LC_ALL=C tr -d '\040-\176' | wc -c | tr -d ' ')" = 0 ] || { echo "raw byte $i"; return 1; }
    [ "$(printf '"%s"' "$encoded" | jq -r 'explode | .[1]')" = "$i" ] || { echo "byte $i"; return 1; }
  done
  # Replacement text is literal, whichever bash runs this.
  [ "$(agsec_js 'a&b\c')" = 'a&b\\c' ]
}

@test "agsec_scan_json finds --json and --format=json before --, and not the space form" {
  src
  agsec_scan_json list --json
  [ "$AGSEC_OUTPUT" = json ]
  AGSEC_OUTPUT=text; agsec_scan_json --format=json
  [ "$AGSEC_OUTPUT" = json ]
  AGSEC_OUTPUT=text; agsec_scan_json run -- cmd --json
  [ "$AGSEC_OUTPUT" = text ]
  agsec_scan_json --format json
  [ "$AGSEC_OUTPUT" = text ]
  agsec_scan_json
  [ "$AGSEC_OUTPUT" = text ]
}

@test "agsec_die in JSON mode: one line on stderr, empty stdout, reason from code" {
  src
  AGSEC_OUTPUT=json
  run --separate-stderr agsec_die "bad thing" 2
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  [ "$(printf '%s\n' "$stderr" | wc -l | tr -d ' ')" = 1 ]
  jq -e '.status=="error" and .reason=="usage" and .message=="bad thing"' <<<"$stderr"
  run --separate-stderr agsec_die "bad thing"
  [ "$status" -eq 1 ]
  jq -e '.reason=="error"' <<<"$stderr"
  run --separate-stderr agsec_die "bad thing" 130
  [ "$status" -eq 130 ]
  jq -e '.reason=="canceled"' <<<"$stderr"
  AGSEC_REASON=undecryptable
  run --separate-stderr agsec_die "bad thing" 1
  jq -e '.reason=="undecryptable"' <<<"$stderr"
}

@test "agsec_die in text mode keeps its first line and exit code" {
  src
  run --separate-stderr agsec_die "bad thing" 3
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  [ "$stderr" = "ERROR bad thing" ]
}

@test "agsec_die with a recovery prints a blank line, the instruction and the 4-space command" {
  src
  run --separate-stderr agsec_die "bad thing" 1 "agent-secrets doctor" "Check the store"
  [ "$stderr" = $'ERROR bad thing\n\nCheck the store:\n    agent-secrets doctor' ]
  run --separate-stderr agsec_die "bad thing" 1 "agent-secrets doctor"
  [ "$stderr" = $'ERROR bad thing\n\nRun:\n    agent-secrets doctor' ]
}

@test "agsec_fail takes exit code and status from the registry" {
  src
  AGSEC_OUTPUT=json
  local row reason code st
  for row in usage:2:error missing_input:2:action_required confirmation_required:2:action_required \
    missing_command:2:error canceled:130:error undecryptable:1:error not_found:1:error \
    conflict:1:error network:1:error partial:1:error error:1:error; do
    IFS=: read -r reason code st <<<"$row"
    run --separate-stderr agsec_fail "$reason" m
    [ "$status" -eq "$code" ] || { echo "$row got $status"; return 1; }
    [ "$(jq -r '.status' <<<"$stderr")" = "$st" ] || { echo "$row: $stderr"; return 1; }
    [ "$(jq -r '.reason' <<<"$stderr")" = "$reason" ] || { echo "$row: $stderr"; return 1; }
  done
}

@test "agsec_canceled exits 130; agsec_need_confirmation exits 2 with status action_required" {
  src
  run --separate-stderr agsec_canceled "stopped"
  [ "$status" -eq 130 ]
  AGSEC_OUTPUT=json
  run --separate-stderr agsec_need_confirmation "remove the store" --yes "agent-secrets uninstall --yes"
  [ "$status" -eq 2 ]
  jq -e '.status=="action_required" and .reason=="confirmation_required"
    and .message=="Can'"'"'t remove the store without --yes in non-interactive mode."
    and .next[0].command=="agent-secrets uninstall --yes"' <<<"$stderr"
}

@test "a JSON error document carries next[].command and next[].argv and no retryable key" {
  src
  AGSEC_OUTPUT=json
  run --separate-stderr agsec_fail usage "bad" "agent-secrets list  --help *" "See the options"
  jq -e '.next == [{"command":"agent-secrets list  --help *","argv":["agent-secrets","list","--help","*"]}]
    and (has("retryable") | not) and (has("warnings") | not)' <<<"$stderr"
  run --separate-stderr agsec_fail usage "bad"
  jq -e 'has("next") | not' <<<"$stderr"
}

@test "agsec_unknown_option exits 2 and prints 'Unknown option' with the help command on its own line" {
  src
  run --separate-stderr agsec_unknown_option list --foo
  [ "$status" -eq 2 ]
  [ "$stderr" = $'ERROR Unknown option \'--foo\' for list.\n\nSee the options:\n    agent-secrets list --help' ]
}

@test "usage helpers never echo a value" {
  src
  run --separate-stderr agsec_unknown_option list --foo=SEKRET
  [ "$status" -eq 2 ]
  [[ "$output$stderr" != *SEKRET* ]] || return 1
  [[ "$stderr" == *"'--foo'"* ]] || return 1
  run --separate-stderr agsec_unexpected_argument add SEKRET
  [ "$status" -eq 2 ]
  [[ "$output$stderr" != *SEKRET* ]] || return 1
  [[ "$stderr" == *"Unexpected argument for add."* ]] || return 1
}

@test "agsec_parse_only_exit exits 0 only when AGSEC_PARSE_ONLY is set" {
  run bash -c '. "$REPO_ROOT/lib/common.sh"; agsec_parse_only_exit; echo reached'
  [ "$status" -eq 0 ]
  [ "$output" = reached ]
  run env AGSEC_PARSE_ONLY=1 bash -c '. "$REPO_ROOT/lib/common.sh"; agsec_parse_only_exit; echo reached; exit 9'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "agsec_deprecated prints once per run; in JSON mode stderr stays empty and the warning is queued" {
  run --separate-stderr bash -c '. "$REPO_ROOT/lib/common.sh"; agsec_deprecated -V --version; agsec_deprecated -V --version; agsec_deprecated --old --new'
  [ "$stderr" = $'WARN -V is deprecated; use --version.\nWARN --old is deprecated; use --new.' ]
  run --separate-stderr bash -c '. "$REPO_ROOT/lib/common.sh"; AGSEC_OUTPUT=json; agsec_deprecated -V --version; agsec_deprecated -V --version; agsec_deprecated --old --new; printf "[%s]" "$AGSEC_WARNINGS"'
  [ -z "$stderr" ]
  jq -e 'length==2 and .[0].reason=="deprecated" and .[0].message=="-V is deprecated; use --version."' <<<"$output"
}

@test "a JSON error document carries queued warnings" {
  src
  AGSEC_OUTPUT=json
  agsec_warn_json stale $'old "x"\nnew'
  run --separate-stderr agsec_fail not_found "gone"
  [ "$status" -eq 1 ]
  jq -e '.warnings == [{"reason":"stale","message":"old \"x\"\nnew"}]' <<<"$stderr"
}

@test "agsec_warn_json writes a normal warning in text mode" {
  src
  run --separate-stderr agsec_warn_json stale "old"
  [ "$stderr" = "WARN old" ]
  [ -z "${AGSEC_WARNINGS:-}" ]
}

@test "JSON mode: SIGTERM writes one canceled error document and exits 143" {
  local err="$AGENT_SECRETS_HOME/err" ready="$AGENT_SECRETS_HOME/ready" pid i rc=0
  # The script's own `wait` is what the signal interrupts; fd 3 is bats's, so the sleep must not keep it.
  # The sleep outlasts any load-delayed kill, and its pid is published so the test can end it.
  bash -c '. "$REPO_ROOT/lib/common.sh"; AGSEC_OUTPUT=json; agsec_json_signal_traps; sleep 120 & echo $! >"$1"; wait $!' _ "$ready" >/dev/null 2>"$err" 3>&- &
  pid=$!
  for i in $(seq 1 300); do [ -s "$ready" ] && break; sleep 0.1; done
  [ -s "$ready" ]
  kill -TERM "$pid"
  wait "$pid" || rc=$?
  kill "$(cat "$ready")" 2>/dev/null || true
  [ "$rc" -eq 143 ]
  [ "$(wc -l <"$err" | tr -d ' ')" = 1 ]
  jq -e '.status=="error" and .reason=="canceled"' "$err"
}

@test "agsec_noninteractive: CI, AGENT_SECRETS_NONINTERACTIVE, agent session and no-tty each imply it; none grants consent" {
  # On a pty with stdin at EOF, script gives the child a pty on 0, 1 and 2: the interactive baseline.
  local probe='. "$REPO_ROOT/lib/common.sh"; if agsec_noninteractive; then echo NON; else echo INT; fi'
  run on_pty "$probe"
  [[ "$output" == *INT* ]] || return 1
  local v
  for v in CI=true AGENT_SECRETS_NONINTERACTIVE=1 AGENT_SECRETS_UNATTENDED=1 CLAUDECODE=1 AGSEC_OUTPUT=json; do
    run env "$v" TERM=xterm script -q /dev/null bash -c "$probe" </dev/null
    [[ "$output" == *NON* ]] || { echo "$v: $output"; return 1; }
  done
  # Either stream off the terminal counts.
  run on_pty ". \"\$REPO_ROOT/lib/common.sh\"; if agsec_noninteractive </dev/null; then echo NON; else echo INT; fi"
  [[ "$output" == *NON* ]] || return 1
  run on_pty ". \"\$REPO_ROOT/lib/common.sh\"; if agsec_noninteractive 2>/dev/null; then echo NON; else echo INT; fi"
  [[ "$output" == *NON* ]] || return 1
  # requested is the narrower signal: an agent session alone does not count as asking for it.
  src
  run agsec_noninteractive_requested
  [ "$status" -ne 0 ]
  CLAUDECODE=1 run agsec_noninteractive_requested
  [ "$status" -ne 0 ]
  CI=1 run agsec_noninteractive_requested
  [ "$status" -eq 0 ]
  # Consent stays a separate act: the refusal helper exits 2 in every non-interactive mode.
  CI=1 run --separate-stderr agsec_need_confirmation "remove it" --yes "agent-secrets uninstall --yes"
  [ "$status" -eq 2 ]
}

@test "agsec_commit preserves mode and writes through a symlink" {
  src
  local d="$AGENT_SECRETS_HOME" tmp
  printf old >"$d/f"; chmod 640 "$d/f"
  tmp="$(agsec_tmp_sibling "$d/f")"
  [ "$(dirname "$tmp")" = "$d" ]
  printf new >"$tmp"
  agsec_commit "$tmp" "$d/f"
  [ "$(cat "$d/f")" = new ]
  [ "$(stat -f %Lp "$d/f")" = 640 ]
  [ ! -e "$tmp" ]

  # An explicit MODE wins; a brand-new target stays at mktemp's 0600.
  printf new | agsec_atomic_write "$d/f" 600
  [ "$(stat -f %Lp "$d/f")" = 600 ]
  printf new | agsec_atomic_write "$d/fresh"
  [ "$(stat -f %Lp "$d/fresh")" = 600 ]

  printf old >"$d/real"; chmod 640 "$d/real"
  ln -s "$d/real" "$d/link"
  printf new | agsec_atomic_write "$d/link"
  [ -L "$d/link" ]
  [ "$(cat "$d/real")" = new ]
  [ "$(stat -f %Lp "$d/real")" = 640 ]
  # No temp left behind: only the files this test made.
  [ "$(find "$d" -name '.*.*' | wc -l | tr -d ' ')" = 0 ]
}

@test "agsec_commit removes the temp and returns 1 on failure, leaving the target alone" {
  src
  local d="$AGENT_SECRETS_HOME/dir" tmp
  mkdir -p "$d/target-is-a-dir"
  tmp="$(agsec_tmp_sibling "$d/f")"
  run agsec_commit "$tmp" "$d/target-is-a-dir"
  [ "$status" -eq 1 ]
  [ ! -e "$tmp" ]
  [ -z "$(ls -A "$d/target-is-a-dir")" ]
  # A link into a missing directory cannot be written through.
  ln -s "$d/missing/real" "$d/dangling"
  tmp="$(agsec_tmp_sibling "$d/f")"
  run agsec_commit "$tmp" "$d/dangling"
  [ "$status" -eq 1 ]
  [ ! -e "$tmp" ]
}

@test "agsec_lock is exclusive, bounded, and steals a dead owner's lock" {
  src
  local lock="$AGENT_SECRETS_HOME/lock" dead start elapsed
  agsec_lock "$lock" 1
  [ "$(cat "$lock/pid")" = "$(exec sh -c 'echo "$PPID"')" ]
  start=$SECONDS
  run agsec_lock "$lock" 1
  elapsed=$((SECONDS - start))
  [ "$status" -eq 1 ]
  [ "$elapsed" -le 20 ]   # proves it is bounded; a tighter figure fails on a loaded machine
  agsec_unlock "$lock"
  [ ! -e "$lock" ]

  dead="$(bash -c 'echo $$')"
  if kill -0 "$dead" 2>/dev/null; then return 1; fi
  mkdir "$lock"; printf '%s\n' "$dead" >"$lock/pid"
  run agsec_lock "$lock" 1
  [ "$status" -eq 0 ]
  [ "$(cat "$lock/pid")" != "$dead" ]
  agsec_unlock "$lock"

  # A crash between the mkdir and the pid write must not wedge the lock forever.
  mkdir "$lock"
  run agsec_lock "$lock" 10
  [ "$status" -eq 0 ]
  [ -s "$lock/pid" ]
}

@test "agsec_lock records the owning subshell, so the owner stays live for its waiters" {
  src
  local lock="$AGENT_SECRETS_HOME/lock" ready="$AGENT_SECRETS_HOME/ready" pid
  # The owner lives until killed, and short sleeps leave no long-lived orphan behind it.
  ( agsec_lock "$lock" 1; : >"$ready"; while :; do sleep 0.2; done ) >/dev/null 2>&1 3>&- &
  pid=$!
  local i
  for i in $(seq 1 300); do [ -e "$ready" ] && break; sleep 0.1; done
  [ -e "$ready" ]
  [ "$(cat "$lock/pid")" = "$pid" ]
  run agsec_lock "$lock" 0
  [ "$status" -eq 1 ]
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}

@test "agsec_sanitize strips ESC, C1 and bidi controls" {
  src
  run agsec_sanitize <<<$'a\e[31mb\tc\xc2\x9bd\xe2\x80\xaee\xe2\x81\xa6f\xef\xbb\xbfg\xe2\x80\x8bh\rcafé'
  [ "$status" -eq 0 ]
  [ "$output" = $'a[31mb\tcdefghcafé' ]
}

@test "agsec_sanitize keeps the text on malformed UTF-8 and drops a raw C1 byte" {
  src
  run --separate-stderr agsec_sanitize < <(printf 'caf\351 ok \233[31m end\n')
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [[ "$output" == *" ok "* ]] || return 1
  [[ "$output" == *" end" ]] || return 1
  [ "$(printf '%s' "$output" | LC_ALL=C tr -d -c '\233\351' | wc -c | tr -d ' ')" = 0 ]
}

@test "AGENT_SECRETS_VERSION, agsec_version and the VERSION file agree (set -u, AGENT_SECRETS_LIB unset)" {
  local want
  want="$(cat "$REPO_ROOT/VERSION")"
  run bash -c 'unset AGENT_SECRETS_LIB; set -euo pipefail; . "$REPO_ROOT/lib/common.sh"; printf "%s %s\n" "$AGENT_SECRETS_VERSION" "$(agsec_version)"'
  [ "$status" -eq 0 ]
  [ "$output" = "$want $want" ]
}

@test "the version falls back to a non-empty literal when VERSION is missing or empty, under set -e" {
  local root="$AGENT_SECRETS_HOME/root"
  mkdir -p "$root/lib"
  cp "$REPO_ROOT/lib/common.sh" "$root/lib/common.sh"
  run --separate-stderr bash -c 'set -euo pipefail; . "$1/lib/common.sh"; agsec_version' _ "$root"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  [ -z "$stderr" ]
  : >"$root/VERSION"
  run bash -c 'set -euo pipefail; . "$1/lib/common.sh"; agsec_version' _ "$root"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  printf '9.9.9' >"$root/VERSION"   # no trailing newline: read fails, the value must still count
  run bash -c 'set -euo pipefail; . "$1/lib/common.sh"; agsec_version' _ "$root"
  [ "$output" = 9.9.9 ]
}

@test "the dispatcher's -V parse of common.sh still yields exactly one version line" {
  run sed -n 's/^AGENT_SECRETS_VERSION="\(.*\)".*/\1/p' "$REPO_ROOT/lib/common.sh"
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
}

@test "lint: TTY and CI checks live only in lib/common.sh" {
  skip "enabled by B8"
  cd "$REPO_ROOT"
  run bash -c "grep -rnE '\[ !? ?-t [012] \]|\\\$\{?CI\b' cmd lib bin/apiKeyHelper bin/claude-agent bin/cursor-agent | grep -v '^lib/common.sh'"
  [ -z "$output" ]
}
