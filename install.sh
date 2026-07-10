#!/usr/bin/env bash
# install.sh — one-command bootstrap (curl'd). 
# FUNCTION-GUARDED (main(){…}; main "$@") so a truncated download can never partial-exec
# Consent gate is the FIRST screen; --dry-run = plan-then-apply (the rendered
# plan is exactly what executes). STOP-ASK gates have NO --force/env bypass
# Install from a PINNED release tag (never main); SHA-256 verify any artifact before running it.
# AGENT_SECRETS_BASE_URL overrides the source (private-repo / corporate mirror;
# smoke uses it). Records every TOOL artifact via lib/manifest.sh; no secret value ever handled.
set -euo pipefail

main() {
  # --- pinned trust anchors ----------------------------------------------------
  # The tag is PINNED — never `main` (a moving ref is an unreviewed-code RCE). Repo-jacking guard:
  # if this project is ever renamed, the OLD GitHub name MUST be retained (a freed name can be
  # re-registered by an attacker and would serve this exact URL).
  local PINNED_TAG="v0.1.0"
  local REPO="renchris/agent-secrets"   # keep the old name reserved forever on any future rename
  local BASE_URL="${AGENT_SECRETS_BASE_URL:-https://github.com/${REPO}}"
  # EXPECTED_SHA256 is baked in at release-tag time; THIS curl'd script is the trust root, so the
  # digest lives here, not in a sibling file an attacker could swap. Empty ⇒ fall back to the
  # published .sha256 (dev/mirror convenience only).
  local EXPECTED_SHA256=""

  local HOME_DIR="${AGENT_SECRETS_HOME:-$HOME}"
  local INSTALL_DIR="$HOME_DIR/.agent-secrets"
  local BIN_DIR="$HOME_DIR/bin"
  local STATE_DIR="$HOME_DIR/.local/state/agent-secrets"
  local RC_FILE="$HOME_DIR/.zshenv"        # sourced by every zsh invocation incl. Cursor subshells
  local PATH_MARKER="agent-secrets"
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
    _say "  • install Homebrew (if absent), then: age, sops, gum"
    _say "  • install the tool under $INSTALL_DIR   (pinned $PINNED_TAG, SHA-256 verified)"
    _say "  • install wrappers into $BIN_DIR   (claude-agent, cursor-agent, apiKeyHelper)"
    _say "  • add a marker-delimited PATH block to $RC_FILE"
    _say "  • install a weekly launchd smoke job ($SMOKE_LABEL)"
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
  # No --force / env bypass: consent is mandatory
  printf '[Enter] continue · [d] show the full dry-run first · Ctrl-C stop: ' >&2
  local reply; read -r reply
  if [ "$reply" = "d" ] || [ "$reply" = "D" ]; then
    DRY_RUN=1; _render_plan; DRY_RUN=0
    printf '[Enter] continue · Ctrl-C stop: ' >&2; read -r reply
  fi

  # --- toolchain ---------------------------------------------------------------
  if ! command -v brew >/dev/null 2>&1; then
    _say "Installing Homebrew…"
    _run /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  fi
  _run brew install age sops gum

  # --- download + SHA-256 verify (never execute an unverified artifact) --------
  local work; work="$(mktemp -d)"
  local pkg="$work/agent-secrets-${PINNED_TAG}.tar.gz"
  local url="$BASE_URL/releases/download/${PINNED_TAG}/agent-secrets-${PINNED_TAG}.tar.gz"
  _say "Downloading ${PINNED_TAG}…"
  _run curl -fsSL "$url" -o "$pkg"
  local got expect
  got="$(shasum -a 256 "$pkg" | awk '{print $1}')"
  if [ -n "$EXPECTED_SHA256" ]; then
    expect="$EXPECTED_SHA256"
  else
    _run curl -fsSL "$url.sha256" -o "$pkg.sha256"
    expect="$(awk '{print $1}' "$pkg.sha256")"
  fi
  [ "$got" = "$expect" ] || _die "SHA-256 mismatch — refusing to run the downloaded artifact"
  _say "SHA-256 verified."

  # --- unpack the tool ---------------------------------------------------------
  _run mkdir -p "$INSTALL_DIR" "$BIN_DIR" "$STATE_DIR"
  _run tar -xzf "$pkg" -C "$INSTALL_DIR" --strip-components=1

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

  # Record a REVERT point for the ~/.claude/settings.json apiKeyHelper edit that `setup` applies.
  # We own the record + rollback, not the write (the wizard/injection step performs the edit).
  local settings="$HOME_DIR/.claude/settings.json"
  if [ -f "$settings" ]; then
    local backup="$STATE_DIR/settings.json.pre-install.bak"
    _run cp "$settings" "$backup"
    manifest_record_edit "$settings" "$backup" "apiKeyHelper"
  fi

  _say ""
  _say "Installed. Launching the setup wizard…"
  _run "$BIN_DIR/agent-secrets" setup
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
