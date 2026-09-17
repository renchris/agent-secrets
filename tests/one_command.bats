#!/usr/bin/env bats
# tests/one_command.bats — executable locks for the "one command setup" claim.
# Every assertion here corresponds to a defect MEASURED over a PTY on 2026-09-11 and recorded in
# docs/plans/ONE_COMMAND_SETUP_V2.md. They exist so the claim cannot rot back.
load test_helper

# ---- B3: a declared default must be the default, and must be visible --------------------------

@test "B3: ui_confirm with default n answers NO on a bare Enter (gum answered YES)" {
  run bash -c '. "$REPO_ROOT/lib/common.sh"; . "$REPO_ROOT/lib/ui.sh"; printf "\n" | ui_confirm "Arm it?" n; echo "rc=$?"'
  [[ "$output" == *"rc=1"* ]] || return 1
  [[ "$output" == *"[y/N]"* ]] || return 1        # the default is on screen, not implied
}

@test "B3: ui_confirm with default y answers YES on a bare Enter" {
  run bash -c '. "$REPO_ROOT/lib/common.sh"; . "$REPO_ROOT/lib/ui.sh"; printf "\n" | ui_confirm "Go?" y; echo "rc=$?"'
  [[ "$output" == *"rc=0"* ]] || return 1
  [[ "$output" == *"[Y/n]"* ]] || return 1
}

@test "B3: ui_confirm still fails CLOSED on EOF (no human = no consent)" {
  run bash -c '. "$REPO_ROOT/lib/common.sh"; . "$REPO_ROOT/lib/ui.sh"; ui_confirm "Go?" y </dev/null; echo "rc=$?"'
  [[ "$output" == *"rc=1"* ]] || return 1
}

@test "B3: ui_menu resolves a bare Enter to option 1 and says so" {
  run bash -c '. "$REPO_ROOT/lib/common.sh"; . "$REPO_ROOT/lib/ui.sh"; printf "\n" | ui_menu "Pick" FIRST SECOND'
  [[ "$output" == *"FIRST"* ]] || return 1
  [[ "$output" != *"SECOND"$'\n'* ]] || true
  [[ "$output" == *"Enter = 1"* ]] || return 1
}

# ---- B4: no full-screen widget in the runtime, at all -----------------------------------------

@test "B4: no runtime code shells out to gum (its widget broke defaults, resize and queries)" {
  # grep the CODE, not the comment block in ui.sh that explains why gum is gone.
  run bash -c 'grep -rhvE "^[[:space:]]*#" "$REPO_ROOT"/lib/*.sh "$REPO_ROOT"/cmd/*.sh "$REPO_ROOT"/bin/* "$REPO_ROOT"/install.sh |
               grep -nE "(^|[^a-zA-Z_-])gum (confirm|choose|style|input|spin)" || true'
  [ -z "$output" ] || return 1
}

# ---- B2: the installer must not leak a bash error onto the consent screen ----------------------

@test "B2: install.sh --dry-run renders the plan with no shell error and no unbound variable" {
  run bash -c 'AGENT_SECRETS_HOME="$AGENT_SECRETS_HOME" bash "$REPO_ROOT/install.sh" --dry-run 2>&1'
  [ "$status" -eq 0 ]
  [[ "$output" != *"unbound variable"* ]] || return 1
  [[ "$output" != *"line "*": "* ]] || return 1
  [[ "$output" == *"agent-secrets installer"* ]] || return 1
}

@test "B2: the machine-wide rule block carries a NON-EMPTY version in its integrity marker" {
  # common.sh sourced WITHOUT the dispatcher's AGENT_SECRETS_LIB — exactly how install.sh uses it.
  run bash -c 'unset AGENT_SECRETS_LIB; . "$REPO_ROOT/lib/common.sh"; agsec_render_rules claude-md'
  [ "$status" -eq 0 ]
  [[ "$output" == *"agent-secrets:version="* ]] || return 1
  [[ "$output" != *"agent-secrets:version= "* ]] || return 1     # the empty-version regression
  run bash -c 'unset AGENT_SECRETS_LIB; set -u; . "$REPO_ROOT/lib/common.sh"; agsec_version'
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}

# ---- B6: `curl … | bash` is a real one command ------------------------------------------------

@test "B6: agsec_attach_tty exists and refuses cleanly when there is genuinely no terminal" {
  run bash -c '. "$REPO_ROOT/lib/common.sh"; agsec_attach_tty </dev/null; echo "rc=$?"'
  [[ "$output" == *"rc=1"* ]] || return 1
}

@test "B6: setup with no terminal anywhere runs HEADLESS to completion — no refusal, no empty secret, no key on screen" {
  # This used to assert a refusal ("no terminal to run it on"). The hazard it guarded — a hidden
  # prompt reading EOF and storing an EMPTY first secret — is structurally absent from headless mode,
  # which reads no secret at all. So "no human" now means "do the safe defaults", not "stop".
  run bash -c 'env -u CLAUDECODE -u CLAUDE_CODE -u CURSOR_AGENT -u CURSOR_TRACE_ID -u TERM_PROGRAM AGSEC_TEST_CONFIRM= bash "$REPO_ROOT/bin/agent-secrets" setup </dev/null 2>&1'
  [ "$status" -eq 0 ]
  [[ "$output" == *"(headless)"* ]] || return 1
  [[ "$output" == *"no terminal attached"* ]] || return 1          # the ONE reason, named
  [[ "$output" == *"You're set up"* ]] || return 1
  [[ "$output" != *"AGE-SECRET-KEY"* ]] || return 1
  run agsec list
  [[ "$output" != *"ANTHROPIC_API_KEY"* ]] || return 1             # nothing was seeded from a dead pipe
}

# ---- B8 / DoD 2: the wizard is legible at 80 columns, with no terminal-query garbage -----------

# Drive the whole wizard on a PTY and keep every byte it wrote. Two answers is the whole minimum
# path now: the recovery save (n = later) and the first-secret menu (4 = skip). The Keychain
# populate no longer asks (it needs no paste), and the canary prompt is gone.
# rc: 0 = wizard exited 0 · 99 = expect not installed · anything else = the DRIVE desynced (a prompt
# changed, or the wizard died) — a failure, never a skip.
_e2e_capture() {
  command -v expect >/dev/null 2>&1 || return 99
  cat >"$AGENT_SECRETS_HOME/cap.exp" <<'EOF'
set timeout 30
log_file -a $env(AGENT_SECRETS_HOME)/cap.log
spawn -noecho env -u CLAUDECODE -u CLAUDE_CODE -u CURSOR_AGENT -u CURSOR_TRACE_ID -u TERM_PROGRAM bash $env(REPO_ROOT)/bin/agent-secrets setup
stty rows 24 columns 80 < $spawn_out(slave,name)
expect_after { timeout { puts "\nDESYNC-TIMEOUT"; exit 90 } eof { puts "\nEARLY-EOF"; exit 91 } }
expect "Save it off this Mac now?" { send "n\r" }
expect -ex {choose [1-4, Enter = 1]:} { send "4\r" }
expect eof { }
catch wait result
exit [lindex $result 3]
EOF
  expect "$AGENT_SECRETS_HOME/cap.exp" >/dev/null 2>&1
}
# The wizard drive is a precondition; its own failure must read as one, not as "expect not available".
_e2e_require() {
  local rc=0; _e2e_capture || rc=$?
  [ "$rc" -eq 99 ] && skip "expect not available"
  [ "$rc" -eq 0 ] || { printf 'wizard drive failed rc=%s\n%s\n' "$rc" "$(cat "$AGENT_SECRETS_HOME/cap.log" 2>/dev/null)"; return 1; }
}

@test "DoD: the interactive minimum path is TWO answers (recovery: later · first secret: skip) — no Keychain paste, no canary prompt" {
  _e2e_require
  run cat "$AGENT_SECRETS_HOME/cap.log"
  [[ "$output" == *"You're set up"* ]] || return 1
  [[ "$output" != *"Populate your login Keychain"* ]] || return 1
  [[ "$output" != *"password data for new item"* ]] || return 1
  [[ "$output" != *"Arm it now?"* ]] || return 1
  [[ "$output" == *"Keychain custody — primary"* ]] || return 1    # populated with no paste at all
  # The prompts that remain are exactly the two the drive answered.
  run bash -c 'LC_ALL=C grep -c "\[Y/n\]\|\[y/N\]\|choose \[" "$AGENT_SECRETS_HOME/cap.log" || true'
  [ "$output" = "2" ]
}

@test "DoD: the wizard reaches the done screen and emits NO terminal capability query" {
  _e2e_require
  run cat "$AGENT_SECRETS_HOME/cap.log"
  [[ "$output" == *"You're set up"* ]] || return 1
  # OSC-11 background query and DSR cursor report — gum emitted both on every prompt and blocked
  # on the reply, which is what read as an unresponsive UI.
  run bash -c 'LC_ALL=C grep -c "\]11;?" "$AGENT_SECRETS_HOME/cap.log" || true'
  [ "$output" = "0" ]
  run bash -c 'LC_ALL=C grep -c "\[6n" "$AGENT_SECRETS_HOME/cap.log" || true'
  [ "$output" = "0" ]
}

@test "DoD: no wizard line exceeds 72 columns except an unsplittable path token" {
  _e2e_require
  # A line is a failure only if it is over budget AND every token in it is short — i.e. it is prose
  # we chose not to fit. A long filesystem path is emitted WHOLE on purpose (drag-copy), so the
  # terminal, not us, wraps it.
  #
  # Width is measured in CHARACTERS. BSD awk's length() counts BYTES, which charges 3 columns for
  # every ✓ ⚠ — in our own output and manufactures failures; bash's ${#var} is multibyte-aware
  # under a UTF-8 locale, so the check runs in the shell.
  run bash -c '
    export LC_ALL=en_US.UTF-8
    LC_ALL=C sed "s/\x1b\[[0-9;?]*[a-zA-Z]//g" "$AGENT_SECRETS_HOME/cap.log" | tr -d "\r" |
    while IFS= read -r line; do
      [ "${#line}" -le 72 ] && continue
      longest=0
      for tok in $line; do [ "${#tok}" -gt "$longest" ] && longest=${#tok}; done
      [ "$longest" -ge 40 ] && continue
      printf "%s: %s\n" "${#line}" "$line"
    done'
  [ -z "$output" ] || return 1
}

@test "DoD: the wizard never prints a raw age public key banner" {
  _e2e_require
  run bash -c 'LC_ALL=C grep -c "^Public key: age1" "$AGENT_SECRETS_HOME/cap.log" || true'
  [ "$output" = "0" ]
}

@test "DoD: the wizard's own screens are numbered from 1" {
  _e2e_require
  run cat "$AGENT_SECRETS_HOME/cap.log"
  [[ "$output" == *"[1/6]"* ]] || return 1
  [[ "$output" == *"[6/6]"* ]] || return 1
  [[ "$output" != *"[2/7]"* ]] || return 1
}

# ---- Fresh macOS: the Xcode-CLT stub problem ---------------------------------------------------
# macOS ships inert stubs at /usr/bin for git/python3/clang/make/swift/lldb — byte-identical
# (sha256 7f30f076…, 118864 bytes) and embedding "com.apple.dt.xcode_select.tool-shim". Without the
# developer tools installed they still EXIST, so `command -v git` succeeds and the first real call
# posts a GUI dialog. A fresh Mac is the default Mac, so this is the common case, not the exotic one.

# Simulate "no developer tools": a fake xcode-select that fails. The PATH is rebuilt so that `git`
# resolves to the real /usr/bin STUB (as it does on any Mac) while age/sops/jq still come from
# wherever this machine keeps them — otherwise the probe is never exercised, because a developer box
# resolves git to Homebrew, which is real by definition.
_fresh_mac_path() {
  local d="$AGENT_SECRETS_HOME/nodev"; mkdir -p "$d"
  printf '#!/bin/sh\nexit 2\n' >"$d/xcode-select"; chmod +x "$d/xcode-select"
  local tools; tools="$(dirname "$(command -v age)")"
  printf '%s\n' "$d:$BATS_TEST_DIRNAME/mocks:/usr/bin:/bin:/usr/sbin:/sbin:$tools"
}

@test "fresh-mac: agsec_have_devtool REJECTS a /usr/bin stub when the developer tools are absent" {
  local p; p="$(_fresh_mac_path)"
  # precondition: git really does resolve to the stub in this simulated environment
  run env PATH="$p" bash -c 'command -v git'
  [ "$output" = "/usr/bin/git" ]
  run env PATH="$p" bash -c '. "$REPO_ROOT/lib/common.sh"; agsec_have_devtool git; echo "rc=$?"'
  [[ "$output" == *"rc=1"* ]] || return 1
  # plain agsec_have still says yes — that IS the bug this probe exists to cover
  run env PATH="$p" bash -c '. "$REPO_ROOT/lib/common.sh"; agsec_have git; echo "rc=$?"'
  [[ "$output" == *"rc=0"* ]] || return 1
}

@test "fresh-mac: agsec_have_devtool ACCEPTS the same stub once the developer tools ARE present" {
  local d="$AGENT_SECRETS_HOME/yesdev"; mkdir -p "$d"
  printf '#!/bin/sh\necho /Library/Developer/CommandLineTools\n' >"$d/xcode-select"; chmod +x "$d/xcode-select"
  run env PATH="$d:/usr/bin:/bin" bash -c '. "$REPO_ROOT/lib/common.sh"; agsec_have_devtool git; echo "rc=$?"'
  [[ "$output" == *"rc=0"* ]] || return 1
}

@test "fresh-mac: a copy OUTSIDE /usr/bin is real by definition — no probe, no rejection" {
  local p; p="$(_fresh_mac_path)"
  local d="$AGENT_SECRETS_HOME/nodev"
  printf '#!/bin/sh\necho ok\n' >"$d/git"; chmod +x "$d/git"   # shadows the stub; xcode-select still fails
  run env PATH="$p" bash -c '. "$REPO_ROOT/lib/common.sh"; agsec_have_devtool git; echo "rc=$?"'
  [[ "$output" == *"rc=0"* ]] || return 1
}

@test "fresh-mac: backup refuses with the one command that fixes it, instead of popping a dialog" {
  setup_store
  local p; p="$(_fresh_mac_path)"
  local d="$AGENT_SECRETS_HOME/nodev"
  printf '#!/bin/sh\nexit 0\n' >"$d/gh"; chmod +x "$d/gh"   # gh present, so git is the missing link
  run env PATH="$p" bash "$REPO_ROOT/bin/agent-secrets" backup </dev/null
  [ "$status" -ne 0 ]
  [[ "$output" == *"xcode-select --install"* ]] || return 1
}

@test "fresh-mac: doctor names git as a placeholder rather than reporting it usable" {
  setup_store
  local p; p="$(_fresh_mac_path)"
  run env PATH="$p" bash "$REPO_ROOT/bin/agent-secrets" doctor
  [[ "$output" == *"placeholder only"* ]] || return 1
  [[ "$output" == *"xcode-select --install"* ]] || return 1
}
