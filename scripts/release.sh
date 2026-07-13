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
# Nothing export-ignored may leak into the runtime tarball: install.sh (baking would be circular) and
# the maintainer-only scripts (telemetry-gate/record-demo/release). Assert each is absent.
for _leak in install.sh scripts/telemetry-gate.sh scripts/record-demo.sh scripts/release.sh; do
  if tar -tzf "$WORK/$PKG" | grep -q "^agent-secrets-${TAG}/${_leak}$"; then
    _die "$_leak leaked into the tarball — check .gitattributes export-ignore"
  fi
done

# 2) BAKE the digest into install.sh as a TAG-ONLY commit. main's install.sh stays EMPTY (the
# "empty on main / baked at the tag" invariant, install.sh:19-24): the baked install.sh lives only in
# the tagged commit that raw-git serves at ${TAG}. Done via a temp index — the branch is never advanced,
# the working tree is never dirtied.
SHA="$(shasum -a 256 "$WORK/$PKG" | awk '{print $1}')"
_say "==> tarball sha256: $SHA"
BAKED="$WORK/install.sh.baked"
sed 's/EXPECTED_SHA256="[a-f0-9]*"/EXPECTED_SHA256="'"$SHA"'"/' install.sh >"$BAKED"
grep -q "EXPECTED_SHA256=\"$SHA\"" "$BAKED" || _die "bake failed — EXPECTED_SHA256 not set in the staged install.sh"
BLOB="$(git hash-object -w "$BAKED")"
MODE="$(git ls-tree HEAD install.sh | awk '{print $1}')"; MODE="${MODE:-100644}"
COMMIT="$(
  GIT_INDEX_FILE="$WORK/index.tmp"; export GIT_INDEX_FILE
  git read-tree HEAD
  git update-index --cacheinfo "$MODE,$BLOB,install.sh"
  TREE="$(git write-tree)"
  printf 'chore(release): bake %s tarball digest into install.sh (tag-only)\n' "$TAG" | git commit-tree "$TREE" -p HEAD
)"
[ -n "$COMMIT" ] || _die "tag-only bake failed — could not create the baked commit"
_say "    baked ${SHA:0:12}… into tag-only commit ${COMMIT:0:9} (main install.sh stays empty)"

# 3) Point the tag at the baked commit so raw-git serves the baked install.sh at ${TAG} (main unchanged).
if _confirm "Move tag ${TAG} onto the baked commit ${COMMIT:0:9}?"; then
  git tag -f "$TAG" "$COMMIT" >&2
  _say "    tag ${TAG} → ${COMMIT:0:9}  (push with: git push -f origin ${TAG})"
else
  _say "    skipped tag move — do it yourself before publishing, or the baked install.sh won't be at ${TAG}"
fi

# 4) Write assets + publish. The baked digest (in the tagged install.sh, via the git-ref channel) is the
# real integrity anchor; the sibling .sha256 is transport convenience. A RE-CUT replaces the prior
# release (dropping its old assets) but keeps the freshly force-pushed tag; enable "immutable releases"
# in the repo settings to stop assets being swapped AFTER publish (gh has no create-time flag for it).
cp "$WORK/$PKG" "./$PKG"
shasum -a 256 "$PKG" >"$PKG.sha256"
_say "==> wrote ./$PKG and ./$PKG.sha256"
_say ""
_say "Publish:"
_say "  git push -f origin ${TAG}         # the baked, tag-only commit"
_say "  git push origin HEAD              # main (unchanged install.sh)"
_say "  gh release delete ${TAG} --yes    # re-cut only: drop the old release's assets (keeps the tag)"
_say "  gh release create ${TAG} ${PKG} ${PKG}.sha256 --title ${TAG} --generate-notes"
# The install.sh served via raw-git at ${TAG} MUST be the baked commit whose digest matches THIS tarball.
# If the tag isn't at the baked commit (tag move declined), publishing would strand a mismatched installer.
if [ "$(git rev-parse "$TAG" 2>/dev/null)" != "$COMMIT" ]; then
  _die "tag ${TAG} is not at the baked commit — the install.sh served at the tag would not match this tarball's baked digest. Re-run and confirm the tag move before publishing."
fi
if _confirm "Run the gh release now?"; then
  git push -f origin "$TAG" && git push origin HEAD
  gh release delete "$TAG" --yes >/dev/null 2>&1 || true   # re-cut: remove the old release, keep our new tag
  gh release create "$TAG" "$PKG" "$PKG.sha256" --title "$TAG" --generate-notes
  _say "==> released ${TAG} — now enable 'immutable releases' in repo settings if you have not."
else
  _say "    skipped — run the commands above when ready."
fi
