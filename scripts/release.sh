#!/usr/bin/env bash
# scripts/release.sh — cut a release so the installer's integrity claim is REAL.
# Maintainer-only (export-ignored from the tarball). Run in a normal terminal — the tag move and
# `gh release` steps are yours to confirm; this script never force-pushes or uploads without a [y].
#
# The trust model it enforces (see install.sh's SHA-256 gate + SECURITY.md):
#   • The tarball is `git archive`d with a PINNED --prefix so install.sh's --strip-components=1 finds
#     exactly one top-level dir.
#   • `.gitattributes` EXPORT-IGNORES install.sh, so the tarball's bytes do NOT depend on install.sh —
#     which lets us BAKE the tarball's own sha256 into install.sh's EXPECTED_SHA256 with no circularity.
#   • install.sh ships via raw-git at the tag (a channel distinct from the release-asset tarball), so a
#     swapped tarball fails the baked-digest check. The sibling .sha256 is transport-integrity only.
set -euo pipefail

ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

TAG="${1:-v$(cat VERSION)}"
PKG="agent-secrets-${TAG}.tar.gz"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

_say() { printf '%s\n' "$*" >&2; }
_die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
_confirm() { local a; printf '%s [y/N]: ' "$1" >&2; read -r a || a=''; case "$a" in [yY]*) return 0 ;; *) return 1 ;; esac; }

command -v gh   >/dev/null 2>&1 || _die "gh not found (brew install gh) — needed for the release step"
command -v shasum >/dev/null 2>&1 || _die "shasum not found"
[ -z "$(git status --porcelain)" ] || _die "working tree is dirty — commit or stash first (a clean tree is the release input)"

# 1) Build the runtime tarball from HEAD with the pinned prefix (install.sh is export-ignored → absent).
_say "==> archiving ${TAG} → ${PKG}"
git archive --prefix="agent-secrets-${TAG}/" HEAD -o "$WORK/$PKG"
tar -tzf "$WORK/$PKG" | grep -q "^agent-secrets-${TAG}/lib/common.sh$" \
  || _die "archive layout check failed — expected agent-secrets-${TAG}/lib/common.sh"
if tar -tzf "$WORK/$PKG" | grep -q "^agent-secrets-${TAG}/install.sh$"; then
  _die "install.sh leaked into the tarball — check .gitattributes export-ignore (baking would be circular)"
fi

# 2) Compute the digest and BAKE it into install.sh (git-ref channel).
SHA="$(shasum -a 256 "$WORK/$PKG" | awk '{print $1}')"
_say "==> tarball sha256: $SHA"
CUR="$(sed -n 's/.*EXPECTED_SHA256="\([a-f0-9]*\)".*/\1/p' install.sh | head -1)"
if [ "$CUR" = "$SHA" ]; then
  _say "    install.sh already carries this digest — no bake needed"
else
  # Portable in-place edit (BSD + GNU sed): only the empty-or-old-hex literal is replaced.
  sed -i.bak 's/EXPECTED_SHA256="[a-f0-9]*"/EXPECTED_SHA256="'"$SHA"'"/' install.sh && rm -f install.sh.bak
  grep -q "EXPECTED_SHA256=\"$SHA\"" install.sh || _die "bake failed — EXPECTED_SHA256 not updated in install.sh"
  _say "    baked EXPECTED_SHA256 into install.sh"
  git add install.sh
  git commit -m "chore(release): bake ${TAG} tarball digest into install.sh" >&2
fi

# 3) Move the tag onto the (possibly new) HEAD so raw-git serves the baked install.sh at ${TAG}.
if _confirm "Move tag ${TAG} onto HEAD ($(git rev-parse --short HEAD))?"; then
  git tag -f "$TAG" >&2
  _say "    tag ${TAG} → $(git rev-parse --short HEAD)  (push with: git push -f origin ${TAG}; git push origin HEAD)"
else
  _say "    skipped tag move — do it yourself before publishing, or the baked install.sh won't be at ${TAG}"
fi

# 4) Write assets + publish (transport .sha256 is convenience; the baked digest is the real anchor).
cp "$WORK/$PKG" "./$PKG"
shasum -a 256 "$PKG" >"$PKG.sha256"
_say "==> wrote ./$PKG and ./$PKG.sha256"
_say ""
_say "Publish (immutable so assets cannot be swapped):"
_say "  git push -f origin ${TAG} && git push origin HEAD"
_say "  gh release create ${TAG} ${PKG} ${PKG}.sha256 --title ${TAG} --generate-notes"
if _confirm "Run the gh release now?"; then
  git push -f origin "$TAG" && git push origin HEAD
  gh release create "$TAG" "$PKG" "$PKG.sha256" --title "$TAG" --generate-notes
  _say "==> released ${TAG}"
else
  _say "    skipped — run the two commands above when ready."
fi
