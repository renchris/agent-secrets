#!/usr/bin/env bash
# cmd/uninstall.sh — total removal via the install-manifest: tool files, PATH block, launchd
# bootout, settings.json apiKeyHelper revert, Keychain exact-service purge. A keep-vs-purge PROMPT
# governs the user's DATA (the sops store + age keys under the config dir) — that is NOT in the
# install-manifest. Zero residue is the goal.
set -euo pipefail
# shellcheck source=/dev/null
. "${AGENT_SECRETS_LIB:?run via bin/agent-secrets}/common.sh"
# help guard — MUST precede any side effect (never start the removal on --help)
case "${1:-}" in -h|--help) . "$AGENT_SECRETS_LIB/help.sh"; agsec_help_render uninstall; exit 0 ;; esac
# shellcheck source=/dev/null
. "$AGENT_SECRETS_LIB/manifest.sh"
# shellcheck source=/dev/null
. "$AGENT_SECRETS_LIB/store.sh"   # store_manifest_purge_sharing (keep-mode social-graph purge)

main() {
  local dry=0
  # Reject an unknown first arg — a mistyped `--dry-run` (e.g. `--dryrun`) must NOT silently fall
  # through to a real, destructive uninstall.
  case "${1:-}" in ''|--dry-run) : ;; *) agsec_die "uninstall: unknown argument: $1 (only --dry-run or --help)" 2 ;; esac
  [ "${1:-}" = "--dry-run" ] && dry=1

  # manifest_rollback drives EVERYTHING through jq (record parsing + rewrites). Without jq it would fail
  # silently mid-rollback yet still print "zero residue" — leaving artifacts behind. Fail LOUD instead.
  agsec_require jq

  local config_dir state_dir
  config_dir="$(agsec_config_dir)"     # store, manifest.toml, .sops.yaml, age.key fallback, age.pub
  state_dir="$(agsec_state_dir)"       # install-manifest.json, wizard-state, edit backups

  agsec_log "agent-secrets uninstall — reverses every recorded tool artifact."
  [ "$dry" -eq 1 ] && agsec_note "(dry-run: showing the plan, changing nothing)"

  # keep-vs-purge for the user's DATA (store + keys). Data-loss decision → a real STOP-ASK gate
  # with NO --force/env bypass. --dry-run defaults to KEEP (touches nothing).
  local purge=0
  if [ "$dry" -eq 1 ]; then
    agsec_note "(dry-run) would ASK: keep or purge the encrypted store + age keys under $config_dir"
    agsec_note "(dry-run) on a real run: answering 'y' → rm -rf $config_dir (store + age keys deleted); 'N'/Enter → keep them (share roster purged from manifest.toml)"
  elif [ ! -t 0 ]; then
    # No terminal to ask at: an OPEN-but-empty stdin (an agent session's inherited pipe never sends EOF)
    # would make `read` BLOCK FOREVER before manifest_rollback, hanging the whole uninstall. Fail closed
    # to KEEP without prompting — the tool-artifact rollback still runs; the destructive store purge
    # (data loss) is never taken without an explicit interactive 'y'.
    agsec_note "non-interactive (no terminal) — keeping the store + keys; run in a terminal to be asked about purging them"
  else
    printf 'Also delete your encrypted store + age keys under %s? [y = purge / N = keep]: ' "$config_dir" >&2
    # EOF-guard (matches setup.sh / share.sh / receive.sh): a bare `read` returns non-zero at stdin
    # EOF and, under `set -euo pipefail`, would abort BEFORE manifest_rollback — leaving TOTAL residue
    # (PATH block, launchd job, Keychain item, wrappers, settings.json edit). Fail closed to KEEP so the
    # tool-artifact rollback still runs; the destructive store purge stays gated behind an explicit `y`.
    local ans=''; read -r ans || ans=''
    case "$ans" in [yY]*) purge=1 ;; *) purge=0 ;; esac
  fi

  # Total tool-artifact rollback: files, edits (settings.json), launchd bootout, PATH block, and
  # Keychain item (by record AND by an exact-service scan of agent-age-key) — the age-key custody copy.
  if [ "$dry" -eq 1 ]; then manifest_rollback --dry-run; else manifest_rollback; fi

  # User DATA: honored by the prompt. KEEP leaves the 0600 age.key fallback so the store stays
  # decryptable after re-onboarding; PURGE removes the config dir entirely.
  if [ "$purge" -eq 1 ]; then
    agsec_log "purging store + keys: $config_dir"
    rm -rf "$config_dir"
  else
    if [ "$dry" -eq 1 ]; then
      agsec_note "(dry-run) would purge the colleague-share roster (shared_with/shared_at/direction) from the retained manifest.toml"
    else
      store_manifest_purge_sharing   # design §3.8 #6: keep-mode retains no who-shared-with-whom social graph
      agsec_log "kept store + keys: $config_dir (share roster purged; re-onboard restores from the fallback key)"
    fi
  fi

  # Tool STATE (install manifest is now empty; drop the dir + edit backups) — always residue.
  if [ "$dry" -eq 1 ]; then
    agsec_note "(dry-run) rm tool state dir: $state_dir"
    agsec_note "(dry-run) rmdir now-empty tool-created parent dirs (~/bin, ~/Library/LaunchAgents, ~/.local/state, ~/.local) if empty"
  else
    rm -rf "$state_dir"
    # Best-effort: remove tool-created parent dirs that are now EMPTY (rmdir is a no-op on a dir that
    # still holds the user's own files) — closes the "zero residue" gap for empty ~/bin etc. on a fresh
    # Mac. Order matters: children before parents. Purge also empties ~/.config/secrets' parent.
    local d
    for d in "$(agsec_bin_dir)" "$(agsec_home)/Library/LaunchAgents" "$state_dir" "$(agsec_home)/.local/state" "$(agsec_home)/.local"; do
      rmdir "$d" 2>/dev/null || true
    done
    [ "$purge" -eq 1 ] && { rmdir "$(agsec_home)/.config" 2>/dev/null || true; }
    agsec_ok "uninstall complete — every recorded artifact removed$([ "$purge" -eq 1 ] && printf '; store purged' || printf '; store kept')"
  fi
}

main "$@"
