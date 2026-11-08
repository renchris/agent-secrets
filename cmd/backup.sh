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
    -*)        agsec_unknown_option backup "$1" ;;
    *)         agsec_unexpected_argument backup ;;
  esac
  shift
done
agsec_parse_only_exit

# backup's prerequisite chain is gh → gh auth login → backup. A bare agsec_require gh points at doctor;
# name the actual next step and where the brew-less install recipe lives (P1-5) so the user isn't stuck.
agsec_have gh || agsec_die "backup needs the GitHub CLI (gh), which isn't installed. Install it (brew-less recipe): agent-secrets help onboarding — then run 'gh auth login', then re-run: agent-secrets backup"
agsec_require_devtool git

# Drop OUR OWN egress loopback proxy BEFORE the first gh network call (gh auth status hits GitHub —
# through our allowlist proxy it would be refused unless github.com is allowlisted, killing backup with
# a misleading "not authenticated"). A wrapping claude-agent/run stamps AGENT_SECRETS_EGRESS_PROXY with
# the exact URL it set; backup is a trusted ciphertext-only push, not agent egress, so drop EXACTLY that
# proxy — but KEEP any corporate proxy, INCLUDING a loopback forwarder (Cntlm/px/ZTNA) we did not set.
if [ -n "${AGENT_SECRETS_EGRESS_PROXY:-}" ] && [ "${HTTPS_PROXY:-}" = "$AGENT_SECRETS_EGRESS_PROXY" ]; then
  unset HTTPS_PROXY HTTP_PROXY ALL_PROXY https_proxy http_proxy all_proxy AGENT_SECRETS_EGRESS_PROXY
fi

# Every gh call gets a 60 s wall-clock bound (stock macOS has no timeout(1)). The alarm survives the
# exec, so a hung gh dies by SIGALRM and the caller sees 142.
_gh_bin="$(command -v gh)"
gh() { /usr/bin/perl -e 'alarm shift; exec { $ARGV[0] } @ARGV; exit 127' 60 "$_gh_bin" "$@"; }

gh auth status >/dev/null 2>&1 || agsec_die "gh is not authenticated — run: gh auth login"

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

errf=""; stage=""
trap 'rm -f "$errf"; [ -z "$stage" ] || rm -rf "$stage"' EXIT
errf="$(mktemp)"

# Ensure the PRIVATE repo exists (creating one is a side effect → confirm unless --yes/UNATTENDED).
# One query, and only GitHub's own "not found" may lead to a create: a network or auth failure must not
# look like a missing repo, and an unreadable isPrivate must not look like a private one.
view_rc=0
is_private="$(gh repo view "$REPO" --json isPrivate -q .isPrivate 2>"$errf")" || view_rc=$?
if [ "$view_rc" -eq 0 ]; then
  case "$is_private" in
    true)  : ;;
    # The ciphertext is safe, but the store's secret-NAME inventory and your age recipients are not for
    # the public — refuse to push into a public repo.
    false) agsec_die "$REPO is PUBLIC — refusing to back up there (the encrypted store's secret-name inventory must stay private). Make it private, or choose another repo with --repo." ;;
    *)     agsec_fail error "Couldn't confirm $REPO is private (gh returned '$is_private')." "gh repo view $REPO" "Check" ;;
  esac
elif grep -q 'Could not resolve to a Repository' "$errf" 2>/dev/null; then
  if [ -z "$ASSUME_YES" ] && agsec_noninteractive; then
    agsec_need_confirmation "create $REPO" --yes "agent-secrets backup --repo $REPO --yes"
  fi
  if [ -z "$ASSUME_YES" ]; then
    ui_confirm "Create PRIVATE GitHub repo $REPO for your encrypted-store backup?" y \
      || agsec_canceled "backup cancelled — nothing was created (pass --yes to skip this prompt)"
  fi
  gh repo create "$REPO" --private >/dev/null 2>&1 || agsec_die "could not create $REPO (check gh permissions)"
  agsec_receipt "created private repo $REPO"
else
  why="$(head -n 1 "$errf" 2>/dev/null || true)"
  [ "$view_rc" -ne 142 ] || why="gh timed out after 60 s"
  agsec_fail network "Couldn't look up $REPO: ${why:-gh exited $view_rc}." "gh auth status" "Check your network and auth, then re-run"
fi

# A stalled transfer (under 1 KB/s for 60 s) aborts instead of hanging; covers the clone's git and the push.
export GIT_HTTP_LOW_SPEED_LIMIT=1000 GIT_HTTP_LOW_SPEED_TIME=60

# Stage CIPHERTEXT ONLY into a fresh clone (gh clone handles auth + the remote URL).
stage="$(mktemp -d)"
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
  agsec_receipt "backup already up to date ($REPO)"
else
  git -C "$stage" -c user.email="agent-secrets@localhost" -c user.name="agent-secrets" \
    commit -q -m "backup $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  git -C "$stage" push -q -u origin "HEAD:$branch" 2>/dev/null || agsec_die "push to $REPO failed (check gh auth + repo access)"
  agsec_receipt "encrypted store backed up to $REPO (ciphertext only)"
fi

# Record the target so doctor can report the off-machine second copy.
printf '%s\n' "$REPO" | agsec_atomic_write "$marker" || agsec_die "could not record the backup target in $marker"
printf '%s\n' "$REPO"
