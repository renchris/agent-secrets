#!/usr/bin/env bash
# install.sh — one-command bootstrap (curl'd).
# FUNCTION-GUARDED (main(){…}; main "$@") so a truncated download can never partial-exec
# Consent gate is the FIRST screen; --dry-run = plan-then-apply (the rendered
# plan is exactly what executes). STOP-ASK gates have NO --force/env bypass.
# Install from a PINNED release tag (never main); SHA-256 verify any artifact before running it.
# AGENT_SECRETS_BASE_URL overrides the source (private-repo / corporate mirror; the smoke test
# uses it). Records every TOOL artifact via lib/manifest.sh; no secret value ever handled.

# --- bash guard (must be POSIX-clean: NOTHING above this may use a bashism) -------------------
# The README one-liner runs this via `bash -c "$(curl…)"`. If a user instead pipes it to `sh`
# (`sh -c "$(curl…)"`, or `sh install.sh`), macOS runs it under /bin/sh, which sources lib/manifest.sh
# and dies on its process substitution (`< <(…)`) with "syntax error near unexpected token \`<'".
# Re-exec under a real bash so the install works whether the user typed `bash` OR `sh`.
# CRUCIAL: macOS /bin/sh IS bash 3.2 in POSIX mode — it SETS BASH_VERSION yet still rejects that syntax
# — so keying only on BASH_VERSION would SKIP the re-exec on the exact `sh` invocations we target
# (verified: /bin/sh has BASH_VERSION set AND `shopt -qo posix` true). Re-exec when there is no bash at
# all OR bash is in POSIX mode. AGSEC_REEXECED is a sentinel so the re-exec'd (non-POSIX) bash can never
# loop. File case ($0 is a real path) re-execs in place; the curl-pipe case re-fetches (mirror override
# via AGENT_SECRETS_INSTALL_URL). `shopt` never runs under a true POSIX sh: `[ -z BASH_VERSION ]` is
# true there and short-circuits the `||`.
if [ -z "${AGSEC_REEXECED:-}" ] && { [ -z "${BASH_VERSION:-}" ] || shopt -qo posix 2>/dev/null; }; then
  AGSEC_REEXECED=1; export AGSEC_REEXECED
  if [ -f "$0" ]; then exec bash "$0" "$@"; fi        # file case: re-exec in place, no re-download
  # curl-pipe case ($0 is "sh", no file): re-fetch from the pinned raw-git channel and hand to bash.
  # Capture first so a failed re-fetch fails LOUD — `bash -c "$(curl…)"` inline would silently run an
  # empty program (exit 0) on a network error, a no-op masquerading as success.
  _agsec_tag="v0.1.0"; _agsec_repo="renchris/agent-secrets"
  _agsec_self_url="${AGENT_SECRETS_INSTALL_URL:-https://raw.githubusercontent.com/${_agsec_repo}/${_agsec_tag}/install.sh}"
  _agsec_src="$(curl -fsSL "$_agsec_self_url")" || _agsec_src=""
  [ -n "$_agsec_src" ] || { printf 'ERROR: could not re-fetch install.sh to re-exec under bash. Re-run the README one-liner with bash (not sh) — it curl-pipes this URL: %s\n' "$_agsec_self_url" >&2; exit 1; }
  exec bash -c "$_agsec_src" bash "$@"
fi

set -euo pipefail

main() {
  # --- pinned trust anchors ----------------------------------------------------
  # The tag is PINNED — never `main` (a moving ref is an unreviewed-code RCE). Repo-jacking guard:
  # if this project is ever renamed, the OLD GitHub name MUST be retained (a freed name can be
  # re-registered by an attacker and would serve this exact URL).
  local PINNED_TAG="v0.1.0"
  local REPO="renchris/agent-secrets"   # keep the old name reserved forever on any future rename
  local BASE_URL="${AGENT_SECRETS_BASE_URL:-https://github.com/${REPO}}"
  # EXPECTED_SHA256 is BAKED IN at release-tag time by the release runbook (README "Cut a release").
  # THIS curl'd script travels the git-ref channel (raw.githubusercontent at the PINNED tag), so the
  # digest is the trust root — a channel DISTINCT from the swappable release-asset tarball it verifies.
  # It is empty on `main` (unreleased): the default production URL then REFUSES to install (a same-origin
  # .sha256 is no defense against a swapped asset); only a dev/mirror (AGENT_SECRETS_BASE_URL) falls back
  # to the sibling .sha256 for transport integrity. See the SHA-256 gate below.
  local EXPECTED_SHA256="bc480ad72e4e49393b769636befd54186bcb760350ba6a50b7382809704e1211"

  local HOME_DIR="${AGENT_SECRETS_HOME:-$HOME}"
  local INSTALL_DIR="$HOME_DIR/.agent-secrets"
  local BIN_DIR="$HOME_DIR/bin"
  local STATE_DIR="$HOME_DIR/.local/state/agent-secrets"
  local RC_FILE="$HOME_DIR/.zshenv"        # sourced by every zsh invocation incl. Cursor subshells
  # zsh is the macOS default, but a bash-login user never reads ~/.zshenv, so the PATH block would be
  # inert and `agent-secrets` unfound by name in every bash terminal (incl. agent subshells). When the
  # login shell is bash, ALSO write a block to the FIRST EXISTING of .bash_profile/.bash_login/.profile
  # (bash reads only the first of those) — creating .bash_profile when none exist would SHADOW an
  # existing ~/.profile, so pick the existing one.
  local BASH_RC_FILE=""
  case "${SHELL:-}" in
    */bash)
      BASH_RC_FILE="$HOME_DIR/.bash_profile"
      local _rc
      for _rc in .bash_profile .bash_login .profile; do
        if [ -f "$HOME_DIR/$_rc" ]; then BASH_RC_FILE="$HOME_DIR/$_rc"; break; fi
      done ;;
  esac
  local PATH_MARKER="agent-secrets"
  local DISCOVERY_MARKER="agent-secrets"   # marker for the opt-in ~/.claude/CLAUDE.md discovery block (doctor greps it; uninstall strips it)
  local SMOKE_LABEL="com.agent-secrets.smoke"
  local SMOKE_PLIST="$HOME_DIR/Library/LaunchAgents/${SMOKE_LABEL}.plist"

  local DRY_RUN=0
  [ "${1:-}" = "--dry-run" ] && DRY_RUN=1

  _say()  { printf '%s\n' "$*" >&2; }
  _step() { printf '  → %s\n' "$*" >&2; }
  _die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
  _run()  { if [ "$DRY_RUN" -eq 1 ]; then _step "$*"; else _step "$*"; "$@"; fi; }

  # --- the plan (rendered identically for consent + dry-run) -------------------
  _render_plan() {
    _say ""
    _say "agent-secrets installer — this will:"
    _say "  • ensure age, sops, gum, jq (reuse yours · Homebrew if present · else pinned, SHA-256-verified downloads — no sudo)"
    _say "  • install the tool under $INSTALL_DIR   (pinned $PINNED_TAG, SHA-256 verified)"
    _say "  • symlink the command + wrappers into $BIN_DIR   (agent-secrets, claude-agent, cursor-agent, apiKeyHelper)"
    _say "  • add a marker-delimited PATH block to $RC_FILE${BASH_RC_FILE:+ (and $BASH_RC_FILE — your login shell is bash)}"
    _say "  • install a weekly launchd smoke job ($SMOKE_LABEL)"
    _say "  • (via 'agent-secrets setup') back up an existing ~/.claude/settings.json as the revert point for its apiKeyHelper edit"
    _say "  • OFFER (opt-in, interactive terminal only) to add agent-secrets rules to ~/.claude/CLAUDE.md so agents in EVERY repo know to use it"
    _say "  • record every change to $STATE_DIR/install-manifest.json (one-command uninstall)"
    _say "  • run 'agent-secrets setup' at the end (in a coding-agent session OR a non-interactive install: install now, then finish setup in a real terminal)"
    _say ""
  }

  # --- consent gate — FIRST screen, nothing mutates before it ------------------
  if [ "$DRY_RUN" -eq 1 ]; then
    _say "DRY RUN — showing the plan, changing nothing."
    _render_plan
    _say "Re-run without --dry-run to apply exactly this plan."
    return 0
  fi
  _render_plan
  # Consent is an interactive, human gate (no --force/env bypass). When stdin is a TTY, require the
  # keypress. When it is NOT a tty — a piped `curl … | bash`, or a coding-agent session whose stdin is
  # /dev/null or an open-but-empty pipe — there is no human at the terminal: the plan was just shown
  # (the disclosure) and running the installer IS the consent, so proceed. Blocking on `read` here would
  # otherwise abort under `set -e` on EOF (closed stdin) or hang forever (open pipe) — and, for an agent
  # session, would never reach the exit-0 key-ceremony deferral below.
  if [ -t 0 ]; then
    printf '[Enter] continue · [d] show the full dry-run first · Ctrl-C stop: ' >&2
    local reply=""; read -r reply || reply=""
    if [ "$reply" = "d" ] || [ "$reply" = "D" ]; then
      DRY_RUN=1; _render_plan; DRY_RUN=0
      printf '[Enter] continue · Ctrl-C stop: ' >&2; read -r reply || reply=""
    fi
  else
    _say "(non-interactive stdin — proceeding with the plan above; run in a terminal to review step by step)"
  fi

  # --- preflight: a regular file (or dangling symlink) where we need a directory --------------------
  # `mkdir -p` below would die "File exists" under set -e AFTER partially creating siblings, leaving
  # residue with no manifest to roll back. Catch it here — pre-network, pre-mutation — and name the
  # conflict. The `if`-form is load-bearing: a `[ … ] && [ … ] && _die` chain returns nonzero on the
  # healthy (dir-absent) path and would abort the install under set -e. A symlink TO a directory passes
  # (`[ ! -d ]` follows links), so a legitimately symlinked ~/bin is unaffected.
  local _d
  for _d in "$INSTALL_DIR" "$BIN_DIR" "$STATE_DIR"; do
    if { [ -e "$_d" ] || [ -L "$_d" ]; } && [ ! -d "$_d" ]; then
      _die "$_d already exists and is not a directory — move it aside, then re-run the installer"
    fi
  done

  # --- toolchain: resolved AFTER unpack, from the tool's own lib/deps.sh -----------------------------
  # (This USED to `brew install age sops gum jq` behind a sudo-gated Homebrew bootstrap — the #1
  #  corporate blocker in ONE_COMMAND_INSTALL_FEEDBACK.md. deps_ensure below now resolves each tool
  #  NO-SUDO: reuse a PATH copy → Homebrew if already present → else a pinned, SHA-256-verified static
  #  binary. It lives in lib/deps.sh, so it can only run once the tarball is unpacked — hence the move.)

  # --- download + SHA-256 verify (never execute an unverified artifact) --------
  local work; work="$(mktemp -d)"
  local pkg="$work/agent-secrets-${PINNED_TAG}.tar.gz"
  local url="$BASE_URL/releases/download/${PINNED_TAG}/agent-secrets-${PINNED_TAG}.tar.gz"
  _say "Downloading ${PINNED_TAG}…"
  _run curl -fsSL "$url" -o "$pkg"
  local got expect
  got="$(shasum -a 256 "$pkg" | awk '{print $1}')"
  if [ -n "$EXPECTED_SHA256" ]; then
    # Production path: the digest was baked into THIS script (git-ref channel) at release-tag time, so a
    # swapped release-asset tarball fails here — real release-asset tamper-evidence, not same-origin trust.
    expect="$EXPECTED_SHA256"
  elif [ -n "${AGENT_SECRETS_BASE_URL:-}" ]; then
    # Dev/mirror convenience ONLY (BASE_URL overridden): trust a sibling .sha256 from the mirror you
    # control. This is transport integrity (corruption/partial-download), NOT release-asset tamper-evidence.
    _run curl -fsSL "$url.sha256" -o "$pkg.sha256"
    expect="$(awk '{print $1}' "$pkg.sha256")"
  else
    _die "this install.sh carries no baked release digest (EXPECTED_SHA256 empty) — it was not cut by the release runbook. Refusing a same-origin .sha256 fallback on the default production URL (it cannot detect a swapped release asset). Install from a published release tag, or set AGENT_SECRETS_BASE_URL to use a dev/mirror."
  fi
  [ "$got" = "$expect" ] || _die "SHA-256 mismatch — refusing to run the downloaded artifact"
  _say "SHA-256 verified."

  # --- unpack the tool ---------------------------------------------------------
  # Was $INSTALL_DIR created by THIS run? A re-run over an existing (live) install must never have its
  # tool dir deleted by the pre-manifest abort trap below (RT6), so only arm that trap when fresh.
  local FRESH_INSTALL=0; [ -d "$INSTALL_DIR" ] || FRESH_INSTALL=1
  _run mkdir -p "$INSTALL_DIR" "$BIN_DIR" "$STATE_DIR"
  _run tar -xzf "$pkg" -C "$INSTALL_DIR" --strip-components=1
  # Fail LOUDLY on a mis-cut tarball (wrong/missing top-level prefix flattens the layout and would
  # dangle every wrapper symlink) instead of a cryptic `set -e` abort on the first source below. The
  # release runbook pins `git archive --prefix=agent-secrets-${TAG}/` to guarantee the single prefix dir.
  # Check BOTH a lib and the dispatcher: a tarball missing bin/agent-secrets would otherwise dangle the
  # dispatcher symlink, and manifest_record_file (which follows the link) returns 1 → set -e abort AFTER
  # the cleanup trap is disarmed → half-wired install with no rollback.
  [ "$DRY_RUN" -eq 1 ] || { [ -f "$INSTALL_DIR/lib/common.sh" ] && [ -f "$INSTALL_DIR/bin/agent-secrets" ]; } \
    || _die "unexpected tarball layout (need one top-level prefix dir with bin/ + lib/) — re-cut with: git archive --prefix=agent-secrets-\${TAG}/ \${TAG}"

  # Cleanup trap for the pre-manifest window: from here until $INSTALL_DIR is recorded, an abort — e.g. a
  # REQUIRED dependency that can't be fetched on a locked-down network (deps_ensure below) — would strand
  # the unpacked tool with NO manifest to roll back (the residue regression the reorder introduced).
  # Remove ONLY what we just created: $INSTALL_DIR (removed only when created fresh THIS run — a re-run
  # over a live install must never be deleted by an abort) plus the two tool dirs if still empty (rmdir
  # is a no-op on a pre-existing ~/bin holding the user's files). Disarmed the instant the manifest
  # records $INSTALL_DIR, so the success path + uninstall are unaffected.
  # The paths MUST be baked in NOW (%q-quoted so any shell metacharacter in an exotic AGENT_SECRETS_HOME
  # stays safe): a named handler is NOT an option — main()'s locals are already out of scope by the time
  # the EXIT trap fires while the shell unwinds through an `exit` on an abort (verified under bash 3.2).
  if [ "$FRESH_INSTALL" -eq 1 ]; then
    local _cleanup_cmd
    printf -v _cleanup_cmd 'rm -rf -- %q; rmdir -- %q %q 2>/dev/null || true' "$INSTALL_DIR" "$STATE_DIR" "$BIN_DIR"
    # shellcheck disable=SC2064  # expand-now via the pre-built %q string is DELIBERATE (see above)
    trap "$_cleanup_cmd" EXIT
  fi

  # From here on the tool's own libs exist — source them to record artifacts.
  # shellcheck source=/dev/null
  . "$INSTALL_DIR/lib/common.sh"
  # Resolve the toolchain NO-SUDO before anything below needs it: manifest.sh + every artifact-record
  # call use jq, and setup/store need age+sops. deps_ensure reuses a PATH copy → Homebrew if present →
  # else fetches pinned SHA-256-verified binaries into $INSTALL_DIR/vendor/bin (inside the recorded
  # install dir, so uninstall removes them) and puts that dir on PATH for the rest of this install
  # (common.sh re-adds it at runtime for the wrappers).
  # shellcheck source=/dev/null
  . "$INSTALL_DIR/lib/deps.sh"
  export AGENT_SECRETS_VENDOR_BIN="$INSTALL_DIR/vendor/bin"
  deps_ensure
  # shellcheck source=/dev/null
  . "$INSTALL_DIR/lib/manifest.sh"
  agsec_secure_umask
  manifest_init

  # Wire the bin dispatcher + wrappers as SYMLINKS onto PATH (they follow the link back to their
  # sibling lib/ under $INSTALL_DIR — a plain copy would strand them from lib/). Record each symlink
  # for rollback, and record $INSTALL_DIR itself so uninstall removes the unpacked tool (no residue).
  manifest_record_file "$INSTALL_DIR" >/dev/null 2>&1 || true
  trap - EXIT   # $INSTALL_DIR is now recorded → uninstall can roll it back; disarm the pre-manifest cleanup
  # A pre-existing NON-symlink at a target on PATH is the USER'S own file — `ln -sf` clobbers it and
  # uninstall's `rm -f` of the `file` record would finish the loss. Write-once backup + an `edit` record
  # (appended BEFORE the file record: LIFO rollback removes the symlink first, then restores the file).
  _bak_user_target() {
    local t="$1" b
    if [ -f "$t" ] && [ ! -L "$t" ]; then
      b="$STATE_DIR/$(basename "$t").preinstall.bak"
      [ -f "$b" ] || cp -p "$t" "$b"
      manifest_record_edit "$t" "$b" >/dev/null 2>&1 || true
    fi
  }
  local f
  _bak_user_target "$BIN_DIR/agent-secrets"
  _run ln -sf "$INSTALL_DIR/bin/agent-secrets" "$BIN_DIR/agent-secrets"
  manifest_record_file "$BIN_DIR/agent-secrets"
  for f in claude-agent cursor-agent apiKeyHelper; do
    [ -f "$INSTALL_DIR/bin/$f" ] || continue
    _bak_user_target "$BIN_DIR/$f"
    _run ln -sf "$INSTALL_DIR/bin/$f" "$BIN_DIR/$f"
    manifest_record_file "$BIN_DIR/$f"
  done

  # Idempotent, marker-delimited PATH block → shell rc (recorded for total rollback).
  manifest_pathblock_install "$RC_FILE" "$PATH_MARKER" "export PATH=\"$BIN_DIR:\$PATH\""
  # Bash-login users also get the block in their login rc (see BASH_RC_FILE above); recorded → uninstall
  # strips it via the same _manifest_rb_pathblock.
  if [ -n "$BASH_RC_FILE" ]; then
    manifest_pathblock_install "$BASH_RC_FILE" "$PATH_MARKER" "export PATH=\"$BIN_DIR:\$PATH\""
  fi

  # Weekly launchd smoke job. Written from the tool's own template.
  _run mkdir -p "$HOME_DIR/Library/LaunchAgents"
  _install_smoke_plist "$SMOKE_PLIST" "$SMOKE_LABEL" "$INSTALL_DIR"
  if [ "$DRY_RUN" -eq 0 ]; then
    launchctl bootout "gui/$(id -u)/$SMOKE_LABEL" >/dev/null 2>&1 || true
    launchctl bootstrap "gui/$(id -u)" "$SMOKE_PLIST" >/dev/null 2>&1 || true
    manifest_record_launchd "$SMOKE_LABEL" "$SMOKE_PLIST"
  fi

  # The ~/.claude/settings.json apiKeyHelper edit + its revert point are owned SOLELY by `setup`
  # (_wire_tools): it records a write-once backup when the file pre-existed, or a `created` marker when
  # it did not (rollback then deletes the tool-made file instead of leaving an empty {}). Recording it
  # here too would double the revert record, so the installer intentionally does not.

  # --- OPT-IN: machine-wide agent discovery ------------------------------------
  # Claude Code loads ~/.claude/CLAUDE.md into EVERY session in EVERY repo, so a marker-delimited
  # block there teaches agents everywhere that this Mac has agent-secrets (the repo AGENTS.md is
  # repo-scoped; apiKeyHelper only auths Claude Code's own key). OPT-IN, recorded as a pathblock so
  # uninstall strips it. Interactive stdin only — piped/CI installs skip it (safe default: no edit).
  local claude_md="$HOME_DIR/.claude/CLAUDE.md"
  if [ -t 0 ] && [ "$DRY_RUN" -eq 0 ]; then
    printf '\nMake every coding agent on this Mac aware of agent-secrets?\n' >&2
    printf 'Appends a short, reversible block to ~/.claude/CLAUDE.md (Claude Code reads it in every repo).\n' >&2
    printf '[y = yes, recommended · Enter = skip]: ' >&2
    local dreply=''; read -r dreply || dreply=''
    case "$dreply" in
      [yY]*)
        mkdir -p "$(dirname "$claude_md")"
        manifest_pathblock_install "$claude_md" "$DISCOVERY_MARKER" "$(_discovery_block)"
        _say "  → added agent-secrets rules to ~/.claude/CLAUDE.md (uninstall strips them)" ;;
      *)
        _say "  → skipped machine-wide discovery (add later by re-running the installer)" ;;
    esac
  fi

  # --- finish: the key ceremony ------------------------------------------------
  # setup mints your age key and takes your first secret — a secret-bearing ceremony. Inside a coding-
  # agent session (Cursor/Claude Code) the transcript would capture those, so setup refuses there. The
  # TOOL install above is complete and exit-0 regardless; we simply route the human to a real terminal
  # for the ceremony instead of running (and failing) it here. UNATTENDED (tests/CI) runs it with fakes.
  _say ""
  # Defer the ceremony when there is no interactive terminal to run it in — an agent session (secret-
  # bearing transcript) OR any non-tty stdin (`curl … | bash`, ssh, cron). Chaining setup there would
  # read EOF at the hidden prompts and silently store an EMPTY first secret. UNATTENDED (tests/CI) still
  # runs it with fake values.
  if { agsec_in_agent_session || [ ! -t 0 ]; } && [ -z "${AGENT_SECRETS_UNATTENDED:-}" ]; then
    _say "${C_GREEN}✓${C_RESET} agent-secrets is installed — one step left."
    _say ""
    _say "The key ceremony was ${C_BOLD}not${C_RESET} run here (a coding-agent session, or a non-interactive"
    _say "install with no terminal) on purpose: it mints your encryption key and takes your first"
    _say "secret, which must not land in a transcript or be read from a dead pipe. Finish it in a ${C_BOLD}real terminal${C_RESET}:"
    _say ""
    _say "    ${C_BOLD}1.${C_RESET} open Terminal.app (or iTerm) — a new window picks up your PATH"
    _say "    ${C_BOLD}2.${C_RESET} run:  ${C_BOLD}agent-secrets setup${C_RESET}"
    _say ""
    _say "       (if the command isn't found yet, use the full path:"
    _say "        ${BIN_DIR}/agent-secrets setup)"
    _say ""
    _say "    ${C_BOLD}3.${C_RESET} then, for GitHub / Azure / API keys (brew-less recipes + the token ladder):"
    _say "        ${C_BOLD}agent-secrets help onboarding${C_RESET}"
    _say ""
    _say "Optional: this piped install skipped the opt-in prompt that adds machine-wide"
    _say "agent discovery to ~/.claude/CLAUDE.md — re-run the installer in that same"
    _say "terminal if you want it (safe: the install is idempotent)."
    _say ""
    _say "Then you're done. Undo everything anytime with:  agent-secrets uninstall"
    return 0
  fi
  _say "Installed. Launching the setup wizard…"
  _run "$BIN_DIR/agent-secrets" setup
}

# The concise golden-rules block appended (opt-in) to ~/.claude/CLAUDE.md. Names-only guidance so an
# agent in ANY repo knows to route secrets through agent-secrets rather than plaintext .env files.
_discovery_block() {
  cat <<'BLOCK'
## Secrets: use `agent-secrets` (never plaintext)
This machine has `agent-secrets` — encrypted (sops+age), names-only secret management for coding agents.
- NEVER write a secret to a `.env`, export it in plaintext, or print a secret VALUE into the transcript.
- Run any tool WITH secrets injected, process-scoped: `agent-secrets run -- <cmd>` (values die with the process).
- Add/update a secret, value via STDIN (never argv): `printf %s "$VALUE" | agent-secrets add NAME`.
- Names · health · full machine-readable manifest: `agent-secrets list` · `agent-secrets doctor` · `agent-secrets help --json`.
BLOCK
}

# Weekly smoke launchd plist (runs the tool's own smoke command; no value ever printed).
_install_smoke_plist() {
  local plist="$1" label="$2" install_dir="$3"
  if [ "${DRY_RUN:-0}" -eq 1 ]; then _step "write launchd plist: $plist"; return 0; fi
  cat >"$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${label}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${install_dir}/bin/agent-secrets</string>
    <string>smoke</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>${install_dir}/vendor/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>
  <key>StartCalendarInterval</key>
  <dict><key>Weekday</key><integer>1</integer><key>Hour</key><integer>9</integer></dict>
</dict>
</plist>
PLIST
  chmod 0644 "$plist"
}

main "$@"
