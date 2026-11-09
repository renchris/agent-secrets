#!/usr/bin/env bats
# tests/install_failure.bats — install.sh's downloads, failure outcomes, cleanup and signals: one curl
# budget with a redacted display, the digest refusal before any download, a fresh install that fails
# leaving nothing behind, the real outcome after launchd and setup, and INT/TERM/SIGPIPE handling.
bats_require_minimum_version 1.5.0
load test_helper
load install_helper
load mode_matrix

# Every run starts from a known mode: no agent, CI or unattended marker inherited from the developer's
# shell.
_CLEAN=(env -u CLAUDECODE -u CLAUDE_CODE -u CURSOR_AGENT -u CURSOR_TRACE_ID -u TERM_PROGRAM -u CI
        -u AGENT_SECRETS_UNATTENDED -u AGENT_SECRETS_NONINTERACTIVE -u AGENT_SECRETS_BASE_URL
        -u CLAUDE_CONFIG_DIR -u CODEX_HOME -u AGSEC_DISCOVERY_KEYS)

# A per-test TMPDIR for the installer only, so its work dir can be checked for removal.
_tmpd() { T="$BATS_TEST_TMPDIR/tmpd"; mkdir -p "$T"; }
_tmp_empty() {
  if [ -n "$(ls -A "$T")" ]; then printf 'TMPDIR not empty:\n%s\n' "$(ls -A "$T")" >&2; return 1; fi
}
# Nothing of the tool under the install home (a pre-existing dir a test made is checked by the test).
_no_residue() {
  [ ! -e "$AGENT_SECRETS_HOME/.agent-secrets" ] || return 1
  [ ! -e "$AGENT_SECRETS_HOME/.local" ] || return 1
  [ ! -e "$AGENT_SECRETS_HOME/bin/agent-secrets" ] || return 1
}
# A mirror install with no terminal: the unbaked repo copy, checked against the mirror's .sha256.
# EXTRA holds more VAR=value words for env.
_mirror_install() {
  run mm_no_ctty "${_CLEAN[@]}" AGENT_SECRETS_BASE_URL="${BASE:-https://mirror.example}" AGSEC_MOCK_DL_DIR="$MIRROR" \
      TMPDIR="$T" AGSEC_SETUP_ARGV_LOG="$BATS_TEST_TMPDIR/setup.argv" AGSEC_SETUP_ENV_LOG="$BATS_TEST_TMPDIR/setup.env" \
      ${EXTRA[@]+"${EXTRA[@]}"} bash "$REPO_ROOT/install.sh" </dev/null
}
# A command named NAME, first on the installer's PATH, whose body is the given lines.
_shim() {
  local name="$1"; shift
  mkdir -p "$BATS_TEST_TMPDIR/shim"
  printf '%s\n' '#!/bin/bash' "$@" >"$BATS_TEST_TMPDIR/shim/$name"
  chmod 0755 "$BATS_TEST_TMPDIR/shim/$name"
}

# Background runs for the signal tests: the installer leads its own session and process group, so one
# kill reaches it and every child (the way a terminal's Ctrl-C reaches the foreground group).
_bg_start() {
  BG_OUT="$BATS_TEST_TMPDIR/bg.out"
  perl -MPOSIX -e "$_MM_SETSID" -- "${_CLEAN[@]}" "$@" </dev/null >"$BG_OUT" 2>&1 &
  BG_PID=$!
}
# Waits up to 300 s for PATTERN in FILE.
_wait_for() {
  local i=0
  while [ "$i" -lt 3000 ]; do
    if grep -q -- "$2" "$1" 2>/dev/null; then return 0; fi
    sleep 0.1; i=$((i + 1))
  done
  printf 'timed out waiting for %s in %s\n' "$2" "$1" >&2
  return 1
}
_wait_for_file() {
  local i=0
  while [ ! -e "$1" ] && [ "$i" -lt 3000 ]; do sleep 0.1; i=$((i + 1)); done
  [ -e "$1" ]
}
# Waits up to 300 s for the background run, kills whatever is left of its group, sets BG_STATUS.
_bg_reap() {
  local i=0
  while kill -0 "$BG_PID" 2>/dev/null && [ "$i" -lt 3000 ]; do sleep 0.1; i=$((i + 1)); done
  kill -KILL -- "-$BG_PID" 2>/dev/null || true
  BG_STATUS=0; wait "$BG_PID" || BG_STATUS=$?
  output="$(cat "$BG_OUT")"
}
_group_gone() {
  local left; left="$(ps -axo pgid=,command= | awk -v g="$BG_PID" '$1 == g')"
  if [ -n "$left" ]; then printf 'left behind:\n%s\n' "$left" >&2; return 1; fi
}

# ---- downloads ----------------------------------------------------------------------------------

@test "a download timeout exits 1, names the host and a rerun command on its own line, and removes the work dir" {
  local log="$BATS_TEST_TMPDIR/curl.log"
  _tmpd
  run mm_no_ctty "${_CLEAN[@]}" AGENT_SECRETS_BASE_URL=https://mirror.example AGSEC_MOCK_CURL_EXIT=28 \
      AGSEC_MOCK_CURL_LOG="$log" TMPDIR="$T" bash "$REPO_ROOT/install.sh" </dev/null
  [ "$status" -eq 1 ]
  [[ "$output" == *"Couldn't reach mirror.example."* ]] || return 1
  [[ "$output" == *"✗ Failed to install agent-secrets: download failed."* ]] || return 1
  printf '%s\n' "$output" | grep -qxF "    bash $REPO_ROOT/install.sh"
  [[ "$output" != *"curl exit"* ]] || return 1
  _tmp_empty
  _no_residue
  # Every download carries the whole budget.
  grep -q http "$log"
  ! grep http "$log" | grep -v -- '--connect-timeout 15' || return 1
  ! grep http "$log" | grep -v -- '--max-time 120' || return 1
  ! grep http "$log" | grep -v -- '--retry 3' || return 1
  ! grep http "$log" | grep -v -- '--retry-max-time 300' || return 1
}

@test "any other curl failure says Couldn't download with the raw curl exit and the redacted URL" {
  _tmpd
  run mm_no_ctty "${_CLEAN[@]}" AGENT_SECRETS_BASE_URL='https://u:fake-pw-placeholder@mirror.example/m' \
      AGSEC_MOCK_CURL_EXIT=22 TMPDIR="$T" bash "$REPO_ROOT/install.sh" </dev/null
  [ "$status" -eq 1 ]
  [[ "$output" == *"Couldn't download agent-secrets-v"*".tar.gz from mirror.example."* ]] || return 1
  [[ "$output" == *"curl exit: 22"* ]] || return 1
  [[ "$output" == *"URL: https://***@mirror.example/m/releases/download/"* ]] || return 1
  [[ "$output" != *"fake-pw-placeholder"* ]] || return 1
  _tmp_empty
}

@test "a credentialed mirror installs without printing the credential; retries say Retrying automatically; the work dir goes" {
  local log="$BATS_TEST_TMPDIR/curl.log"
  _tmpd
  _build_mirror
  _shim_setup_in_mirror
  local BASE='https://u:fake-pw-placeholder@mirror.example'
  local -a EXTRA=(AGSEC_MOCK_CURL_RETRY_NOTE=1 AGSEC_MOCK_CURL_LOG="$log")
  _mirror_install
  [ "$status" -eq 0 ]
  [[ "$output" != *"fake-pw-placeholder"* ]] || return 1
  [[ "$output" == *"curl https://***@mirror.example/releases/download/"* ]] || return 1
  [[ "$output" == *"Retrying automatically..."* ]] || return 1
  [[ "$output" != *"Will retry"* ]] || return 1
  # The real URL still reaches curl's argv: the mock serves by it.
  grep -q 'fake-pw-placeholder@mirror.example' "$log"
  [[ "$output" == *"Tool installed at $AGENT_SECRETS_HOME/.agent-secrets. Changes recorded in $AGENT_SECRETS_HOME/.local/state/agent-secrets/install-manifest.json. Running setup..."* ]] || return 1
  [ "$(printf '%s\n' "$output" | tail -n 1)" = "Installed agent-secrets v$(cat "$REPO_ROOT/VERSION")." ]
  _tmp_empty
}

@test "a failed sh re-fetch prints the install URL with its credential and query masked" {
  local log="$BATS_TEST_TMPDIR/curl.log"
  run env -u AGSEC_REEXECED AGENT_SECRETS_INSTALL_URL='https://u:fake-pw-placeholder@raw.example/install.sh?t=fake-q' \
      AGSEC_MOCK_CURL_EXIT=22 AGSEC_MOCK_CURL_LOG="$log" /bin/sh -s <"$REPO_ROOT/install.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"could not re-fetch install.sh"*"https://***@raw.example/install.sh"* ]] || return 1
  [[ "$output" != *"fake-pw-placeholder"* ]] || return 1
  [[ "$output" != *"fake-q"* ]] || return 1
  grep -q 'raw.example/install.sh' "$log"   # it really took the re-fetch
}

@test "an unbaked copy on the default URL refuses before any download or write" {
  local log="$BATS_TEST_TMPDIR/curl.log"
  _tmpd
  run mm_no_ctty "${_CLEAN[@]}" AGSEC_MOCK_CURL_LOG="$log" TMPDIR="$T" bash "$REPO_ROOT/install.sh" </dev/null
  [ "$status" -ne 0 ]
  [[ "$output" == *"no baked release digest"* ]] || return 1
  [ ! -s "$log" ]
  _tmp_empty
  _no_residue
  [ ! -e "$AGENT_SECRETS_HOME/bin" ]
}

# ---- failure leaves nothing ---------------------------------------------------------------------

@test "a mis-cut tarball leaves no .agent-secrets, no directories this run made, and no work dir" {
  local x
  _tmpd
  _build_mirror
  x="$BATS_TEST_TMPDIR/recut"; mkdir -p "$x/wrap"
  tar -xzf "$MIRROR/$PKG" -C "$x/wrap"
  ( cd "$x" && COPYFILE_DISABLE=1 tar -czf "$MIRROR/$PKG" wrap )   # one prefix too many
  _mirror_digest
  _mirror_install
  [ "$status" -eq 1 ]
  [[ "$output" == *"unexpected tarball layout"* ]] || return 1
  [[ "$output" == *"✗ Failed to install agent-secrets: unpack failed."* ]] || return 1
  _no_residue
  [ ! -e "$AGENT_SECRETS_HOME/bin" ]
  _tmp_empty
}

@test "a required-dependency failure keeps a pre-existing empty ~/bin and removes what the run made" {
  _tmpd
  _build_mirror
  mkdir "$AGENT_SECRETS_HOME/bin"
  run mm_no_ctty "${_CLEAN[@]}" "PATH=$BATS_TEST_DIRNAME/mocks:/usr/bin:/bin:/usr/sbin:/sbin" \
      AGENT_SECRETS_BASE_URL=https://mirror.example AGSEC_MOCK_DL_DIR="$MIRROR" AGENT_SECRETS_DEPS_NO_BREW=1 \
      TMPDIR="$T" bash "$REPO_ROOT/install.sh" </dev/null
  [ "$status" -eq 1 ]
  [[ "$output" == *"✗ Failed to install agent-secrets: toolchain failed."* ]] || return 1
  [ -d "$AGENT_SECRETS_HOME/bin" ]
  _no_residue
  _tmp_empty
}

@test "a failed manifest record of the tool dir exits 1 and removes the fresh tool dir" {
  local real_jq; real_jq="$(command -v jq)"
  _tmpd
  _build_mirror
  # shellcheck disable=SC2016  # the shim's own variables
  _shim jq 'for a in "$@"; do case "$a" in *"$AGSEC_T_FAIL_PATH"*) exit 1 ;; esac; done' \
           'exec "$AGSEC_T_REAL_JQ" "$@"'
  local -a EXTRA=("PATH=$BATS_TEST_TMPDIR/shim:$PATH" AGSEC_T_REAL_JQ="$real_jq"
                  AGSEC_T_FAIL_PATH="$AGENT_SECRETS_HOME/.agent-secrets")
  _mirror_install
  [ "$status" -eq 1 ]
  [[ "$output" == *"Couldn't record $AGENT_SECRETS_HOME/.agent-secrets in the install manifest."* ]] || return 1
  _no_residue
  _tmp_empty
}

@test "a tar failure says Couldn't unpack, exits 1 and leaves no residue" {
  _tmpd
  _build_mirror
  _shim tar 'case " $* " in *" -xzf "*) exit 2 ;; esac' 'exec /usr/bin/tar "$@"'
  local -a EXTRA=("PATH=$BATS_TEST_TMPDIR/shim:$PATH")
  _mirror_install
  [ "$status" -eq 1 ]
  [[ "$output" == *"Couldn't unpack agent-secrets-v"*".tar.gz into $AGENT_SECRETS_HOME/.agent-secrets."* ]] || return 1
  _no_residue
  [ ! -e "$AGENT_SECRETS_HOME/bin" ]
  _tmp_empty
}

# ---- real outcomes ------------------------------------------------------------------------------

@test "a launchd bootstrap failure warns, still records the job, says not loaded, and exits 0" {
  local mf="$AGENT_SECRETS_HOME/.local/state/agent-secrets/install-manifest.json"
  _tmpd
  _build_mirror
  _shim_setup_in_mirror
  local -a EXTRA=(AGSEC_MOCK_LAUNCHCTL_BOOTSTRAP_FAIL=1)
  _mirror_install
  [ "$status" -eq 0 ]
  [[ "$output" == *"! Couldn't load the weekly smoke job (com.agent-secrets.smoke). Run agent-secrets doctor later."* ]] || return 1
  [[ "$output" == *"This command failed: launchctl bootstrap gui/$(id -u) "* ]] || return 1
  [[ "$output" == *"(weekly smoke job not loaded)"* ]] || return 1
  grep -q com.agent-secrets.smoke "$mf"
  [[ "$output" == *"Installed agent-secrets v"* ]] || return 1
}

@test "a setup failure reports it with setup's exit code and never claims the install finished" {
  local baked
  _tmpd
  _build_mirror
  baked="$(_bake_install)"
  run mm_no_ctty "${_CLEAN[@]}" AGENT_SECRETS_UNATTENDED=1 AGENT_SECRETS_SEED_NAME=bad-name \
      AGSEC_MOCK_DL_DIR="$MIRROR" TMPDIR="$T" bash "$baked" </dev/null
  [ "$status" -eq 1 ]
  [[ "$output" == *"✗ Setup failed (exit 1). The tool is installed but not configured."* ]] || return 1
  printf '%s\n' "$output" | grep -qxF "    $AGENT_SECRETS_HOME/bin/agent-secrets setup"
  printf '%s\n' "$output" | grep -qxF "    $AGENT_SECRETS_HOME/bin/agent-secrets uninstall"
  [[ "$output" != *"Installed agent-secrets"* ]] || return 1
  [[ "$output" != *"Failed to install agent-secrets"* ]] || return 1
  [ -L "$AGENT_SECRETS_HOME/bin/agent-secrets" ]
}

# ---- signals and closed streams -----------------------------------------------------------------

@test "TERM during the download exits 143, says nothing was changed, and leaves no process or work dir" {
  local log="$BATS_TEST_TMPDIR/curl.log"; : >"$log"
  _tmpd
  _bg_start AGENT_SECRETS_BASE_URL=https://mirror.example AGSEC_MOCK_CURL_SLEEP=300 AGSEC_MOCK_CURL_LOG="$log" \
      TMPDIR="$T" bash "$REPO_ROOT/install.sh"
  _wait_for "$log" . || { _bg_reap; return 1; }
  kill -TERM -- "-$BG_PID"
  _bg_reap
  [ "$BG_STATUS" -eq 143 ]
  [[ "$output" == *"Canceled. Nothing was changed."* ]] || return 1
  [[ "$output" != *"Failed to install"* ]] || return 1
  _no_residue
  _tmp_empty
  _group_gone
}

@test "TERM in the unpack window exits 143, removes the fresh tool and says so" {
  local mark="$BATS_TEST_TMPDIR/tar.started"
  _tmpd
  _build_mirror
  # shellcheck disable=SC2016  # the shim's own variables
  _shim tar 'case " $* " in *" -xzf "*) : >"$AGSEC_T_MARK"; sleep 300 >/dev/null 2>&1 & wait "$!" ;; esac' \
            'exec /usr/bin/tar "$@"'
  _bg_start "PATH=$BATS_TEST_TMPDIR/shim:$PATH" AGSEC_T_MARK="$mark" AGENT_SECRETS_BASE_URL=https://mirror.example \
      AGSEC_MOCK_DL_DIR="$MIRROR" TMPDIR="$T" bash "$REPO_ROOT/install.sh"
  _wait_for_file "$mark" || { _bg_reap; return 1; }
  kill -TERM -- "-$BG_PID"
  _bg_reap
  [ "$BG_STATUS" -eq 143 ]
  [[ "$output" == *"Stopped. Removed the partial install."* ]] || return 1
  [[ "$output" != *"Nothing was changed"* ]] || return 1
  _no_residue
  _tmp_empty
  _group_gone
}

@test "a closed stderr (| head -1) never kills the installer: it finishes wiring and exits 0" {
  _tmpd
  _build_mirror
  _shim_setup_in_mirror
  # shellcheck disable=SC2016  # expanded by the inner bash
  run mm_no_ctty "${_CLEAN[@]}" AGENT_SECRETS_BASE_URL=https://mirror.example AGSEC_MOCK_DL_DIR="$MIRROR" TMPDIR="$T" \
      AGSEC_SETUP_ARGV_LOG="$BATS_TEST_TMPDIR/setup.argv" AGSEC_SETUP_ENV_LOG="$BATS_TEST_TMPDIR/setup.env" \
      bash -c '{ bash "$1" </dev/null 2>&1 >/dev/null; } | head -1; exit "${PIPESTATUS[0]}"' _ "$REPO_ROOT/install.sh"
  [ "$status" -eq 0 ]
  [ -f "$AGENT_SECRETS_HOME/.local/state/agent-secrets/install-manifest.json" ]
  [ -L "$AGENT_SECRETS_HOME/bin/agent-secrets" ]
  [ "$(cat "$BATS_TEST_TMPDIR/setup.argv")" = setup ]
  _tmp_empty
}

# ---- error copy (C7.1): a short headline, then a runnable recovery --------------------------------

# The command printed on the row after the row that is exactly $1, without its 4-space indent.
_cmd_after() { printf '%s\n' "$output" | grep -A1 -xF -- "$1" | sed -n '2s/^    //p'; }

@test "the digest refusal has a short headline and two recoveries that each pass the parse-only seam" {
  local head cmd dl="$BATS_TEST_TMPDIR/dl"
  run mm_no_ctty "${_CLEAN[@]}" bash "$REPO_ROOT/install.sh" </dev/null
  [ "$status" -eq 1 ]
  head="$(printf '%s\n' "$output" | grep '^ERROR: ')"
  [ "${#head}" -le 100 ] || { echo "headline is ${#head} chars: $head"; return 1; }
  [[ "$head" == *"no baked release digest"* ]] || return 1
  cmd="$(_cmd_after 'Install the published release:')"
  [[ "$cmd" == *"https://raw.githubusercontent.com/renchris/agent-secrets/v$(cat "$REPO_ROOT/VERSION")/install.sh"* ]] || return 1
  mkdir -p "$dl"; cp "$REPO_ROOT/install.sh" "$dl/install.sh"
  run env AGSEC_PARSE_ONLY=1 AGSEC_MOCK_DL_DIR="$dl" bash -c "$cmd" </dev/null
  [ "$status" -eq 0 ] || { echo "release command: exit $status"; return 1; }
  run mm_no_ctty "${_CLEAN[@]}" bash "$REPO_ROOT/install.sh" </dev/null
  cmd="$(_cmd_after 'Or install from a mirror you control:')"
  [ "$cmd" = 'AGENT_SECRETS_BASE_URL=<MIRROR_URL> bash install.sh' ]
  cmd="${cmd//<MIRROR_URL>/https://mirror.example}"
  run bash -c "cd \"\$1\" && AGSEC_PARSE_ONLY=1 $cmd" _ "$dl" </dev/null
  [ "$status" -eq 0 ] || { echo "mirror command: exit $status"; return 1; }
}

@test "a SHA-256 mismatch names the file, URL, expected and actual digests, and the re-run, exit 1" {
  local head
  _tmpd
  _build_mirror
  printf '%s  %s\n' "$(printf '0%.0s' $(seq 64))" "$PKG" >"$MIRROR/$PKG.sha256"
  _mirror_install
  [ "$status" -eq 1 ]
  head="$(printf '%s\n' "$output" | grep '^ERROR: ')"
  [ "$head" = "ERROR: Couldn't verify $PKG. SHA-256 mismatch." ]
  [ "${#head}" -le 100 ]
  printf '%s\n' "$output" | grep -qxF "  URL:      https://mirror.example/releases/download/$TAG/$PKG"
  printf '%s\n' "$output" | grep -qxF "  Expected: $(printf '0%.0s' $(seq 64))"
  printf '%s\n' "$output" | grep -qxF "  Actual:   $BUILT_SHA"
  [[ "$(_cmd_after 'Nothing was installed. Re-run the installer:')" == "bash "*"install.sh" ]] || return 1
  [[ "$output" != *"Failed to install agent-secrets"* ]] || return 1   # one report, not two
  _no_residue
  _tmp_empty
}

@test "a path in the way gets a short headline, one mv per path and the re-run" {
  local head
  mkdir -p "$AGENT_SECRETS_HOME"; : >"$AGENT_SECRETS_HOME/bin"
  run mm_no_ctty "${_CLEAN[@]}" bash "$REPO_ROOT/install.sh" </dev/null
  [ "$status" -eq 1 ]
  head="$(printf '%s\n' "$output" | grep '^ERROR: ')"
  [ "${#head}" -le 100 ]
  [[ "$head" != *"not a directory"* ]] || return 1          # the per-path rows carry it, counted elsewhere
  printf '%s\n' "$output" | grep -qxF "    mv $(printf '%q %q' "$AGENT_SECRETS_HOME/bin" "$AGENT_SECRETS_HOME/bin.bak")"
  [[ "$(_cmd_after 'Then re-run the installer:')" == "bash "*"install.sh" ]] || return 1
}

@test "a mis-cut release points end users at the issues page; git archive is only for a mirror" {
  local x
  _tmpd
  _build_mirror
  x="$BATS_TEST_TMPDIR/recut"; mkdir -p "$x/wrap"
  tar -xzf "$MIRROR/$PKG" -C "$x/wrap"
  ( cd "$x" && COPYFILE_DISABLE=1 tar -czf "$MIRROR/$PKG" wrap )
  _mirror_digest
  _mirror_install
  [ "$status" -eq 1 ]
  [ "$(_cmd_after 'Report it, so the release can be re-cut:')" = "https://github.com/renchris/agent-secrets/issues" ]
  [[ "$(_cmd_after 'If you run a mirror, rebuild with:')" == "git archive --prefix=agent-secrets-$TAG/ "* ]] || return 1
  [ "$(printf '%s\n' "$output" | grep -c 'git archive')" -eq 1 ]
  [[ "$output" != *'${TAG}'* ]] || return 1
}

@test "a failed sh re-fetch prints ASCII only, and the download-then-bash recovery" {
  run env -u AGSEC_REEXECED AGENT_SECRETS_INSTALL_URL='https://raw.example/install.sh' AGSEC_MOCK_CURL_EXIT=22 \
      /bin/sh -s <"$REPO_ROOT/install.sh"
  [ "$status" -eq 1 ]
  [ -z "$(printf '%s\n' "$output" | LC_ALL=C grep '[^ -~]')" ]
  [ "$(_cmd_after 'Download it, then run it with bash (not sh):')" = "curl -fsSLo install.sh https://raw.example/install.sh && bash install.sh" ]
}

# ---- F28 (C7.3): setup finished, but its health check found a ✗ row ------------------------------

@test "when setup's health check finds a ✗ row, install says setup finished with problems and exits 1" {
  _tmpd
  _build_mirror
  # A settings.json helper wired with no ANTHROPIC_API_KEY stored is a doctor ✗ (tests/headless.bats).
  mkdir -p "$AGENT_SECRETS_HOME/.claude"
  jq -n --arg h "$AGENT_SECRETS_HOME/bin/apiKeyHelper" '{apiKeyHelper:$h}' >"$AGENT_SECRETS_HOME/.claude/settings.json"
  run mm_no_ctty "${_CLEAN[@]}" AGENT_SECRETS_BASE_URL=https://mirror.example AGSEC_MOCK_DL_DIR="$MIRROR" \
      TMPDIR="$T" bash "$REPO_ROOT/install.sh" --no-discovery </dev/null
  [ "$status" -eq 1 ]
  [[ "$output" == *"Setup finished with problems. Run: agent-secrets doctor"* ]] || return 1
  printf '%s\n' "$output" | grep -qF "    $AGENT_SECRETS_HOME/bin/agent-secrets doctor"
  [[ "$output" != *"Setup failed"* ]] || return 1
  [[ "$output" != *"Installed agent-secrets"* ]] || return 1
  grep -qx checked "$AGENT_SECRETS_HOME/.local/state/agent-secrets/wizard-state.json"
}
