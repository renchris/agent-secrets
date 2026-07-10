#!/usr/bin/env bash
# cmd/uninstall.sh — total removal via the install-manifest: tool files, PATH block, launchd
# bootout, settings.json apiKeyHelper revert, Keychain agent-* purge. A keep-vs-purge PROMPT
# governs the user's DATA (the sops store + age keys under the config dir) — that is NOT in the
# install-manifest. Zero residue is the goal.
set -euo pipefail
# shellcheck source=/dev/null
. "${AGENT_SECRETS_LIB:?run via bin/agent-secrets}/common.sh"
# help guard — MUST precede any side effect (never start the removal on --help)
case "${1:-}" in -h|--help) . "$AGENT_SECRETS_LIB/help.sh"; agsec_help_render uninstall; exit 0 ;; esac
# shellcheck source=/dev/null
. "$AGENT_SECRETS_LIB/manifest.sh"

main() {
  local dry=0
  [ "${1:-}" = "--dry-run" ] && dry=1

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
  else
    printf 'Also delete your encrypted store + age keys under %s? [y = purge / N = keep]: ' "$config_dir" >&2
    local ans; read -r ans
    case "$ans" in [yY]*) purge=1 ;; *) purge=0 ;; esac
  fi

  # Total tool-artifact rollback: files, edits (settings.json), launchd bootout, PATH block, and
  # Keychain items (by record AND by agent-* prefix scan) — the age-key custody copy included.
  if [ "$dry" -eq 1 ]; then manifest_rollback --dry-run; else manifest_rollback; fi

  # User DATA: honored by the prompt. KEEP leaves the 0600 age.key fallback so the store stays
  # decryptable after re-onboarding; PURGE removes the config dir entirely.
  if [ "$purge" -eq 1 ]; then
    agsec_log "purging store + keys: $config_dir"
    rm -rf "$config_dir"
  else
    [ "$dry" -eq 1 ] || agsec_log "kept store + keys: $config_dir (re-onboard restores from the fallback key)"
  fi

  # Tool STATE (install manifest is now empty; drop the dir + edit backups) — always residue.
  if [ "$dry" -eq 1 ]; then
    agsec_note "(dry-run) rm tool state dir: $state_dir"
  else
    rm -rf "$state_dir"
    agsec_ok "uninstall complete — zero tool residue$([ "$purge" -eq 1 ] && printf '; store purged' || printf '; store kept')"
  fi
}

main "$@"
