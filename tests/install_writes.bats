#!/usr/bin/env bats
# tests/install_writes.bats — install.sh's writes and concurrency: a user's own ~/bin targets (files and
# every kind of symlink) are backed up and restored, a changed one refreshes its backup, the tool is
# unpacked into staging and swapped in (vendor/ kept, stale files dropped, a bad tarball never touches a
# live install, a half-done swap recovered), exotic install homes stay literal in the rc and the plist,
# and one install at a time holds a lock that a dead holder does not keep.
bats_require_minimum_version 1.5.0
load test_helper
load install_helper
load mode_matrix

_CLEAN=(env -u CLAUDECODE -u CLAUDE_CODE -u CURSOR_AGENT -u CURSOR_TRACE_ID -u TERM_PROGRAM -u CI
        -u AGENT_SECRETS_UNATTENDED -u AGENT_SECRETS_NONINTERACTIVE -u AGENT_SECRETS_BASE_URL
        -u CLAUDE_CONFIG_DIR -u CODEX_HOME -u AGSEC_DISCOVERY_KEYS)

_tmpd() { T="$BATS_TEST_TMPDIR/tmpd"; mkdir -p "$T"; }
_tmp_empty() {
  if [ -n "$(ls -A "$T")" ]; then printf 'TMPDIR not empty:\n%s\n' "$(ls -A "$T")" >&2; return 1; fi
}
# A mirror install with no terminal, setup shimmed (call _build_mirror and _shim_setup_in_mirror first).
# EXTRA holds more VAR=value words for env; IHOME, when set, is the install home for this run.
_install() {
  run mm_no_ctty "${_CLEAN[@]}" AGENT_SECRETS_BASE_URL=https://mirror.example AGSEC_MOCK_DL_DIR="$MIRROR" \
      AGENT_SECRETS_HOME="${IHOME:-$AGENT_SECRETS_HOME}" TMPDIR="$T" \
      AGSEC_SETUP_ARGV_LOG="$BATS_TEST_TMPDIR/setup.argv" AGSEC_SETUP_ENV_LOG="$BATS_TEST_TMPDIR/setup.env" \
      ${EXTRA[@]+"${EXTRA[@]}"} bash "$REPO_ROOT/install.sh" </dev/null
}
_prep() { _tmpd; _build_mirror; _shim_setup_in_mirror; }
_shim() {
  local name="$1"; shift
  mkdir -p "$BATS_TEST_TMPDIR/shim"
  printf '%s\n' '#!/bin/bash' "$@" >"$BATS_TEST_TMPDIR/shim/$name"
  chmod 0755 "$BATS_TEST_TMPDIR/shim/$name"
}
# What uninstall does with the manifest this install wrote.
_rollback() {
  ( export AGENT_SECRETS_LIB="$REPO_ROOT/lib" AGENT_SECRETS_ROOT="$REPO_ROOT"
    # shellcheck source=/dev/null
    . "$REPO_ROOT/lib/common.sh"; . "$REPO_ROOT/lib/manifest.sh"; manifest_rollback ) >/dev/null 2>&1 || true
}
# Every file and link under a tree with its digest or link text, plus the tree's mode.
_tree_sum() {
  stat -f '%Lp' "$1"
  ( cd "$1" && find . \( -type f -o -type l \) -print | LC_ALL=C sort | while IFS= read -r p; do
      if [ -L "$p" ]; then printf 'L %s %s\n' "$p" "$(readlink "$p")"
      else printf 'F %s %s\n' "$p" "$(shasum -a 256 "$p" | awk '{print $1}')"; fi
    done )
}
# No staging tree, no .old tree and no lock left behind.
_no_swap_residue() {
  local left
  left="$(compgen -G "$AGENT_SECRETS_HOME/.agent-secrets.staging.*" || true)"
  if [ -n "$left" ]; then printf 'left behind: %s\n' "$left" >&2; return 1; fi
  if [ -e "$TOOL.old" ]; then echo 'left behind: .agent-secrets.old' >&2; return 1; fi
  if [ -e "$STATE/install.lock" ] || [ -e "$STATE/install.lock.steal" ]; then echo 'lock left behind' >&2; return 1; fi
}
_vars() { B="$AGENT_SECRETS_HOME/bin"; STATE="$AGENT_SECRETS_HOME/.local/state/agent-secrets"; TOOL="$AGENT_SECRETS_HOME/.agent-secrets"; }

# Signal-test helpers (as in tests/install_failure.bats): the installer leads its own process group.
_bg_start() {
  BG_OUT="$BATS_TEST_TMPDIR/bg.out"
  perl -MPOSIX -e "$_MM_SETSID" -- "${_CLEAN[@]}" "$@" </dev/null >"$BG_OUT" 2>&1 &
  BG_PID=$!
}
_wait_for_file() {
  local i=0
  while [ ! -e "$1" ] && [ "$i" -lt 3000 ]; do sleep 0.1; i=$((i + 1)); done
  [ -e "$1" ]
}
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

# ---- user targets in ~/bin ------------------------------------------------------------------------

@test "foreign, dangling and directory symlinks: the plan names each backup, install keeps it, uninstall restores the links" {
  _vars; _prep
  local f la="$AGENT_SECRETS_HOME/Library/LaunchAgents" dot="$AGENT_SECRETS_HOME/dotfiles"
  mkdir -p "$B" "$AGENT_SECRETS_HOME/mine" "$AGENT_SECRETS_HOME/mydir" "$la" "$dot"
  printf 'mine\n' >"$AGENT_SECRETS_HOME/mine/ca"
  ln -s "$AGENT_SECRETS_HOME/mine/ca" "$B/claude-agent"
  ln -s /nonexistent/elsewhere "$B/cursor-agent"
  ln -s "$AGENT_SECRETS_HOME/mydir" "$B/apiKeyHelper"
  # A dotfile-managed plist: the write goes through the link.
  printf 'old\n' >"$dot/smoke.plist"; ln -s "$dot/smoke.plist" "$la/com.agent-secrets.smoke.plist"
  _install
  [ "$status" -eq 0 ]
  for f in claude-agent cursor-agent apiKeyHelper; do
    [[ "$output" == *"replace your existing symlink $B/$f (backed up to $STATE/$f.preinstall.bak; uninstall restores it)"* ]] || return 1
    [ "$(readlink "$B/$f")" = "$TOOL/bin/$f" ]
    [ -L "$STATE/$f.preinstall.bak" ]
  done
  [ "$(printf '%s\n' "$output" | grep -c 'replace your existing')" -eq 3 ]
  [ "$(readlink "$STATE/claude-agent.preinstall.bak")" = "$AGENT_SECRETS_HOME/mine/ca" ]
  [ "$(readlink "$STATE/cursor-agent.preinstall.bak")" = /nonexistent/elsewhere ]
  [ -z "$(ls -A "$AGENT_SECRETS_HOME/mydir")" ]                   # nothing landed inside their directory
  [ -L "$la/com.agent-secrets.smoke.plist" ]
  grep -q '<key>Label</key><string>com.agent-secrets.smoke</string>' "$dot/smoke.plist"
  [ "$(stat -f '%Lp' "$dot/smoke.plist")" = 644 ]
  [ "$(ls -A "$la")" = com.agent-secrets.smoke.plist ]            # no .smoke.* temp file
  _rollback
  [ "$(readlink "$B/claude-agent")" = "$AGENT_SECRETS_HOME/mine/ca" ]
  [ "$(readlink "$B/cursor-agent")" = /nonexistent/elsewhere ]
  [ "$(readlink "$B/apiKeyHelper")" = "$AGENT_SECRETS_HOME/mydir" ]
  [ "$(cat "$AGENT_SECRETS_HOME/mine/ca")" = mine ]
}

@test "a user file changed between installs refreshes its backup, keeps the earlier one, and uninstall restores the newer" {
  _vars; _prep
  local b olds
  b="$STATE/claude-agent.preinstall.bak"
  mkdir -p "$B"; printf 'v1\n' >"$B/claude-agent"
  _install
  [ "$status" -eq 0 ]
  [ "$(cat "$b")" = v1 ]
  rm -f "$B/claude-agent"; printf 'v2\n' >"$B/claude-agent"     # the user replaces our link with v2
  _install
  [ "$status" -eq 0 ]
  [[ "$output" == *"kept the earlier backup of $B/claude-agent as $b."* ]] || return 1
  [ "$(cat "$b")" = v2 ]
  olds="$(compgen -G "$b.[0-9]*")"
  [ "$(printf '%s\n' "$olds" | wc -l | tr -d ' ')" -eq 1 ]
  [ "$(cat "$olds")" = v1 ]
  run jq --arg p "$B/claude-agent" '[.[] | select(.type=="edit" and .path==$p)] | length' "$STATE/install-manifest.json"
  [ "$output" -eq 1 ]
  _rollback
  [ ! -L "$B/claude-agent" ]
  [ "$(cat "$B/claude-agent")" = v2 ]
}

@test "a failed backup record stops before the link and leaves the user's file as it was" {
  _vars; _prep
  local real_jq; real_jq="$(command -v jq)"
  # shellcheck disable=SC2016  # the shim's own variables
  _shim jq 'for a in "$@"; do case "$a" in *claude-agent.preinstall.bak*) exit 1 ;; esac; done' \
           'exec "$AGSEC_T_REAL_JQ" "$@"'
  mkdir -p "$B"; printf 'mine\n' >"$B/claude-agent"
  local -a EXTRA=("PATH=$BATS_TEST_TMPDIR/shim:$PATH" AGSEC_T_REAL_JQ="$real_jq")
  _install
  [ "$status" -eq 1 ]
  [[ "$output" == *"Couldn't record the backup of $B/claude-agent; nothing replaced. Your file is unchanged."* ]] || return 1
  [ ! -L "$B/claude-agent" ]
  [ "$(cat "$B/claude-agent")" = mine ]
  [ ! -e "$B/cursor-agent" ]                                      # nothing after it was wired either
  _no_swap_residue
  _tmp_empty
}

# ---- staged unpack and swap -----------------------------------------------------------------------

@test "a same-version re-install says already installed, keeps vendor/, drops stale files and backs up nothing of ours" {
  _vars; _prep
  local mode
  _install
  [ "$status" -eq 0 ]
  mode="$(stat -f '%Lp' "$TOOL")"
  mkdir -p "$TOOL/vendor/bin"; printf 'kept\n' >"$TOOL/vendor/bin/marker"
  printf 'old\n' >"$TOOL/lib/stale-from-old.sh"
  _install
  [ "$status" -eq 0 ]
  [[ "$output" == *"is already installed"* ]] || return 1
  [[ "$output" != *"replace your existing"* ]] || return 1
  [ "$(cat "$TOOL/vendor/bin/marker")" = kept ]
  [ ! -e "$TOOL/lib/stale-from-old.sh" ]
  [ "$(stat -f '%Lp' "$TOOL")" = "$mode" ]
  [ "$(readlink "$B/agent-secrets")" = "$TOOL/bin/agent-secrets" ]
  [ -z "$(compgen -G "$STATE/*.preinstall.bak*")" ]
  _no_swap_residue
  _tmp_empty
}

@test "a mis-cut tarball over a live install leaves it byte-identical, with no staging tree and no lock" {
  _vars; _prep
  local before x
  _install
  [ "$status" -eq 0 ]
  before="$(_tree_sum "$TOOL")"
  x="$BATS_TEST_TMPDIR/recut"; mkdir -p "$x/wrap"
  tar -xzf "$MIRROR/$PKG" -C "$x/wrap"
  ( cd "$x" && COPYFILE_DISABLE=1 tar -czf "$MIRROR/$PKG" wrap )  # one prefix too many
  _mirror_digest
  _install
  [ "$status" -eq 1 ]
  [[ "$output" == *"unexpected tarball layout"* ]] || return 1
  [ "$(_tree_sum "$TOOL")" = "$before" ]
  _no_swap_residue
  _tmp_empty
}

@test "a leftover .old tree with no live tool dir is moved back and re-installed over" {
  _vars; _prep
  _install
  [ "$status" -eq 0 ]
  mkdir -p "$TOOL/vendor/bin"; printf 'kept\n' >"$TOOL/vendor/bin/marker"
  mv "$TOOL" "$TOOL.old"                                          # stopped between the two renames
  _install
  [ "$status" -eq 0 ]
  [[ "$output" == *"Recovered $TOOL from an interrupted install."* ]] || return 1
  [ -f "$TOOL/bin/agent-secrets" ]
  [ "$(cat "$TOOL/vendor/bin/marker")" = kept ]
  _no_swap_residue
  _tmp_empty
}

@test "TERM while unpacking over a live install exits 143, says it was not changed, and leaves it intact" {
  _vars; _prep
  local before mark="$BATS_TEST_TMPDIR/tar.started"
  _install
  [ "$status" -eq 0 ]
  before="$(_tree_sum "$TOOL")"
  # shellcheck disable=SC2016  # the shim's own variables
  _shim tar 'case " $* " in *" -xzf "*) : >"$AGSEC_T_MARK"; sleep 300 >/dev/null 2>&1 & wait "$!" ;; esac' \
            'exec /usr/bin/tar "$@"'
  _bg_start "PATH=$BATS_TEST_TMPDIR/shim:$PATH" AGSEC_T_MARK="$mark" AGENT_SECRETS_BASE_URL=https://mirror.example \
      AGSEC_MOCK_DL_DIR="$MIRROR" TMPDIR="$T" bash "$REPO_ROOT/install.sh"
  _wait_for_file "$mark" || { _bg_reap; return 1; }
  kill -TERM -- "-$BG_PID"
  _bg_reap
  [ "$BG_STATUS" -eq 143 ]
  [[ "$output" == *"Stopped. Your existing install was not changed."* ]] || return 1
  [[ "$output" != *"partly updated"* ]] || return 1
  [ "$(_tree_sum "$TOOL")" = "$before" ]
  _no_swap_residue
  _tmp_empty
  _group_gone
}

# ---- exotic install homes -------------------------------------------------------------------------

@test "an install home with a double quote, \$(…), a backquote and & installs; rc and plist keep it literal" {
  _vars; _prep
  # shellcheck disable=SC2016  # the literal characters are the point
  local IHOME="$AGENT_SECRETS_HOME/h\"q\$(touch pwned1)\`touch pwned2\`a&b" scratch="$BATS_TEST_TMPDIR/scratch" plist got
  mkdir -p "$IHOME" "$scratch"
  _install
  [ "$status" -eq 0 ]
  # shellcheck disable=SC2016  # expanded by the inner bash
  got="$(cd "$scratch" && PATH=/usr/bin:/bin /bin/bash -c '. "$1" && printf "%s" "${PATH%%:*}"' _ "$IHOME/.zshenv")"
  [ "$got" = "$IHOME/bin" ]
  [ -z "$(ls -A "$scratch")" ]                                    # sourcing ran nothing
  plist="$IHOME/Library/LaunchAgents/com.agent-secrets.smoke.plist"
  grep -qF 'a&amp;b/.agent-secrets/bin/agent-secrets' "$plist"
  if command -v plutil >/dev/null 2>&1; then
    plutil -lint "$plist" >/dev/null
    [ "$(plutil -extract ProgramArguments.0 raw -o - "$plist")" = "$IHOME/.agent-secrets/bin/agent-secrets" ]
  fi
}

# ---- one install at a time ------------------------------------------------------------------------

@test "a lock held by a live pid: exit 1 after the wait, names the pid, keeps the holder's lock, changes nothing" {
  _vars; _prep
  mkdir -p "$STATE/install.lock"; printf '%s\n' "$$" >"$STATE/install.lock/pid"
  _install
  [ "$status" -eq 1 ]
  [[ "$output" == *"Another agent-secrets install is running (pid $$); waited 60 s for it to finish."* ]] || return 1
  [[ "$output" == *"Re-run the installer when it finishes:"* ]] || return 1
  [[ "$output" != *"✗ Failed"* ]] || return 1
  [ "$(cat "$STATE/install.lock/pid")" = "$$" ]
  [ ! -e "$TOOL" ]
  [ ! -e "$B/agent-secrets" ]
  [ -z "$(compgen -G "$AGENT_SECRETS_HOME/.agent-secrets.staging.*" || true)" ]
  _tmp_empty
}

@test "a lock left by a dead pid is reclaimed, and no lock is left after the run" {
  _vars; _prep
  local dead
  ( exit 0 ) & dead=$!; wait "$dead" || true
  mkdir -p "$STATE/install.lock"; printf '%s\n' "$dead" >"$STATE/install.lock/pid"
  _install
  [ "$status" -eq 0 ]
  [[ "$output" != *"Another agent-secrets install is running"* ]] || return 1
  [ -f "$TOOL/bin/agent-secrets" ]
  _no_swap_residue
  _tmp_empty
}
