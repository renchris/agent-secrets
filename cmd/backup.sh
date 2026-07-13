#!/usr/bin/env bash
# cmd/backup.sh — push the ENCRYPTED store (ciphertext only) to a private GitHub repo via gh, so a
# lost or dead Mac stays recoverable. This off-machine copy + your password-manager-saved age key =
# a full restore (setup --restore). Names-only AND private-key-safe: only the sops-encrypted
# secrets.env plus PUBLIC metadata ever leave; the age PRIVATE key is never staged, and a hard guard
# refuses the push if any AGE-SECRET-KEY material is detected in the staging area.
set -euo pipefail
. "${AGENT_SECRETS_LIB:?run via bin/agent-secrets}/common.sh"
case "${1:-}" in -h|--help) . "$AGENT_SECRETS_LIB/help.sh"; agsec_help_render backup; exit 0 ;; esac
. "$AGENT_SECRETS_LIB/ui.sh"

REPO=""
ASSUME_YES="${AGENT_SECRETS_UNATTENDED:+1}"   # automation implies "yes" to the create-repo confirm
while [ "${1:-}" != "" ]; do
  case "$1" in
    --repo)    shift; REPO="${1:-}"; [ -n "$REPO" ] || agsec_die "--repo needs an owner/name argument" 2 ;;
    --repo=*)  REPO="${1#--repo=}" ;;
    --yes|-y)  ASSUME_YES=1 ;;
    *)         agsec_die "backup: unknown argument: $1 (see --help)" 2 ;;
  esac
  shift
done

agsec_require gh
agsec_require git
gh auth status >/dev/null 2>&1 || agsec_die "gh is not authenticated — run: gh auth login"

# If we inherited OUR OWN egress loopback proxy (from a wrapping claude-agent/run), it must NOT bound
# backup's gh/git push — backup is a trusted, ciphertext-only push, not agent egress. Drop a 127.0.0.1
# proxy so the push reaches GitHub; KEEP a corporate (non-loopback) proxy so backup still honors it.
case "${HTTPS_PROXY:-}" in *127.0.0.1*|*localhost*) unset HTTPS_PROXY HTTP_PROXY ALL_PROXY https_proxy http_proxy all_proxy ;; esac

cfg="$(agsec_config_dir)"
[ -f "$(agsec_store_file)" ] || agsec_die "no store to back up — run: agent-secrets setup"
marker="$cfg/backup-repo"

# Resolve the target repo: --repo > saved marker > env > derive <your-login>/agent-secrets-store.
[ -z "$REPO" ] && [ -f "$marker" ] && REPO="$(cat "$marker")"
[ -z "$REPO" ] && [ -n "${AGENT_SECRETS_BACKUP_REPO:-}" ] && REPO="$AGENT_SECRETS_BACKUP_REPO"
if [ -z "$REPO" ]; then
  login="$(gh api user -q .login 2>/dev/null || true)"
  [ -n "$login" ] || agsec_die "could not determine your GitHub login — pass --repo owner/name"
  REPO="$login/agent-secrets-store"
fi
case "$REPO" in */*) : ;; *) agsec_die "--repo must be owner/name (got: $REPO)" 2 ;; esac

# Ensure the PRIVATE repo exists (creating one is a side effect → confirm unless --yes/UNATTENDED).
if gh repo view "$REPO" >/dev/null 2>&1; then
  # Exists already → it MUST be private. The ciphertext is safe, but the store's secret-NAME inventory
  # and your age recipients are not for the public — refuse to push into a public repo.
  if [ "$(gh repo view "$REPO" --json isPrivate -q .isPrivate 2>/dev/null)" = "false" ]; then
    agsec_die "$REPO is PUBLIC — refusing to back up there (the encrypted store's secret-name inventory must stay private). Make it private, or choose another repo with --repo."
  fi
else
  if [ -z "$ASSUME_YES" ]; then
    ui_confirm "Create PRIVATE GitHub repo $REPO for your encrypted-store backup?" y || agsec_die "backup cancelled"
  fi
  gh repo create "$REPO" --private >/dev/null 2>&1 || agsec_die "could not create $REPO (check gh permissions)"
  agsec_ok "created private repo $REPO"
fi

# Stage CIPHERTEXT ONLY into a fresh clone (gh clone handles auth + the remote URL).
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
gh repo clone "$REPO" "$stage" >/dev/null 2>&1 || agsec_die "could not clone $REPO"
# Use the repo's ACTUAL default branch (empty repo → the clone's unborn branch, usually main). Forcing
# `main` onto a repo whose default is `master` made every subsequent backup a non-fast-forward reject.
branch="$(git -C "$stage" symbolic-ref --short HEAD 2>/dev/null || echo main)"

# The encrypted store + PUBLIC metadata needed to use it. NEVER age.key / recovery.key (private keys).
copied=0
for f in secrets.env .sops.yaml manifest.toml age.pub recovery.pub; do
  [ -f "$cfg/$f" ] || continue
  cp "$cfg/$f" "$stage/$f"; copied=1
done
[ "$copied" = 1 ] || agsec_die "nothing to back up (no store files under $cfg)"

# Strip the colleague-share SOCIAL GRAPH (shared_with/shared_at/direction + received: sources) from the
# PUSHED manifest — pushing it would publish who-shared-with-whom to GitHub. Mirrors uninstall keep-mode.
if [ -f "$stage/manifest.toml" ]; then
  if grep -vE '^(shared_with|shared_at|direction) = |^source = "received:' "$stage/manifest.toml" >"$stage/manifest.toml.tmp" 2>/dev/null; then
    mv "$stage/manifest.toml.tmp" "$stage/manifest.toml"
  else
    rm -f "$stage/manifest.toml.tmp"   # grep printed nothing (empty/all-sharing manifest) — keep the copy as-is
  fi
fi

# Hard invariants before anything leaves the Mac (defense in depth):
#  (1) NO private-key material (the file list already excludes age.key; this catches a future mistake).
if grep -rql "AGE-SECRET-KEY-1" "$stage" 2>/dev/null; then
  agsec_die "refusing to push — private age key material detected in staging (backup is ciphertext-only)"
fi
#  (2) secrets.env must actually be sops CIPHERTEXT (an unencrypted store would leak values verbatim).
if [ -f "$stage/secrets.env" ] && ! grep -q 'ENC\[' "$stage/secrets.env" 2>/dev/null; then
  agsec_die "refusing to push — secrets.env is not sops ciphertext (no ENC[...] found); aborting to avoid pushing plaintext"
fi

# A README in the backup repo (written once) so a future you knows what this is and how to restore.
if [ ! -f "$stage/README.md" ]; then
  { printf '# agent-secrets encrypted-store backup\n\n'
    printf 'Ciphertext only, sops+age encrypted. USELESS without your age PRIVATE key (saved in your\n'
    printf 'password manager, NEVER stored here). Restore: copy secrets.env into ~/.config/secrets/,\n'
    printf 'then run:  agent-secrets setup --restore  and paste your saved key.\n'; } >"$stage/README.md"
fi

git -C "$stage" add -A
if git -C "$stage" diff --cached --quiet 2>/dev/null; then
  agsec_ok "backup already up to date ($REPO)"
else
  git -C "$stage" -c user.email="agent-secrets@localhost" -c user.name="agent-secrets" \
    commit -q -m "backup $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  git -C "$stage" push -q -u origin "HEAD:$branch" 2>/dev/null || agsec_die "push to $REPO failed (check gh auth + repo access)"
  agsec_ok "encrypted store backed up to $REPO (ciphertext only)"
fi

printf '%s\n' "$REPO" >"$marker"   # record the target so doctor can report the off-machine second copy
