#!/usr/bin/env bats
# tests/install_plan.bats — install.sh's mode resolver, consent gate, plan preview, dry run, preflight
# and the place of the discovery offer. The pty drives that answer prompts live in tests/install_tty.bats.
bats_require_minimum_version 1.5.0
load test_helper
load install_helper
load mode_matrix

# Every run starts from a known mode: no agent, CI or unattended marker inherited from the developer's
# shell, and no relocated harness dir.
_CLEAN=(env -u CLAUDECODE -u CLAUDE_CODE -u CURSOR_AGENT -u CURSOR_TRACE_ID -u TERM_PROGRAM -u CI
        -u AGENT_SECRETS_UNATTENDED -u AGENT_SECRETS_NONINTERACTIVE -u AGENT_SECRETS_BASE_URL
        -u CLAUDE_CONFIG_DIR -u CODEX_HOME -u AGSEC_DISCOVERY_KEYS)

# A dry run with no controlling terminal (so a local run never attaches the developer's terminal).
# DRY_ENV holds extra VAR=value words; ARGS… are appended after --dry-run.
_dry() { run mm_no_ctty "${_CLEAN[@]}" ${DRY_ENV[@]+"${DRY_ENV[@]}"} bash "${DRY_SCRIPT:-$REPO_ROOT/install.sh}" --dry-run "$@" </dev/null; }

# A copy of install.sh with a placeholder digest baked in (a dry run never downloads, so it is never used).
_fake_baked() {
  local b="$BATS_TEST_TMPDIR/install.sh"
  sed "s/EXPECTED_SHA256=\"[a-f0-9]*\"/EXPECTED_SHA256=\"$(printf '0%.0s' $(seq 64))\"/" "$REPO_ROOT/install.sh" >"$b"
  printf '%s\n' "$b"
}

# Which setup the plan announces: wizard, headless, or none.
_plan_mode() { case "$1" in *"the interactive wizard"*) echo wizard ;; *"setup --headless"*) echo headless ;; *) echo none ;; esac; }

# ---- preflight ---------------------------------------------------------------------------------

@test "a dry run names every directory conflict after the plan, exits 1 and creates nothing" {
  printf 'x\n' >"$AGENT_SECRETS_HOME/bin"
  printf 'x\n' >"$AGENT_SECRETS_HOME/Library"
  DRY_ENV=(AGENT_SECRETS_BASE_URL=https://mirror.example)
  _dry
  [ "$status" -eq 1 ]
  [[ "$output" == *"agent-secrets installer"* ]] || return 1
  [[ "$output" == *"$AGENT_SECRETS_HOME/bin already exists and is not a directory"* ]] || return 1
  [[ "$output" == *"$AGENT_SECRETS_HOME/Library already exists and is not a directory"* ]] || return 1
  [[ "$output" != *"Local checks passed"* ]] || return 1
  [ ! -e "$AGENT_SECRETS_HOME/.agent-secrets" ]
  [ ! -e "$AGENT_SECRETS_HOME/.local" ]
}

@test "preflight catches a file at ~/.local and a directory at ~/.zshenv, passes a symlinked ~/.zshenv, caps at 5" {
  printf 'x\n' >"$AGENT_SECRETS_HOME/.local"
  _dry
  [ "$status" -eq 1 ]
  [[ "$output" == *"$AGENT_SECRETS_HOME/.local already exists and is not a directory"* ]] || return 1
  rm -f "$AGENT_SECRETS_HOME/.local"
  mkdir "$AGENT_SECRETS_HOME/.zshenv"
  _dry
  [ "$status" -eq 1 ]
  [[ "$output" == *"$AGENT_SECRETS_HOME/.zshenv is a directory"* ]] || return 1
  rmdir "$AGENT_SECRETS_HOME/.zshenv"
  mkdir -p "$AGENT_SECRETS_HOME/dotfiles"; : >"$AGENT_SECRETS_HOME/dotfiles/zshenv"
  ln -s "$AGENT_SECRETS_HOME/dotfiles/zshenv" "$AGENT_SECRETS_HOME/.zshenv"
  _dry
  [ "$status" -eq 0 ]
  # Six conflicts: five are listed, the sixth is counted.
  local p
  for p in bin Library .agent-secrets .local; do printf 'x\n' >"$AGENT_SECRETS_HOME/$p"; done
  rm -f "$AGENT_SECRETS_HOME/.zshenv"; mkdir "$AGENT_SECRETS_HOME/.zshenv" "$AGENT_SECRETS_HOME/.bash_profile"
  DRY_ENV=(SHELL=/bin/bash)
  _dry
  [ "$status" -eq 1 ]
  [[ "$output" == *"6 path(s)"* ]] || return 1
  [ "$(printf '%s\n' "$output" | grep -cE 'is not a directory|is a directory,')" -eq 5 ]
  [[ "$output" == *"and 1 more"* ]] || return 1
}

# ---- dry run: digest status and the printed command ---------------------------------------------

@test "an unbaked copy on the default URL shows REFUSE and no install command, exit 0" {
  _dry
  [ "$status" -eq 0 ]
  [[ "$output" == *"REFUSE: this install.sh has no baked release digest"* ]] || return 1
  [[ "$output" == *"Install from a published release tag, or set AGENT_SECRETS_BASE_URL."* ]] || return 1
  [[ "$output" != *"Local checks passed"* ]] || return 1
  [[ "$output" != *"SHA-256 verified"* ]] || return 1
}

@test "with a mirror the dry run prints a runnable command built by _self_cmd with the same flags" {
  local line log="$BATS_TEST_TMPDIR/curl.log"
  DRY_ENV=(AGENT_SECRETS_BASE_URL=https://mirror.example)
  _dry --headless --no-discovery --import-env A,B_2 --no-color
  [ "$status" -eq 0 ]
  [[ "$output" == *"Local checks passed. To install with this plan (download and dependency steps were not checked):"* ]] || return 1
  line="$(printf '%s\n' "$output" | grep -A1 '^Local checks passed' | tail -1)"; line="${line#    }"
  [ "${line%% --*}" = "$(printf 'bash %q' "$REPO_ROOT/install.sh")" ]
  # %q may or may not escape the comma (bash 3.2 does not, bash 5 does); both forms run.
  [[ "${line#* --}" == "headless --import-env A"*",B_2 --no-discovery --no-color" ]] || return 1
  # The printed command passes the parse-only seam: exit 0, silent, no fetch.
  : >"$log"
  run env AGSEC_PARSE_ONLY=1 AGSEC_MOCK_CURL_LOG="$log" bash -c "$line" </dev/null
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -s "$log" ]
}

@test "in the pipe form the printed command downloads then runs, keeps the flags and passes the parse-only seam" {
  local line dl="$BATS_TEST_TMPDIR/dl"
  mkdir -p "$dl"; cp "$REPO_ROOT/install.sh" "$dl/install.sh"
  run mm_no_ctty "${_CLEAN[@]}" AGENT_SECRETS_BASE_URL='https://u:SEKRET@mirror.example' \
      bash -s -- --dry-run --headless --discovery <"$REPO_ROOT/install.sh"
  [ "$status" -eq 0 ]
  [[ "$output" != *SEKRET* ]] || return 1
  line="$(printf '%s\n' "$output" | grep -A1 '^Local checks passed' | tail -1)"; line="${line#    }"
  [[ "$line" == 'f="$(mktemp '*' && curl -fsSL https://raw.githubusercontent.com/'*'/install.sh -o "$f" && AGENT_SECRETS_BASE_URL=<URL> bash "$f" --headless --discovery' ]] || return 1
  line="${line//<URL>/https://mirror.example}"
  run env AGSEC_PARSE_ONLY=1 AGSEC_MOCK_DL_DIR="$dl" bash -c "$line" </dev/null
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "--dry-run --import-env 1BAD is a usage error (exit 2) and renders no plan" {
  _dry --import-env 1BAD
  [ "$status" -eq 2 ]
  [[ "$output" != *"agent-secrets installer"* ]] || return 1
}

# ---- the plan's rows --------------------------------------------------------------------------

@test "Source rows name a set mirror (credentials masked) and a set install home, and only then" {
  DRY_ENV=(AGENT_SECRETS_BASE_URL='https://u:SEKRET@mirror.example/p?token=SEKRET')
  _dry
  [ "$status" -eq 0 ]
  [[ "$output" == *"Source: https://***@mirror.example/p (AGENT_SECRETS_BASE_URL)"* ]] || return 1
  [[ "$output" == *"Source: $AGENT_SECRETS_HOME (AGENT_SECRETS_HOME)"* ]] || return 1
  [[ "$output" != *SEKRET* ]] || return 1
  # The default: no install-home override, no mirror. The settings.json row then needs no "(at …)".
  run mm_no_ctty "${_CLEAN[@]}" -u AGENT_SECRETS_HOME HOME="$AGENT_SECRETS_HOME" bash "$REPO_ROOT/install.sh" --dry-run </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" != *"Source:"* ]] || return 1
  [[ "$output" == *"back up an existing ~/.claude/settings.json as the revert point"* ]] || return 1
  # An install home that differs from HOME is named on the settings.json row.
  _dry
  [[ "$output" == *"back up an existing ~/.claude/settings.json (at $AGENT_SECRETS_HOME/.claude/settings.json)"* ]] || return 1
}

@test "trust wording keys on the baked digest: verified even on a mirror; an unbaked mirror says .sha256" {
  DRY_SCRIPT="$(_fake_baked)"
  DRY_ENV=(AGENT_SECRETS_BASE_URL=https://mirror.example)
  _dry
  [ "$status" -eq 0 ]
  [[ "$output" == *", SHA-256 verified)"* ]] || return 1
  [[ "$output" == *"verify the download against the baked SHA-256 digest"* ]] || return 1
  [[ "$output" == *"Local checks passed"* ]] || return 1
  DRY_ENV=()
  _dry
  [[ "$output" == *", SHA-256 verified)"* ]] || return 1
  [[ "$output" == *"Local checks passed"* ]] || return 1
  DRY_SCRIPT=""
  DRY_ENV=(AGENT_SECRETS_BASE_URL=https://mirror.example)
  _dry
  [[ "$output" == *"checked only against the mirror's own .sha256"* ]] || return 1
  [[ "$output" == *"transport integrity only, not tamper evidence"* ]] || return 1
  [[ "$output" != *"SHA-256 verified"* ]] || return 1
}

@test "an existing install: same version repairs, older upgrades, newer warns of a downgrade (numeric compare)" {
  local cur maj min pat d="$AGENT_SECRETS_HOME/.agent-secrets"
  cur="$(cat "$REPO_ROOT/VERSION")"; maj="${cur%%.*}"; pat="${cur##*.}"; min="${cur#*.}"; min="${min%.*}"
  _dry
  [[ "$output" != *"cannot be undone"* ]] || return 1          # nothing to replace
  mkdir -p "$d"
  printf '%s\n' "$cur" >"$d/VERSION"; _dry
  [[ "$output" == *"agent-secrets v$cur is already installed. Re-applying it to repair dependencies, wiring and agent rules."* ]] || return 1
  [[ "$output" == *"Some effects cannot be undone"* ]] || return 1
  printf '0.0.0\n' >"$d/VERSION"; _dry
  [[ "$output" == *"Upgrading agent-secrets v0.0.0 to v$cur."* ]] || return 1
  # Lexically "x.y.(p+10)" sorts before "x.y.p"; numerically it is newer.
  printf '%s.%s.%s\n' "$maj" "$min" "$((pat + 10))" >"$d/VERSION"; _dry
  [ "$status" -eq 0 ]
  [[ "$output" == *"Warning: this downgrades agent-secrets v$maj.$min.$((pat + 10)) to v$cur."* ]] || return 1
  printf 'not-a-version\n' >"$d/VERSION"; _dry
  [[ "$output" == *"already installed at $d (version unknown)"* ]] || return 1
  [[ "$output" != *"not-a-version"* ]] || return 1
}

@test "the plan names each foreign ~/bin target it replaces, with the backup path for a regular file" {
  local b="$AGENT_SECRETS_HOME/bin"
  mkdir -p "$b"
  printf '#!/bin/sh\n' >"$b/claude-agent"
  ln -s /nonexistent/elsewhere "$b/cursor-agent"
  ln -s "$AGENT_SECRETS_HOME/.agent-secrets/bin/apiKeyHelper" "$b/apiKeyHelper"   # already ours
  _dry
  [ "$status" -eq 0 ]
  [[ "$output" == *"agent-secrets, claude-agent, cursor-agent, apiKeyHelper"* ]] || return 1
  [[ "$output" == *"replace your existing $b/claude-agent (backed up to $AGENT_SECRETS_HOME/.local/state/agent-secrets/claude-agent.preinstall.bak; uninstall restores it)"* ]] || return 1
  [[ "$output" == *"replace your existing symlink $b/cursor-agent"* ]] || return 1
  [ "$(printf '%s\n' "$output" | grep -c 'replace your existing')" -eq 2 ]
}

@test "the plan's agent-rule paths match the discovery registry, one row per AGSEC_DISCOVERY_KEYS entry" {
  local plan want
  _dry
  [ "$status" -eq 0 ]
  plan="$(printf '%s\n' "$output" | sed -n 's|^      \(/[^ ]*\)   .*|\1|p')"
  want="$(env -u AGSEC_DISCOVERY_KEYS bash -c '. "$1/lib/common.sh"; . "$1/lib/discovery.sh"
          for k in $AGSEC_DISCOVERY_KEYS; do _disc_field "$k" 2; done' _ "$REPO_ROOT")"
  [ -n "$want" ]
  if [ "$plan" != "$want" ]; then printf 'plan:\n%s\nregistry:\n%s\n' "$plan" "$want" >&2; return 1; fi
  [[ "$output" == *"org/MDM-managed"* ]] || return 1
}

@test "without an install home the rule paths follow CLAUDE_CONFIG_DIR and CODEX_HOME, plus the literal ~/.claude copy" {
  local h="$AGENT_SECRETS_HOME"
  run mm_no_ctty "${_CLEAN[@]}" -u AGENT_SECRETS_HOME HOME="$h" CLAUDE_CONFIG_DIR="$h/cfg" CODEX_HOME="$h/cx" \
      bash "$REPO_ROOT/install.sh" --dry-run </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"      $h/cfg/CLAUDE.md   "* ]] || return 1
  [[ "$output" == *"      $h/.claude/CLAUDE.md   "* ]] || return 1
  [[ "$output" == *"      $h/cx/AGENTS.md   "* ]] || return 1
}

@test "plan copy never promises reversibility and names what uninstall rolls back" {
  _dry
  [ "$status" -eq 0 ]
  [[ "$output" != *"reversible"* ]] || return 1
  [[ "$output" != *"one-command uninstall"* ]] || return 1
  [[ "$output" == *"('agent-secrets uninstall' rolls back recorded entries; Homebrew-installed tools are not recorded)"* ]] || return 1
  [[ "$output" == *"advisory; recorded in the manifest; --no-discovery skips"* ]] || return 1
  mm_run tty -- bash "$REPO_ROOT/install.sh" --dry-run
  [ "$mm_status" -eq 0 ]
  [[ "$mm_pty" != *"reversible"* ]] || return 1
  [[ "$mm_pty" != *"one-command uninstall"* ]] || return 1
}

# ---- mode: one resolver, the same answer as setup ---------------------------------------------

@test "on a terminal the offer comes after setup; --discovery, --import-env, --no-discovery and --headless change it" {
  local o s
  mm_run tty -- bash "$REPO_ROOT/install.sh" --dry-run
  [ "$mm_status" -eq 0 ]
  [ "$(_plan_mode "$mm_pty")" = wizard ]
  s="$(printf '%s\n' "$mm_pty" | grep -n "run 'agent-secrets setup' at the end" | cut -d: -f1)"
  o="$(printf '%s\n' "$mm_pty" | grep -n 'after setup, OFFER (opt-in)' | cut -d: -f1)"
  { [ -n "$s" ] && [ -n "$o" ] && [ "$s" -lt "$o" ]; } || return 1
  mm_run tty -- bash "$REPO_ROOT/install.sh" --dry-run --discovery
  [[ "$mm_pty" == *"(--discovery, no offer)"* ]] || return 1
  [[ "$mm_pty" != *"OFFER"* ]] || return 1
  # --import-env makes setup headless (and it writes the rules itself), so neither wizard nor offer.
  mm_run tty -- bash "$REPO_ROOT/install.sh" --dry-run --import-env SOME_NAME
  [ "$(_plan_mode "$mm_pty")" = headless ]
  [[ "$mm_pty" != *"OFFER"* ]] || return 1
  mm_run tty -- bash "$REPO_ROOT/install.sh" --dry-run --no-discovery
  [[ "$mm_pty" == *"skip the machine-wide agent rules (--no-discovery)"* ]] || return 1
  [[ "$mm_pty" != *"OFFER"* ]] || return 1
  mm_run tty -- bash "$REPO_ROOT/install.sh" --dry-run --headless
  [ "$(_plan_mode "$mm_pty")" = headless ]
  [[ "$mm_pty" != *"OFFER"* ]] || return 1
}

@test "install's plan announces the setup mode setup_resolve_mode really picks, in every mode" {
  local h="$BATS_TEST_TMPDIR/setup_mode.sh" errf="$BATS_TEST_TMPDIR/err" ins sm m
  # setup's own resolver, lifted from cmd/setup.sh, run in the same environment as install.
  {
    printf '%s\n' 'UNATTENDED="${AGENT_SECRETS_UNATTENDED:-}"; HEADLESS=""; HEADLESS_WHY=""'
    printf '. %q\n' "$REPO_ROOT/lib/common.sh"
    sed -n '/^setup_resolve_mode() {/,/^}/p' "$REPO_ROOT/cmd/setup.sh"
    printf '%s\n' 'setup_resolve_mode' \
      'if [ -z "$UNATTENDED" ] && [ -z "$HEADLESS" ]; then echo the interactive wizard; else echo setup --headless; fi'
  } >"$h"
  [ "$(grep -c . "$h")" -gt 8 ]
  for m in tty ci-tty noninteractive-tty unattended-tty stderr-file-tty agent stdin-piped; do
    case "$m" in
      unattended-tty)
        mm_run tty -- env AGENT_SECRETS_UNATTENDED=1 bash "$REPO_ROOT/install.sh" --dry-run; ins="$mm_pty"
        mm_run tty -- env AGENT_SECRETS_UNATTENDED=1 bash "$h"; sm="$mm_pty" ;;
      stderr-file-tty)
        # shellcheck disable=SC2016  # expanded by the inner bash
        mm_run tty -- bash -c 'f="$1"; shift; exec "$@" 2>"$f"' _ "$errf" bash "$REPO_ROOT/install.sh" --dry-run
        ins="$(cat "$errf")"
        # shellcheck disable=SC2016
        mm_run tty -- bash -c 'f="$1"; shift; exec "$@" 2>"$f"' _ /dev/null bash "$h"; sm="$mm_pty" ;;
      agent|stdin-piped)
        mm_run "$m" -- bash "$REPO_ROOT/install.sh" --dry-run; ins="$mm_stderr"
        mm_run "$m" -- bash "$h"; sm="$mm_stdout" ;;
      *)
        mm_run "$m" -- bash "$REPO_ROOT/install.sh" --dry-run; ins="$mm_pty"
        mm_run "$m" -- bash "$h"; sm="$mm_pty" ;;
    esac
    if [ "$(_plan_mode "$ins")" != "$(_plan_mode "$sm")" ] || [ "$(_plan_mode "$ins")" = none ]; then
      printf 'mode %s: install plans %s, setup picks %s\n' "$m" "$(_plan_mode "$ins")" "$(_plan_mode "$sm")" >&2
      return 1
    fi
    if [ "$m" = tty ]; then [ "$(_plan_mode "$ins")" = wizard ] || return 1
    else [ "$(_plan_mode "$ins")" = headless ] || return 1; fi
  done
}

@test "terminal tests and the CI read live only in _attach_tty and _resolve_mode; the agent check precedes the attach" {
  local i="$REPO_ROOT/install.sh" body a b
  run awk '
    /^  (_attach_tty|_resolve_mode)\(\) \{/ { inside = 1; next }
    inside && /^  \}/ { inside = 0; next }
    inside { next }
    /^[[:space:]]*#/ { next }
    /-t [012]/ || /\$[{]?CI[^A-Za-z0-9_]/ { print NR ": " $0 }
  ' "$i"
  if [ -n "$output" ]; then printf 'outside the allowlist:\n%s\n' "$output" >&2; return 1; fi
  # Not vacuous: the resolver really reads both.
  body="$(sed -n '/^  _resolve_mode() {/,/^  }/p' "$i")"
  [[ "$body" == *'-t 2'* ]] || return 1
  [[ "$body" == *'${CI:-}'* ]] || return 1
  body="$(sed -n '/^  _attach_tty() {/,/^  }/p' "$i")"
  a="$(printf '%s\n' "$body" | grep -n 'AGENT' | head -1 | cut -d: -f1)"
  b="$(printf '%s\n' "$body" | grep -n 'exec 0</dev/tty' | cut -d: -f1)"
  { [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]; } || return 1
  # The inlined agent check is the same as the shared one (a documented bootstrap duplicate).
  a="$(sed -n '/^  _agent_session() {/,/^  }/p' "$i" | sed '1d;$d' | sed 's/^[[:space:]]*//')"
  b="$(sed -n '/^agsec_in_agent_session() {/,/^}/p' "$REPO_ROOT/lib/common.sh" | sed '1d;$d' | sed 's/^[[:space:]]*//')"
  [ -n "$a" ]
  [ "$a" = "$b" ]
}

# ---- consent ------------------------------------------------------------------------------------

@test "on a terminal the consent prompt names the targets, and EOF cancels with exit 130 before any fetch or write" {
  local log="$BATS_TEST_TMPDIR/curl.log"; : >"$log"
  mm_run tty -- env AGSEC_MOCK_CURL_LOG="$log" bash "$REPO_ROOT/install.sh"
  [ "$mm_status" -eq 130 ]
  [[ "$mm_pty" == *"Install agent-secrets to $AGENT_SECRETS_HOME/.agent-secrets and edit $AGENT_SECRETS_HOME/.zshenv? [Y/n]"* ]] || return 1
  [[ "$mm_pty" == *"Canceled. Nothing was changed."* ]] || return 1
  [[ "$mm_pty" != *"[d]"* ]] || return 1
  [ ! -s "$log" ]
  [ ! -e "$AGENT_SECRETS_HOME/.agent-secrets" ]
  [ ! -e "$AGENT_SECRETS_HOME/bin" ]
}

@test "with nobody to answer, the plan proceeds without a keypress and names the reason and the opt-outs" {
  local tail='proceeding with the plan above; --dry-run previews, --no-discovery skips the agent rules)'
  # The unbaked copy on the default URL stops at the download, after the consent step.
  run mm_no_ctty "${_CLEAN[@]}" bash "$REPO_ROOT/install.sh" </dev/null
  [ "$status" -ne 0 ]
  [[ "$output" == *"(no terminal: $tail"* ]] || return 1
  run mm_no_ctty "${_CLEAN[@]}" CLAUDECODE=1 bash "$REPO_ROOT/install.sh" </dev/null
  [[ "$output" == *"(coding-agent session: $tail"* ]] || return 1
  # CI and AGENT_SECRETS_NONINTERACTIVE skip the keypress even on a terminal.
  mm_run ci-tty -- bash "$REPO_ROOT/install.sh"
  [ "$mm_status" -ne 130 ]
  [[ "$mm_pty" == *"(non-interactive: $tail"* ]] || return 1
  [[ "$mm_pty" != *"[Y/n]"* ]] || return 1
  mm_run noninteractive-tty -- bash "$REPO_ROOT/install.sh"
  [[ "$mm_pty" == *"(non-interactive: $tail"* ]] || return 1
  [[ "$mm_pty" != *"[Y/n]"* ]] || return 1
  [ ! -e "$AGENT_SECRETS_HOME/.agent-secrets" ]
}

# ---- full installs --------------------------------------------------------------------------------

@test "an unbaked mirror install says .sha256 at run time, never 'SHA-256 verified', and offers nothing without a terminal" {
  local argv="$BATS_TEST_TMPDIR/setup.argv" envl="$BATS_TEST_TMPDIR/setup.env"
  _build_mirror
  _shim_setup_in_mirror
  run mm_no_ctty "${_CLEAN[@]}" AGENT_SECRETS_BASE_URL=https://mirror.example AGSEC_MOCK_DL_DIR="$MIRROR" \
      AGSEC_SETUP_ARGV_LOG="$argv" AGSEC_SETUP_ENV_LOG="$envl" bash "$REPO_ROOT/install.sh" </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"Checked only against the mirror's own .sha256: transport integrity, not tamper evidence."* ]] || return 1
  [[ "$output" != *"SHA-256 verified"* ]] || return 1
  [[ "$output" != *"Make every coding agent"* ]] || return 1
  [ "$(cat "$argv")" = setup ]
  grep -qx AGENT_SECRETS_BIN "$envl"
}

@test "AGENT_SECRETS_UNATTENDED on a terminal never rebinds stdin: a piped seed line reaches setup" {
  local baked seed=fake-b11-seed-placeholder
  _build_mirror
  baked="$(_bake_install)"
  # Inside a pty, so /dev/tty is attachable; the old rebind would discard the piped line.
  # shellcheck disable=SC2016  # expanded by the inner bash
  MM_TIMEOUT=1500 mm_run tty -- env AGENT_SECRETS_UNATTENDED=1 \
      bash -c 'printf "%s\n" "$1" | bash "$2"' _ "$seed" "$baked"
  [ "$mm_status" -eq 0 ]
  [[ "$mm_pty" == *"(unattended: proceeding with the plan above"* ]] || return 1
  [[ "$mm_pty" != *"$seed"* ]] || return 1
  [ "$(env AGENT_SECRETS_HOME="$AGENT_SECRETS_HOME" "$AGENT_SECRETS_HOME/bin/apiKeyHelper" 2>/dev/null)" = "$seed" ]
}
