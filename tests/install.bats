#!/usr/bin/env bats
# tests/install.bats — install.sh bootstrap: dry-run fidelity + the baked-SHA integrity gate.
# The FIRST tests to exercise install-from-tarball (the audit flagged this coverage gap). Fully
# synthetic-HOME + mocked (curl/brew/launchctl/security/osascript) — no network, no real Keychain.
# Also owns install.sh's argument parsing, help, version and the sh re-exec guard.
bats_require_minimum_version 1.5.0
load test_helper
load install_helper
load mode_matrix

@test "install --dry-run renders the complete plan and mutates nothing" {
  run bash "$REPO_ROOT/install.sh" --dry-run
  [ "$status" -eq 0 ]
  # The plan must name every real change (the dry-run-fidelity finding): dispatcher + wrappers,
  # the settings.json backup, and the launchd job.
  [[ "$output" == *"agent-secrets, claude-agent, cursor-agent, apiKeyHelper"* ]] || return 1
  [[ "$output" == *"back up an existing ~/.claude/settings.json"* ]] || return 1
  [[ "$output" == *"weekly launchd smoke job"* ]] || return 1
  # Zero mutation.
  [ ! -d "$AGENT_SECRETS_HOME/.agent-secrets" ]
  [ ! -e "$AGENT_SECRETS_HOME/bin/agent-secrets" ]
}

@test "default production URL REFUSES to install with no baked digest (supply-chain gate)" {
  _build_mirror
  # No AGENT_SECRETS_BASE_URL → default production URL; install.sh on main carries an empty
  # EXPECTED_SHA256 → it must DIE rather than trust a same-origin sibling .sha256.
  run bash -c "printf '\n' | AGENT_SECRETS_HOME='$AGENT_SECRETS_HOME' bash '$REPO_ROOT/install.sh'"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no baked release digest"* ]] || return 1
  [ ! -d "$AGENT_SECRETS_HOME/.agent-secrets" ]   # nothing unpacked
}

@test "dev-mirror install rejects a tampered tarball (SHA-256 mismatch)" {
  _build_mirror
  # Corrupt the served .sha256 so got != expect on the dev-mirror path (BASE_URL set).
  printf '%s  %s\n' "0000000000000000000000000000000000000000000000000000000000000000" "$PKG" >"$MIRROR/$PKG.sha256"
  run bash -c "printf '\n' | AGENT_SECRETS_BASE_URL='https://mirror.example' AGENT_SECRETS_HOME='$AGENT_SECRETS_HOME' bash '$REPO_ROOT/install.sh'"
  [ "$status" -ne 0 ]
  [[ "$output" == *"SHA-256 mismatch"* ]] || return 1
  [ ! -d "$AGENT_SECRETS_HOME/.agent-secrets" ]
}

@test "baked-digest production install verifies, unpacks, and passes the layout guard" {
  _build_mirror
  # Simulate the released install.sh: bake the real tarball digest in (git-ref channel), production URL.
  local baked="$MIRROR/install.sh"
  sed "s/EXPECTED_SHA256=\"[a-f0-9]*\"/EXPECTED_SHA256=\"$BUILT_SHA\"/" "$REPO_ROOT/install.sh" >"$baked"
  run bash -c "printf '\nfake-value\n' | AGENT_SECRETS_UNATTENDED=1 AGENT_SECRETS_HOME='$AGENT_SECRETS_HOME' bash '$baked'"
  [[ "$output" == *"SHA-256 verified"* ]] || return 1
  # Baked gate passed → the tool unpacked with the expected single-prefix layout, dispatcher symlinked.
  [ -f "$AGENT_SECRETS_HOME/.agent-secrets/lib/common.sh" ]
  [ -L "$AGENT_SECRETS_HOME/bin/agent-secrets" ]
}

@test "install under /bin/sh completes a REAL install — re-execs out of POSIX mode, past manifest.sh (feedback BLOCKER #1)" {
  _build_mirror
  local baked="$MIRROR/install.sh"
  sed "s/EXPECTED_SHA256=\"[a-f0-9]*\"/EXPECTED_SHA256=\"$BUILT_SHA\"/" "$REPO_ROOT/install.sh" >"$baked"
  # macOS /bin/sh IS bash-3.2 in POSIX mode and SETS BASH_VERSION, so a BASH_VERSION-only guard would
  # skip the re-exec and die on lib/manifest.sh's process substitution. Drive a REAL (non-dry-run)
  # install via /bin/sh: it must re-exec and run to completion (past manifest_init + symlink wiring),
  # not merely render --dry-run (which returns before manifest.sh is ever sourced — false confidence).
  run bash -c "printf 'fake-value\n' | AGENT_SECRETS_UNATTENDED=1 AGENT_SECRETS_HOME='$AGENT_SECRETS_HOME' /bin/sh '$baked'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"SHA-256 verified"* ]] || return 1
  [ -L "$AGENT_SECRETS_HOME/bin/agent-secrets" ]                                 # wrappers wired ⇒ got past manifest.sh
  [ -f "$AGENT_SECRETS_HOME/.local/state/agent-secrets/install-manifest.json" ]  # manifest_init ran
}

@test "install in an agent session with CLOSED stdin completes a HEADLESS setup, exit 0 — no human step left" {
  _build_mirror
  local baked="$MIRROR/install.sh"
  sed "s/EXPECTED_SHA256=\"[a-f0-9]*\"/EXPECTED_SHA256=\"$BUILT_SHA\"/" "$REPO_ROOT/install.sh" >"$baked"
  mkdir -p "$AGENT_SECRETS_HOME/.claude"                        # a Claude Code machine → discovery gates in
  # A real Cursor/Claude-Code session has NON-tty stdin (often /dev/null). This used to install the
  # tool and then print "open Terminal.app and run agent-secrets setup" — the agent had to hand the
  # human a command (docs/plans/AGENT_ENTRYPOINT_HEADLESS.md M1). Now the ONE command finishes: real
  # keys, Keychain (mock) custody, store, wrappers, discovery — and nothing secret in the output.
  run bash -c "CLAUDECODE=1 AGENT_SECRETS_HOME='$AGENT_SECRETS_HOME' bash '$baked' </dev/null"
  [ "$status" -eq 0 ]
  [[ "$output" != *"real terminal"* ]] || return 1               # the deferral screen is gone
  [[ "$output" != *"Open Terminal.app"* ]] || return 1
  [[ "$output" == *"headless"* ]] || return 1
  [[ "$output" == *"You're set up"* ]] || return 1
  [[ "$output" != *"AGE-SECRET-KEY"* ]] || return 1              # names-only: no key material printed
  [ -f "$AGENT_SECRETS_HOME/.agent-secrets/lib/common.sh" ]     # tool unpacked
  [ -L "$AGENT_SECRETS_HOME/bin/agent-secrets" ]                # wired onto PATH
  [ -f "$AGENT_SECRETS_HOME/.config/secrets/secrets.env" ]      # the key ceremony RAN
  [ -s "$AGENT_SECRETS_HOME/.config/secrets/age.key" ]
  [ -s "$AGENT_SECRETS_HOME/.config/secrets/recovery.key" ]     # kept on disk (0600) — never deleted unverified
  grep -q "agent-secrets" "$AGENT_SECRETS_HOME/.claude/CLAUDE.md"   # discovery written by default
  grep -q done "$AGENT_SECRETS_HOME/.local/state/agent-secrets/wizard-state.json"
  # The installed tool is USABLE from the same session by full path, and doctor gates green.
  run env AGENT_SECRETS_HOME="$AGENT_SECRETS_HOME" "$AGENT_SECRETS_HOME/bin/agent-secrets" doctor
  [ "$status" -eq 0 ]
}

@test "install --headless --import-env seeds the store from the environment; --no-discovery writes no rules file" {
  _build_mirror
  local baked="$MIRROR/install.sh"
  sed "s/EXPECTED_SHA256=\"[a-f0-9]*\"/EXPECTED_SHA256=\"$BUILT_SHA\"/" "$REPO_ROOT/install.sh" >"$baked"
  mkdir -p "$AGENT_SECRETS_HOME/.claude"
  run bash -c "SEEDED_TOKEN=env-seed-install-3c1 AGENT_SECRETS_HOME='$AGENT_SECRETS_HOME' bash '$baked' --headless --import-env SEEDED_TOKEN --no-discovery </dev/null"
  [ "$status" -eq 0 ]
  [[ "$output" == *"imported SEEDED_TOKEN"* ]] || return 1
  [[ "$output" != *"env-seed-install-3c1"* ]] || return 1        # the value never surfaces
  [ ! -f "$AGENT_SECRETS_HOME/.claude/CLAUDE.md" ]               # --no-discovery honored
  run env AGENT_SECRETS_HOME="$AGENT_SECRETS_HOME" "$AGENT_SECRETS_HOME/bin/agent-secrets" list
  [[ "$output" == *"SEEDED_TOKEN"* ]] || return 1
}

@test "install --dry-run renders the headless plan when there is no tty (no deferral sentence anywhere)" {
  run bash -c "AGENT_SECRETS_HOME='$AGENT_SECRETS_HOME' bash '$REPO_ROOT/install.sh' --dry-run </dev/null"
  [ "$status" -eq 0 ]
  [[ "$output" == *"setup --headless"* ]] || return 1
  [[ "$output" != *"real terminal"* ]] || return 1
}

@test "a required-dependency failure removes the unpacked tool — no unrecorded residue (cleanup trap)" {
  _build_mirror
  local baked="$MIRROR/install.sh"
  sed "s/EXPECTED_SHA256=\"[a-f0-9]*\"/EXPECTED_SHA256=\"$BUILT_SHA\"/" "$REPO_ROOT/install.sh" >"$baked"
  # The corporate failure: no age/sops/gum on PATH, no Homebrew, dep downloads blocked (age is not in the
  # mock mirror). deps_ensure aborts on the REQUIRED age AFTER the tool is unpacked. The cleanup trap must
  # remove ~/.agent-secrets so `agent-secrets uninstall` is never left with un-rollback-able residue.
  run bash -c "PATH='$BATS_TEST_DIRNAME/mocks:/usr/bin:/bin:/usr/sbin:/sbin' AGSEC_MOCK_DL_DIR='$MIRROR' AGENT_SECRETS_DEPS_NO_BREW=1 AGENT_SECRETS_HOME='$AGENT_SECRETS_HOME' bash '$baked' </dev/null"
  [ "$status" -ne 0 ]                                           # required dep unresolved → abort
  [ ! -d "$AGENT_SECRETS_HOME/.agent-secrets" ]                 # trap removed the unpacked tool
  [ ! -e "$AGENT_SECRETS_HOME/bin/agent-secrets" ]             # nothing left wired
}

@test "cleanup trap survives a shell metacharacter (single quote) in the install home (%q quoting)" {
  _build_mirror
  local baked="$MIRROR/install.sh"
  sed "s/EXPECTED_SHA256=\"[a-f0-9]*\"/EXPECTED_SHA256=\"$BUILT_SHA\"/" "$REPO_ROOT/install.sh" >"$baked"
  # An install path with a single quote (e.g. an exotic AGENT_SECRETS_HOME) must not break the cleanup
  # trap's stored command — expand-now single-quoting would abort with an unmatched-quote parse error and
  # leave residue. Force the required-dep failure and assert the tool is still removed.
  local qhome; qhome="$(mktemp -d)/o'brien"; mkdir -p "$qhome"
  run env "PATH=$BATS_TEST_DIRNAME/mocks:/usr/bin:/bin:/usr/sbin:/sbin" "AGSEC_MOCK_DL_DIR=$MIRROR" \
      AGENT_SECRETS_DEPS_NO_BREW=1 "AGENT_SECRETS_HOME=$qhome" bash "$baked" </dev/null
  [ "$status" -ne 0 ]
  [ ! -d "$qhome/.agent-secrets" ]                              # trap ran cleanly despite the quote
  rm -rf "$(dirname "$qhome")"
}

# ---- argument parsing, help, version and the sh re-exec guard -----------------------------------

# ARGS… must be a usage error: exit 2, and no install dir created.
_expect_usage() {
  run bash "$REPO_ROOT/install.sh" "$@" </dev/null
  if [ "$status" -ne 2 ]; then printf 'want exit 2, got %s for: %s\n%s\n' "$status" "$*" "$output" >&2; return 1; fi
  [ ! -e "$AGENT_SECRETS_HOME/.agent-secrets" ] || return 1
}
# ARGS… must pass the parse-only seam: exit 0, no output, no curl call.
_expect_parse_ok() {
  run env AGSEC_PARSE_ONLY=1 AGSEC_MOCK_CURL_LOG="$BATS_TEST_TMPDIR/curl.log" bash "$REPO_ROOT/install.sh" "$@" </dev/null
  if [ "$status" -ne 0 ] || [ -n "$output" ]; then printf 'want a clean parse, got %s for: %s\n%s\n' "$status" "$*" "$output" >&2; return 1; fi
  [ ! -s "$BATS_TEST_TMPDIR/curl.log" ] || return 1
}

@test "install.sh --help, -h and help: usage on stdout, exit 0, empty stderr, no line over 80 columns" {
  local a
  for a in --help -h help; do
    run --separate-stderr bash "$REPO_ROOT/install.sh" "$a"
    [ "$status" -eq 0 ] || return 1
    [[ "$output" == "Usage: install.sh"* ]] || return 1
    [ -z "$stderr" ] || return 1
    [ -z "$(printf '%s\n' "$output" | awk 'length > 80')" ] || return 1
  done
}

@test "install.sh help under sh never fetches or re-execs: the file case and the piped sh -s case" {
  local log="$BATS_TEST_TMPDIR/curl.log"; : >"$log"
  run env AGSEC_MOCK_CURL_LOG="$log" /bin/sh "$REPO_ROOT/install.sh" --help
  [ "$status" -eq 0 ]
  [[ "$output" == "Usage: install.sh"* ]] || return 1
  # The pipe form has no file to re-exec: before the pre-scan it re-fetched, and with the fetch failing it died.
  run env AGSEC_MOCK_CURL_LOG="$log" AGSEC_MOCK_KEYS_FAIL=1 sh -s -- --help <"$REPO_ROOT/install.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == "Usage: install.sh"* ]] || return 1
  [[ "$output" != *"could not re-fetch"* ]] || return 1
  [ ! -s "$log" ]
}

@test "help wins over an unknown flag and a missing value; '--import-env help' stays a value" {
  run --separate-stderr bash "$REPO_ROOT/install.sh" --bogus --help
  [ "$status" -eq 0 ]
  [[ "$output" == "Usage: install.sh"* ]] || return 1
  run --separate-stderr bash "$REPO_ROOT/install.sh" --import-env --help
  [ "$status" -eq 0 ]
  [[ "$output" == "Usage: install.sh"* ]] || return 1
  [ ! -e "$AGENT_SECRETS_HOME/.agent-secrets" ]
  _expect_parse_ok --import-env help
}

@test "install.sh help and version in every mode: stdout only, exit 0, no prompt" {
  local m
  for m in tty stdout-redirected stdin-piped noninteractive-tty ci-tty agent; do
    mm_run "$m" -- bash "$REPO_ROOT/install.sh" --help
    [ "$mm_status" -eq 0 ] || return 1
    case "$m" in
      tty|noninteractive-tty|ci-tty) [[ "$mm_pty" == *"Usage: install.sh"* ]] || return 1 ;;
      stdout-redirected) [[ "$mm_stdout" == "Usage: install.sh"* ]] && [ -z "$mm_pty" ] || return 1 ;;
      *) [[ "$mm_stdout" == "Usage: install.sh"* ]] && [ -z "$mm_stderr" ] || return 1 ;;
    esac
    [[ "$mm_pty$mm_stderr" != *"[Enter]"* ]] || return 1
  done
  mm_run json-tty -- bash "$REPO_ROOT/install.sh" --version --json
  [ "$mm_status" -eq 0 ]
  [[ "$mm_pty" == *"{\"version\":\"$(cat "$REPO_ROOT/VERSION")\"}"* ]] || return 1
}

@test "usage errors exit 2, name the token and a runnable --help, and create nothing" {
  local self; printf -v self 'bash %q' "$REPO_ROOT/install.sh"
  run --separate-stderr bash "$REPO_ROOT/install.sh" --bogus
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"'--bogus'"* ]] || return 1
  [[ "$stderr" == *"    $self --help"* ]] || return 1
  [ -z "$output" ]
  run --separate-stderr bash "$REPO_ROOT/install.sh" --import-env
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"--import-env without <NAME>"* ]] || return 1
  [[ "$stderr" == *"install.sh --help"* ]] || return 1
  [ ! -e "$AGENT_SECRETS_HOME/.agent-secrets" ]
}

@test "usage errors never echo a value; a near-miss option gets one suggestion, a far one none" {
  local a
  for a in --import-envv=SEKRET SEKRET; do
    _expect_usage "$a" || return 1
    [[ "$output" != *SEKRET* ]] || return 1
  done
  _expect_usage -- SEKRET
  [[ "$output" != *SEKRET* ]] || return 1
  _expect_usage --dry-rn
  [[ "$output" == *"Did you mean --dry-run?"* ]] || return 1
  _expect_usage --zzz
  [[ "$output" != *"Did you mean"* ]] || return 1
}

@test "--import-env --dry-run is a usage error before anything runs (it used to drop the dry run)" {
  local log="$BATS_TEST_TMPDIR/curl.log"; : >"$log"
  run env AGSEC_MOCK_CURL_LOG="$log" bash "$REPO_ROOT/install.sh" --import-env --dry-run </dev/null
  [ "$status" -eq 2 ]
  [ ! -e "$AGENT_SECRETS_HOME/.agent-secrets" ]
  [ ! -e "$AGENT_SECRETS_HOME/bin" ]
  [ ! -s "$log" ]
}

@test "parse errors exit 2: empty or bad --import-env, bad Boolean values, contradictions, -- extra" {
  _expect_usage --import-env= || return 1
  _expect_usage --import-env '' || return 1
  _expect_usage --import-env 1BAD || return 1
  _expect_usage --import-env , || return 1
  _expect_usage --import-env ' ' || return 1
  _expect_usage --import-env 'GOOD,A-B' || return 1
  _expect_usage --dry-run=maybe || return 1
  _expect_usage --headless=yes || return 1
  _expect_usage --no-discovery= || return 1
  _expect_usage -- extra || return 1
  _expect_usage --dry-run --no-dry-run || return 1
  _expect_usage --dry-run=false --dry-run || return 1
  _expect_usage --headless --no-headless || return 1
  _expect_usage --discovery --no-discovery || return 1
  _expect_usage --discovery=false --no-discovery=false || return 1
  [[ "$output" != *"line "*": "* ]] || return 1    # tests/one_command.bats pins this glob on install output
}

@test "--import-env='*' is refused whatever the cwd holds (no glob expansion into valid names)" {
  local d="$BATS_TEST_TMPDIR/cwd"; mkdir -p "$d"; : >"$d/GOOD"
  run bash -c 'cd "$1" && AGSEC_PARSE_ONLY=1 bash "$2" --import-env="*"' _ "$d" "$REPO_ROOT/install.sh"
  [ "$status" -eq 2 ]
  run bash -c 'cd "$1" && AGSEC_PARSE_ONLY=1 bash "$2" --import-env "GOOD,?OOD"' _ "$d" "$REPO_ROOT/install.sh"
  [ "$status" -eq 2 ]
}

@test "the parse-only seam accepts the help examples, last-wins --import-env and every negation, with no fetch" {
  local line
  # The examples are read from the help itself, so the two cannot drift apart.
  run bash "$REPO_ROOT/install.sh" --help
  while IFS= read -r line; do
    # shellcheck disable=SC2086  # the example's words are meant to split
    _expect_parse_ok ${line#  bash install.sh} || return 1
  done < <(printf '%s\n' "$output" | grep '^  bash install.sh ')
  _expect_parse_ok --import-env 1BAD --import-env GOOD || return 1
  _expect_parse_ok --import-env 'A, B' --import-env=_X,Y9 || return 1
  _expect_parse_ok --no-dry-run || return 1
  _expect_parse_ok --no-headless || return 1
  _expect_parse_ok --dry-run --dry-run=true || return 1
  _expect_parse_ok --headless=false --no-headless || return 1
  _expect_parse_ok --discovery --discovery=true --no-discovery=false || return 1
  _expect_parse_ok --no-discovery=true --discovery=false || return 1
  _expect_parse_ok --no-color -- || return 1
}

@test "--dry-run=true renders the same plan as --dry-run; --no-color --dry-run exits 0" {
  run bash "$REPO_ROOT/install.sh" --dry-run </dev/null
  [ "$status" -eq 0 ]
  local plain="$output"
  run bash "$REPO_ROOT/install.sh" --dry-run=true </dev/null
  [ "$status" -eq 0 ]
  [ "$output" = "$plain" ]
  run bash "$REPO_ROOT/install.sh" --no-color --dry-run </dev/null
  [ "$status" -eq 0 ]
  [ "$output" = "$plain" ]
}

@test "--debug prints step diagnostics on stderr without tracing (no set -x, no value)" {
  run --separate-stderr env SEEDED=SEKRET bash "$REPO_ROOT/install.sh" --debug --dry-run --import-env SEEDED </dev/null
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"debug: parsed: dry_run=1"* ]] || return 1
  [[ "$stderr" != *SEKRET* ]] || return 1
  [[ "$stderr" != *$'\n+ '* ]] || return 1
  [ -z "$output" ]
}

@test "install's inline --import-env check agrees with setup's _import_env_valid, and also needs one name" {
  local in want got
  # No glob characters here: setup's unquoted word-split would make its verdict depend on the cwd.
  for in in GOOD A,B _X 'A B' 'A,,B' ' A' A1,_b2 1BAD A-B 'GOOD,9X' 'A$B' A.B 'A,B-'; do
    run bash -c 'export AGENT_SECRETS_LIB="$1/lib"; . "$1/cmd/setup.sh"; _import_env_valid "$2"' _ "$REPO_ROOT" "$in"
    want="$status"
    run env AGSEC_PARSE_ONLY=1 bash "$REPO_ROOT/install.sh" --import-env "$in" </dev/null
    case "$status" in 0) got=0 ;; 2) got=1 ;; *) printf 'install exit %s for [%s]\n' "$status" "$in" >&2; return 1 ;; esac
    if [ "$got" != "$want" ]; then printf 'disagree on [%s]: setup %s, install %s\n' "$in" "$want" "$got" >&2; return 1; fi
  done
  # setup accepts a list with no names (its '' arm never runs); install requires at least one.
  for in in , ' ' ',,'; do
    run bash -c 'export AGENT_SECRETS_LIB="$1/lib"; . "$1/cmd/setup.sh"; _import_env_valid "$2"' _ "$REPO_ROOT" "$in"
    [ "$status" -eq 0 ] || return 1
    _expect_usage --import-env "$in" || return 1
  done
}

@test "install.sh --version prints the bare version from the one tag variable; help still wins; --json is JSON" {
  local log="$BATS_TEST_TMPDIR/curl.log" v; : >"$log"; v="$(cat "$REPO_ROOT/VERSION")"
  run --separate-stderr env AGSEC_MOCK_CURL_LOG="$log" bash "$REPO_ROOT/install.sh" --version
  [ "$status" -eq 0 ]
  [ "$output" = "$v" ]
  [ -z "$stderr" ]
  run --separate-stderr env AGSEC_MOCK_CURL_LOG="$log" /bin/sh "$REPO_ROOT/install.sh" -v
  [ "$status" -eq 0 ]
  [ "$output" = "$v" ]
  run bash "$REPO_ROOT/install.sh" --version --help
  [ "$status" -eq 0 ]
  [[ "$output" == "Usage: install.sh"* ]] || return 1
  run --separate-stderr bash "$REPO_ROOT/install.sh" --version --json
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e --arg v "$v" '. == {version: $v}' >/dev/null
  [ ! -s "$log" ]
  # One tag literal, equal to VERSION; the release sed's EXPECTED_SHA256 line keeps its single form.
  grep -qx "AGSEC_PINNED_TAG=\"v$v\"" "$REPO_ROOT/install.sh"
  run grep -cE '"v[0-9]+\.[0-9]+\.[0-9]+"' "$REPO_ROOT/install.sh"
  [ "$output" -eq 1 ]
  run grep -c 'EXPECTED_SHA256="' "$REPO_ROOT/install.sh"
  [ "$output" -eq 1 ]
}

@test "help parity: every option the parser takes is in the help, and every option in the help is parsed" {
  local parsed helped
  # Parser: the arms of main's parse loop plus the version pre-scan (help is pre-scanned the same way).
  parsed="$( { awk '/^  while \[ "\$#" -gt 0 \]; do$/ { on = 1 } on && /^  done$/ { on = 0 } on' "$REPO_ROOT/install.sh" \
                 | sed -nE 's/^      ([-a-z|=*]+)\).*/\1/p'
               sed -nE 's/.*case "\$_a" in --\) break ;; (-v\|--version)\).*/\1/p' "$REPO_ROOT/install.sh"; } \
             | tr '|' '\n' | sed 's/=\*$//' | grep -vxE -- '--|-?\*|help' | sort -u)"
  run bash "$REPO_ROOT/install.sh" --help
  helped="$(printf '%s\n' "$output" | awk '/^Options:$/ { on = 1; next } on && /^$/ { on = 0 } on && /^  -/' \
             | sed -E 's/^  //; s/   .*//; s/\[=[^]]*\]//; s/ <.*//' | tr ',' '\n' | tr -d ' ' | sort -u)"
  if [ "$parsed" != "$helped" ]; then printf 'parser:\n%s\nhelp:\n%s\n' "$parsed" "$helped" >&2; return 1; fi
  [ "$(printf '%s\n' "$parsed" | wc -l)" -ge 13 ]
  [[ "$output" == *"--json"* ]] || return 1    # the version pre-scan's --json is documented on -v's row
}

@test "re-run hints never echo a mirror URL: AGENT_SECRETS_BASE_URL shows as a placeholder" {
  run env AGENT_SECRETS_BASE_URL='https://u:SEKRET@mirror.example' bash "$REPO_ROOT/install.sh" --bogus
  [ "$status" -eq 2 ]
  [[ "$output" != *SEKRET* ]] || return 1
}

@test "in the pipe form the re-run hint is one unwrapped download-then-run line, credentials masked" {
  local log="$BATS_TEST_TMPDIR/curl.log" line; : >"$log"
  run env AGSEC_MOCK_KEYS_FILE="$REPO_ROOT/install.sh" AGSEC_MOCK_CURL_LOG="$log" \
      AGENT_SECRETS_BASE_URL='https://u:SEKRET@mirror.example' \
      AGENT_SECRETS_INSTALL_URL='https://u:SEKRET@mirror.example/install.sh?token=SEKRET' \
      sh -s -- --bogus <"$REPO_ROOT/install.sh"
  [ "$status" -eq 2 ]
  [[ "$output" != *SEKRET* ]] || return 1
  grep -q 'mirror.example/install.sh' "$log"                     # it really took the re-fetch
  line="$(printf '%s\n' "$output" | sed -n 's/^    //p' | tail -1)"
  # shellcheck disable=SC2016  # literal text of the printed command
  [ "$line" = 'f="$(mktemp "${TMPDIR:-/tmp}/agent-secrets-install.XXXXXX")" && curl -fsSL https://***@mirror.example/install.sh -o "$f" && AGENT_SECRETS_BASE_URL=<URL> bash "$f" --help' ]
}

@test "under curl | sh a planted ./sh in the cwd never runs; sh -s and /bin/sh -s take the re-fetch" {
  local d="$BATS_TEST_TMPDIR/cwd" log="$BATS_TEST_TMPDIR/curl.log" url
  url="https://raw.githubusercontent.com/renchris/agent-secrets/v$(cat "$REPO_ROOT/VERSION")/install.sh"
  mkdir -p "$d"; : >"$log"
  printf '#!/bin/sh\n: >"%s/PLANTED-RAN"\n' "$d" >"$d/sh"; chmod +x "$d/sh"
  run bash -c 'cd "$1" && AGSEC_MOCK_KEYS_FILE="$2" AGSEC_MOCK_CURL_LOG="$3" sh -s -- --dry-run <"$2"' \
      _ "$d" "$REPO_ROOT/install.sh" "$log"
  [ "$status" -eq 0 ]
  [ ! -e "$d/PLANTED-RAN" ]
  [[ "$output" == *"agent-secrets installer"* ]] || return 1
  [ "$(cat "$log")" = "-fsSL $url" ]
  : >"$log"
  # $0 is /bin/sh here: it used to be re-exec'd as a script (bash /bin/sh, rc 126).
  run bash -c 'cd "$1" && AGSEC_MOCK_KEYS_FILE="$2" AGSEC_MOCK_CURL_LOG="$3" /bin/sh -s -- --dry-run <"$2"' \
      _ "$d" "$REPO_ROOT/install.sh" "$log"
  [ "$status" -eq 0 ]
  [[ "$output" == *"agent-secrets installer"* ]] || return 1
  [ "$(cat "$log")" = "-fsSL $url" ]
  : >"$log"
  # A real script path stays the file case: re-exec in place, no fetch.
  run env AGSEC_MOCK_CURL_LOG="$log" /bin/sh "$REPO_ROOT/install.sh" --dry-run </dev/null
  [ "$status" -eq 0 ]
  [ ! -s "$log" ]
}

@test "setup gets neither the AGSEC_REEXECED sentinel nor --discovery; --no-color reaches it (argv/env shim)" {
  _build_mirror
  _shim_setup_in_mirror
  local baked argv="$BATS_TEST_TMPDIR/setup.argv" envl="$BATS_TEST_TMPDIR/setup.env"
  baked="$(_bake_install)"
  # /bin/sh takes the guard's file case, which sets and exports the sentinel before the re-exec.
  run env -u NO_COLOR AGSEC_SETUP_ARGV_LOG="$argv" AGSEC_SETUP_ENV_LOG="$envl" \
      /bin/sh "$baked" --discovery --no-color </dev/null
  [ "$status" -eq 0 ]
  [ "$(cat "$argv")" = setup ]                    # no --discovery forwarded on a no-TTY run
  grep -qx AGENT_SECRETS_BIN "$envl"              # the env log is live: install's own export reached it
  grep -qx NO_COLOR "$envl"
  run grep -cx AGSEC_REEXECED "$envl"
  [ "$output" -eq 0 ]
}
