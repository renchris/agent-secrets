#!/usr/bin/env bats
# tests/flows.bats — wizard (unattended), run guard, cursor single-instance guard, restore drill,
# setup's flag conflicts and mode resolution, apiKeyHelper wiring, wrapper backups.
load test_helper
load mode_matrix

# setup with no agent-session variables, so the mode is the one under test.
_setup_cli() { env -u CLAUDECODE -u CLAUDE_CODE -u CURSOR_AGENT -u CURSOR_TRACE_ID -u TERM_PROGRAM bash "$REPO_ROOT/bin/agent-secrets" setup "$@"; }

@test "unattended wizard completes and seeds the first secret" {
  run bash -c "printf '%s' fakeseed_val | AGENT_SECRETS_UNATTENDED=1 bash '$REPO_ROOT/bin/agent-secrets' setup"
  [ "$status" -eq 0 ]
  [[ "$output" == *"set up"* ]] || return 1
  run agsec list
  [[ "$output" == *"ANTHROPIC_API_KEY"* ]] || return 1
  [[ "$output" != *"fakeseed_val"* ]] || return 1
}

@test "unattended wizard seeds from AGENT_SECRETS_SEED_VALUE with NO stdin (deterministic automation)" {
  run env AGENT_SECRETS_HOME="$AGENT_SECRETS_HOME" AGENT_SECRETS_UNATTENDED=1 \
      AGENT_SECRETS_SEED_NAME=OPENAI_API_KEY AGENT_SECRETS_SEED_VALUE=env-seed-xyz \
      bash "$REPO_ROOT/bin/agent-secrets" setup </dev/null
  [ "$status" -eq 0 ]
  run agsec list
  [[ "$output" == *"OPENAI_API_KEY"* ]] || return 1
  [[ "$output" != *"env-seed-xyz"* ]] || return 1     # value never surfaced
}

@test "unattended wizard cannot hang on an open-but-empty stdin (feedback BLOCKER #3)" {
  # Reproduce an agent session's inherited stdin: a pipe held OPEN with no data (never sends EOF). The
  # old val="\$(cat)" blocked here forever; the bounded read must fall through to the placeholder. A perl
  # fork+alarm hard-kills a genuine hang (exit 124) so the suite fails loudly instead of hanging.
  command -v perl >/dev/null 2>&1 || skip "perl needed for the timeout guard"
  local fifo="$AGENT_SECRETS_HOME/seed.fifo"; mkfifo "$fifo"
  exec 9<>"$fifo"                          # hold a writer end open with nothing written
  run perl -e 'my $p=fork; if(!$p){exec @ARGV or die} local $SIG{ALRM}=sub{kill "KILL",$p; exit 124}; alarm 900; waitpid $p,0; exit($? >> 8)' \
      env AGENT_SECRETS_HOME="$AGENT_SECRETS_HOME" AGENT_SECRETS_UNATTENDED=1 \
      bash "$REPO_ROOT/bin/agent-secrets" setup <"$fifo"
  exec 9>&-
  # 124 ⇒ it hung past the alarm (the old cat bug). Print why on any failure: the run takes ~9 s directly
  # but has failed under a loaded bats run, and a bare status check left no trace of the cause.
  [ "$status" -eq 0 ] || { printf 'setup status=%s\n%s\n' "$status" "$(printf '%s\n' "$output" | tail -25)"; return 1; }
  run agsec list
  [[ "$output" == *"ANTHROPIC_API_KEY"* ]] || return 1 # placeholder still seeded the default name
}

@test "wizard is idempotent: re-run mints no second key (resume)" {
  printf '%s' v1 | AGENT_SECRETS_UNATTENDED=1 bash "$REPO_ROOT/bin/agent-secrets" setup >/dev/null 2>&1
  local pub1; pub1=$(cat "$AGENT_SECRETS_HOME/.config/secrets/age.pub")
  printf '%s' v2 | AGENT_SECRETS_UNATTENDED=1 bash "$REPO_ROOT/bin/agent-secrets" setup >/dev/null 2>&1
  local pub2; pub2=$(cat "$AGENT_SECRETS_HOME/.config/secrets/age.pub")
  [ "$pub1" = "$pub2" ]
}

@test "wizard resumes after age.pub is lost — gates idempotency on the private key alone (no silent wedge)" {
  printf '%s' v1 | AGENT_SECRETS_UNATTENDED=1 bash "$REPO_ROOT/bin/agent-secrets" setup >/dev/null 2>&1
  local key1 pub1
  key1=$(cat "$AGENT_SECRETS_HOME/.config/secrets/age.key")
  pub1=$(cat "$AGENT_SECRETS_HOME/.config/secrets/age.pub")
  # age.pub is documented as a "non-secret recipient"; lose it (+ the wrapper, so state is 'partial' →
  # the key ceremony re-runs). Pre-fix: age-keygen refused to overwrite the key, `2>/dev/null` hid it,
  # set -e aborted → silent exit 1, permanent onboarding lockout.
  rm -f "$AGENT_SECRETS_HOME/.config/secrets/age.pub" "$AGENT_SECRETS_HOME/bin/claude-agent"
  run bash -c "printf '%s' v2 | AGENT_SECRETS_UNATTENDED=1 bash '$REPO_ROOT/bin/agent-secrets' setup"
  [ "$status" -eq 0 ]
  [ "$(cat "$AGENT_SECRETS_HOME/.config/secrets/age.key")" = "$key1" ]   # same private key kept, not re-minted
  [ "$(cat "$AGENT_SECRETS_HOME/.config/secrets/age.pub")" = "$pub1" ]   # public recipient re-derived, identical
}

@test "run without -- errors" {
  setup_store
  run agsec run printenv PATH
  [ "$status" -ne 0 ]
  [[ "$output" == *"--"* ]] || return 1
}

@test "cursor-agent single-instance guard blocks when Cursor is running" {
  setup_store
  install -m0755 "$REPO_ROOT/bin/cursor-agent" "$AGENT_SECRETS_HOME/cursor-agent"
  run env AGENT_SECRETS_MOCK_CURSOR_RUNNING=1 AGENT_SECRETS_ROOT="$REPO_ROOT" bash "$REPO_ROOT/bin/cursor-agent"
  [ "$status" -ne 0 ]
  [[ "$output" == *"quit"* ]] || [[ "$output" == *"running"* ]] || [[ "$output" == *"Cursor"* ]] || return 1
}

@test "restore drill: returning-user check + restore_flow decrypts via the saved key" {
  setup_store   # creates a store + writes the age.key
  export AGENT_SECRETS_LIB="$REPO_ROOT/lib"
  # shellcheck source=/dev/null
  . "$REPO_ROOT/lib/common.sh"; . "$REPO_ROOT/lib/keychain.sh"; . "$REPO_ROOT/lib/store.sh"; . "$REPO_ROOT/lib/ui.sh"; . "$REPO_ROOT/lib/restore.sh"
  run restore_returning_user_check
  [ "$output" = "installed" ] || [ "$output" = "partial" ]
  # Save the key, wipe custody, restore from the saved key alone -> store still decrypts.
  local saved; saved=$(cat "$(agsec_age_key_file)")
  rm -f "$(agsec_age_key_file)"
  run bash -c "printf '%s' '$saved' | { . '$REPO_ROOT/lib/common.sh'; . '$REPO_ROOT/lib/keychain.sh'; . '$REPO_ROOT/lib/store.sh'; . '$REPO_ROOT/lib/ui.sh'; . '$REPO_ROOT/lib/restore.sh'; restore_flow; }"
  [ "$status" -eq 0 ]
  [[ "$output" == *"verified"* ]] || [[ "$output" == *"decrypt"* ]] || return 1
}

@test "setup --restore recovers via the CLI: paste the saved key over a restored store -> decrypts" {
  setup_store
  export AGENT_SECRETS_LIB="$REPO_ROOT/lib"
  . "$REPO_ROOT/lib/common.sh"; . "$REPO_ROOT/lib/keychain.sh"; . "$REPO_ROOT/lib/store.sh"
  local saved; saved=$(cat "$(agsec_age_key_file)")
  rm -f "$(agsec_age_key_file)"                 # wipe local key custody; the encrypted store copy remains
  run bash -c "printf '%s' '$saved' | env -u CLAUDECODE -u CLAUDE_CODE -u CURSOR_AGENT -u CURSOR_TRACE_ID -u TERM_PROGRAM bash '$REPO_ROOT/bin/agent-secrets' setup --restore"
  [ "$status" -eq 0 ]
  [[ "$output" == *"verified"* ]] || [[ "$output" == *"decrypt"* ]] || return 1
  run store_extract "$AGENT_SECRETS_CANARY_NAME"   # store decryptable again after the CLI restore
  [ "$status" -eq 0 ]
}

@test "setup refuses to mint a new key over an existing store — sends you to --restore (no strand)" {
  setup_store
  export AGENT_SECRETS_LIB="$REPO_ROOT/lib"
  . "$REPO_ROOT/lib/common.sh"
  rm -f "$(agsec_age_key_file)"                 # store present, key gone: the strand scenario
  # Wipe the wizard state so restore_returning_user_check can't short-circuit to a health check.
  rm -f "$(agsec_wizard_state)" "$AGENT_SECRETS_HOME/bin/claude-agent"
  run bash -c "printf '%s' x | env -u CLAUDECODE -u CLAUDE_CODE -u CURSOR_AGENT -u CURSOR_TRACE_ID -u TERM_PROGRAM AGENT_SECRETS_UNATTENDED=1 bash '$REPO_ROOT/bin/agent-secrets' setup"
  [ "$status" -ne 0 ]
  [[ "$output" == *"--restore"* ]] || return 1              # directed to the restore path, not a silent strand
}

@test "done screen hands over the Cursor User Rules template and the degraded-custody fix (v2 feedback R2+R3)" {
  run bash -c "printf '%s' seedval | AGENT_SECRETS_UNATTENDED=1 bash '$REPO_ROOT/bin/agent-secrets' setup"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Cursor Settings"* ]] || return 1                 # R3: paste-ready User Rules template
  [[ "$output" == *"agent-secrets run -- <cmd>"* ]] || return 1
  [[ "$output" == *"setup --keychain"* ]] || return 1                # R2: unattended run leaves file custody → hint printed
}

@test "unattended wizard with an EMPTY SEED_VALUE falls through to a placeholder (no abort)" {
  run env AGENT_SECRETS_HOME="$AGENT_SECRETS_HOME" AGENT_SECRETS_UNATTENDED=1 \
      AGENT_SECRETS_SEED_NAME=OPENAI_API_KEY AGENT_SECRETS_SEED_VALUE= \
      bash "$REPO_ROOT/bin/agent-secrets" setup </dev/null
  [ "$status" -eq 0 ]
  run agsec list
  [[ "$output" == *"OPENAI_API_KEY"* ]] || return 1     # seeded with the placeholder, not aborted
}

# ---- setup: flag conflicts and --import-env -------------------------------------------------------

@test "setup --restore --keychain exits 2 and writes nothing" {
  run _setup_cli --restore --keychain </dev/null
  [ "$status" -eq 2 ]
  [[ "$output" == *"can't use --restore with --keychain"* ]] || return 1
  [ ! -e "$AGENT_SECRETS_HOME/.config/secrets" ]
}

@test "setup --discovery --no-discovery exits 2 and writes no CLAUDE.md" {
  mkdir -p "$AGENT_SECRETS_HOME/.claude"
  run env CLAUDECODE=1 bash "$REPO_ROOT/bin/agent-secrets" setup --discovery --no-discovery </dev/null
  [ "$status" -eq 2 ]
  [[ "$output" == *"can't use --discovery with --no-discovery"* ]] || return 1
  [ ! -e "$AGENT_SECRETS_HOME/.claude/CLAUDE.md" ]
}

@test "setup --import-env never echoes the token it rejects, and needs at least one NAME" {
  run _setup_cli --import-env 'sk-ant-SEKRET' </dev/null
  [ "$status" -eq 2 ]
  [[ "$output" == *"--import-env"* ]] || return 1
  [[ "$output" != *"SEKRET"* ]] || return 1
  run _setup_cli --import-env , </dev/null
  [ "$status" -eq 2 ]
  run _setup_cli --import-envv=sk-ant-SEKRET </dev/null              # a typo'd flag is named without its value
  [ "$status" -eq 2 ]
  [[ "$output" == *"Unknown option '--import-envv' for setup."* ]] || return 1
  [[ "$output" != *"SEKRET"* ]] || return 1
  [ ! -e "$AGENT_SECRETS_HOME/.config/secrets" ]
}

# ---- setup: mode resolution (R403 mode matrix) ----------------------------------------------------

@test "setup's mode resolution across the mode matrix: only a terminal on stdin and stderr gets the wizard" {
  export AGENT_SECRETS_LIB="$REPO_ROOT/lib"
  # shellcheck disable=SC2016  # expanded by the inner bash
  local probe='. "$REPO_ROOT/cmd/setup.sh"; setup_resolve_mode; printf "MODE[%s|%s]\n" "${HEADLESS:-wizard}" "$HEADLESS_WHY" >&2'
  local mode want got
  for mode in tty stdout-redirected noninteractive-tty ci-tty stdin-piped agent; do
    case "$mode" in
      tty|stdout-redirected)   want='MODE[wizard|]' ;;
      noninteractive-tty|ci-tty) want='MODE[1|non-interactive (--non-interactive or CI)]' ;;
      stdin-piped)             want='MODE[1|no terminal attached]' ;;
      agent)                   want='MODE[1|coding-agent session]' ;;
    esac
    mm_run "$mode" -- bash -c "$probe"
    got="$mm_pty$mm_stderr"
    [ "$mm_status" -eq 0 ] || { echo "$mode: status $mm_status"; return 1; }
    [[ "$got" == *"$want"* ]] || { echo "$mode: want $want, got: $got"; return 1; }
    [ -z "$mm_stdout" ] || { echo "$mode: stdout not empty"; return 1; }
  done
  # stderr redirected on a terminal: every prompt would be invisible.
  local log="$AGENT_SECRETS_HOME/probe.log"
  mm_run tty -- bash -c 'exec 2>"$1"; '"$probe" _ "$log"
  [ "$mm_status" -eq 0 ]
  grep -qF 'MODE[1|stderr is not a terminal]' "$log"
  # setup has no --json: json-tty is a usage error before anything is written.
  mm_run json-tty -- bash "$REPO_ROOT/bin/agent-secrets" setup --json
  [ "$mm_status" -eq 2 ]
  [[ "$mm_pty" == *"Unknown option '--json' for setup."* ]] || return 1
  [[ "$mm_pty" != *"Save it off this Mac now?"* ]] || return 1
  [ ! -e "$AGENT_SECRETS_HOME/.config/secrets" ]
}

@test "CI=1 setup on a terminal goes headless" {
  mm_run ci-tty -- bash "$REPO_ROOT/bin/agent-secrets" setup
  [ "$mm_status" -eq 0 ] || { printf '%s\n' "$mm_pty" | tail -25; return 1; }
  [[ "$mm_pty" == *"(headless)"* ]] || return 1
  [[ "$mm_pty" == *"non-interactive (--non-interactive or CI)"* ]] || return 1
  [[ "$mm_pty" == *"You're set up"* ]] || return 1
  [[ "$mm_pty" != *"Save it off this Mac now?"* ]] || return 1
  [[ "$mm_pty" != *"choose ["* ]] || return 1
}

@test "headless modes run setup to the end with no prompt: noninteractive-tty, stdin-piped, agent, stderr to a log" {
  local base="$AGENT_SECRETS_HOME" mode why out
  for mode in noninteractive-tty stdin-piped agent stderr-log; do
    AGENT_SECRETS_HOME="$base/$mode"; mkdir -p "$AGENT_SECRETS_HOME"; export AGENT_SECRETS_HOME
    case "$mode" in
      stderr-log)
        mm_run tty -- bash -c 'bash "$1" setup 2>"$2"' _ "$REPO_ROOT/bin/agent-secrets" "$AGENT_SECRETS_HOME/setup.log"
        out="$(cat "$AGENT_SECRETS_HOME/setup.log")"; why="stderr is not a terminal" ;;
      *)
        mm_run "$mode" -- bash "$REPO_ROOT/bin/agent-secrets" setup
        out="$mm_pty$mm_stderr" ;;
    esac
    case "$mode" in
      noninteractive-tty) why="non-interactive (--non-interactive or CI)" ;;
      stdin-piped)        why="no terminal attached" ;;
      agent)              why="coding-agent session" ;;
    esac
    [ "$mm_status" -eq 0 ] || { echo "$mode: status $mm_status"; printf '%s\n' "$out" | tail -25; return 1; }
    [[ "$out" == *"(headless)"* ]] || { echo "$mode: not headless"; return 1; }
    [[ "$out" == *"$why"* ]] || { echo "$mode: reason '$why' missing"; return 1; }
    [[ "$out" == *"You're set up"* ]] || { echo "$mode: did not finish"; return 1; }
    [[ "$out$mm_pty$mm_stdout" != *"Save it off this Mac now?"* ]] || { echo "$mode: prompted"; return 1; }
    [[ "$out$mm_pty$mm_stdout" != *"choose ["* ]] || { echo "$mode: prompted"; return 1; }
    case "$mode" in
      stdin-piped|agent) [[ "$mm_stdout" != *"You're set up"* ]] || { echo "$mode: wizard copy on stdout"; return 1; } ;;
    esac
  done
  AGENT_SECRETS_HOME="$base"; export AGENT_SECRETS_HOME
}

# ---- apiKeyHelper wiring (lib/wire.sh) ------------------------------------------------------------

# Loads the libs agsec_wire_apikeyhelper needs, with a store and the helper link in place.
_wire_env() {
  setup_store
  export AGENT_SECRETS_ROOT="$REPO_ROOT"
  . "$REPO_ROOT/lib/ui.sh"; . "$REPO_ROOT/lib/manifest.sh"; . "$REPO_ROOT/lib/wire.sh"
  mkdir -p "$AGENT_SECRETS_HOME/bin" "$AGENT_SECRETS_HOME/.claude"
  ln -sfn "$REPO_ROOT/bin/apiKeyHelper" "$AGENT_SECRETS_HOME/bin/apiKeyHelper"
}

@test "wiring keeps a symlinked settings.json a symlink" {
  _wire_env
  printf '%s' fake-wire-val | store_add ANTHROPIC_API_KEY >/dev/null 2>&1
  local sj="$AGENT_SECRETS_HOME/.claude/settings.json" real="$AGENT_SECRETS_HOME/dotfiles/settings.json"
  mkdir -p "$(dirname "$real")"; printf '{"theme":"dark"}\n' >"$real"; ln -s "$real" "$sj"
  run agsec_wire_apikeyhelper
  [ "$status" -eq 0 ]
  [[ "$output" == *"wired apiKeyHelper"* ]] || return 1
  [ -L "$sj" ]
  [ "$(jq -r .apiKeyHelper "$real")" = "$AGENT_SECRETS_HOME/bin/apiKeyHelper" ]
  [ "$(jq -r .theme "$real")" = dark ]
  run compgen -G "$AGENT_SECRETS_HOME/.claude/.settings.json.*"; [ "$status" -ne 0 ]   # no temp left
  [ ! -e "$AGENT_SECRETS_HOME/.local/state/agent-secrets/.settings.lock" ]              # lock released
}

@test "wiring on an undecryptable store says so and returns 2 (not 'no key stored')" {
  _wire_env
  printf 'not a sops file\n' >"$(agsec_store_file)"
  run agsec_wire_apikeyhelper
  [ "$status" -eq 2 ]
  [[ "$output" == *"can't read the store (decrypt failed)"* ]] || return 1
  [[ "$output" != *"no ANTHROPIC_API_KEY in the store yet"* ]] || return 1
  [ ! -e "$AGENT_SECRETS_HOME/.claude/settings.json" ]
}

@test "wiring waits for the settings lock, then gives up with rc 2 and leaves settings.json alone" {
  _wire_env
  printf '%s' fake-wire-val | store_add ANTHROPIC_API_KEY >/dev/null 2>&1
  local lock="$AGENT_SECRETS_HOME/.local/state/agent-secrets/.settings.lock"
  mkdir -p "$lock"; printf '%s\n' "$$" >"$lock/pid"                     # held by a live process (this test)
  run agsec_wire_apikeyhelper
  [ "$status" -eq 2 ]
  [[ "$output" == *"another agent-secrets run is editing settings.json"* ]] || return 1
  [ ! -e "$AGENT_SECRETS_HOME/.claude/settings.json" ]
  [ "$(cat "$lock/pid")" = "$$" ]                                         # someone else's lock is kept
}

# ---- wrappers (_wire_tools) -----------------------------------------------------------------------

@test "a foreign symlink at ~/bin/claude-agent is backed up and restored" {
  setup_store
  export AGENT_SECRETS_ROOT="$REPO_ROOT"
  local bd="$AGENT_SECRETS_HOME/bin" other="$AGENT_SECRETS_HOME/elsewhere/claude-agent"
  mkdir -p "$bd" "$(dirname "$other")"; printf '#!/bin/sh\n' >"$other"
  ln -s "$other" "$bd/claude-agent"
  run bash -c '. "$REPO_ROOT/cmd/setup.sh"; _wire_tools'
  [ "$status" -eq 0 ]
  [ "$(readlink "$bd/claude-agent")" = "$REPO_ROOT/bin/claude-agent" ]
  local b="$AGENT_SECRETS_HOME/.local/state/agent-secrets/wrapper-claude-agent.bak"
  [ -L "$b" ]; [ "$(readlink "$b")" = "$other" ]
  . "$REPO_ROOT/lib/manifest.sh"
  manifest_rollback >/dev/null 2>&1
  [ -L "$bd/claude-agent" ]; [ "$(readlink "$bd/claude-agent")" = "$other" ]
}

@test "a wrapper backup that fails stops setup before the user's file is replaced" {
  setup_store
  export AGENT_SECRETS_ROOT="$REPO_ROOT"
  local bd="$AGENT_SECRETS_HOME/bin" st="$AGENT_SECRETS_HOME/.local/state/agent-secrets"
  mkdir -p "$bd" "$st"; printf 'mine\n' >"$bd/claude-agent"
  chmod 500 "$st"                                                       # the backup copy cannot be written
  run bash -c '. "$REPO_ROOT/cmd/setup.sh"; _wire_tools'
  chmod 700 "$st"
  [ "$status" -ne 0 ]
  [[ "$output" == *"could not back up your existing $bd/claude-agent"* ]] || return 1
  [ ! -L "$bd/claude-agent" ]; [ "$(cat "$bd/claude-agent")" = mine ]
}
