#!/usr/bin/env bash
# install.sh — one-command bootstrap (curl'd).
# FUNCTION-GUARDED (main(){…}; main "$@") so a truncated download can never partial-exec
# Consent gate is the FIRST screen; --dry-run = plan-then-apply (the rendered
# plan is exactly what executes). STOP-ASK gates have NO --force/env bypass.
# Install from a PINNED release tag (never main); SHA-256 verify any artifact before running it.
# AGENT_SECRETS_BASE_URL overrides the source (private-repo / corporate mirror; the smoke test
# uses it). Records every TOOL artifact via lib/manifest.sh; no secret value ever handled.
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
  local EXPECTED_SHA256="168e56b98cd2d8c7255a621eaec3551579617e6ab71432ff5df4d6c356691008"

  local HOME_DIR="${AGENT_SECRETS_HOME:-$HOME}"
  local INSTALL_DIR="$HOME_DIR/.agent-secrets"
  local BIN_DIR="$HOME_DIR/bin"
  local STATE_DIR="$HOME_DIR/.local/state/agent-secrets"
  local RC_FILE="$HOME_DIR/.zshenv"        # sourced by every zsh invocation incl. Cursor subshells
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
    _say "  • install Homebrew (if absent), then: age, sops, gum, jq"
    _say "  • install the tool under $INSTALL_DIR   (pinned $PINNED_TAG, SHA-256 verified)"
    _say "  • symlink the command + wrappers into $BIN_DIR   (agent-secrets, claude-agent, cursor-agent, apiKeyHelper)"
    _say "  • add a marker-delimited PATH block to $RC_FILE"
    _say "  • install a weekly launchd smoke job ($SMOKE_LABEL)"
    _say "  • back up an existing ~/.claude/settings.json (revert point for setup's apiKeyHelper edit)"
    _say "  • OFFER (opt-in) to add agent-secrets rules to ~/.claude/CLAUDE.md so agents in EVERY repo know to use it"
    _say "  • record every change to $STATE_DIR/install-manifest.json (one-command uninstall)"
    _say "  • run 'agent-secrets setup' (the interactive wizard) at the end"
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
  # No --force / env bypass: consent is mandatory.
  printf '[Enter] continue · [d] show the full dry-run first · Ctrl-C stop: ' >&2
  local reply; read -r reply
  if [ "$reply" = "d" ] || [ "$reply" = "D" ]; then
    DRY_RUN=1; _render_plan; DRY_RUN=0
    printf '[Enter] continue · Ctrl-C stop: ' >&2; read -r reply
  fi

  # --- toolchain ---------------------------------------------------------------
  if ! command -v brew >/dev/null 2>&1; then
    _say "Installing Homebrew…"
    # Homebrew's canonical HEAD bootstrap is the ecosystem-standard trust anchor; pinning ITS installer
    # to a commit is unsupported and rots. This is the ONE intentional moving-ref exception to the
    # "install from a pinned tag" rule above — trusted-upstream, NOT SHA-pinned by us (see SECURITY.md's
    # honest ceiling). The "never run an unverified artifact" rule covers the tool's OWN release only.
    _run /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  fi
  # jq is REQUIRED, not optional: lib/manifest.sh (the install/uninstall manifest backbone),
  # `help --json`, and `list --format=json` all call jq unguarded — omitting it aborts the install
  # mid-way under `set -euo pipefail`, leaving partial residue.
  _run brew install age sops gum jq

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
  _run mkdir -p "$INSTALL_DIR" "$BIN_DIR" "$STATE_DIR"
  _run tar -xzf "$pkg" -C "$INSTALL_DIR" --strip-components=1
  # Fail LOUDLY on a mis-cut tarball (wrong/missing top-level prefix flattens the layout and would
  # dangle every wrapper symlink) instead of a cryptic `set -e` abort on the first source below. The
  # release runbook pins `git archive --prefix=agent-secrets-${TAG}/` to guarantee the single prefix dir.
  [ "$DRY_RUN" -eq 1 ] || [ -f "$INSTALL_DIR/lib/common.sh" ] \
    || _die "unexpected tarball layout (need one top-level prefix dir) — re-cut with: git archive --prefix=agent-secrets-\${TAG}/ \${TAG}"

  # From here on the tool's own libs exist — source them to record artifacts.
  # shellcheck source=/dev/null
  . "$INSTALL_DIR/lib/common.sh"
  # shellcheck source=/dev/null
  . "$INSTALL_DIR/lib/manifest.sh"
  agsec_secure_umask
  manifest_init

  # Wire the bin dispatcher + wrappers as SYMLINKS onto PATH (they follow the link back to their
  # sibling lib/ under $INSTALL_DIR — a plain copy would strand them from lib/). Record each symlink
  # for rollback, and record $INSTALL_DIR itself so uninstall removes the unpacked tool (no residue).
  manifest_record_file "$INSTALL_DIR" >/dev/null 2>&1 || true
  local f
  _run ln -sf "$INSTALL_DIR/bin/agent-secrets" "$BIN_DIR/agent-secrets"
  manifest_record_file "$BIN_DIR/agent-secrets"
  for f in claude-agent cursor-agent apiKeyHelper; do
    [ -f "$INSTALL_DIR/bin/$f" ] || continue
    _run ln -sf "$INSTALL_DIR/bin/$f" "$BIN_DIR/$f"
    manifest_record_file "$BIN_DIR/$f"
  done

  # Idempotent, marker-delimited PATH block → shell rc (recorded for total rollback).
  manifest_pathblock_install "$RC_FILE" "$PATH_MARKER" "export PATH=\"$BIN_DIR:\$PATH\""

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

  _say ""
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
  <key>StartCalendarInterval</key>
  <dict><key>Weekday</key><integer>1</integer><key>Hour</key><integer>9</integer></dict>
</dict>
</plist>
PLIST
  chmod 0644 "$plist"
}

main "$@"
