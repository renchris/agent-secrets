# shellcheck shell=bash
# tests/install_helper.bash — shared setup for the install.sh suites. `load test_helper` first, then
# `load install_helper`: this file's teardown replaces test_helper's and also removes $MIRROR.

# The release file set, from the WORKING TREE: tracked + untracked-not-ignored paths minus every path
# that is `export-ignore` itself or sits under an `export-ignore` directory. One check-attr call.
_tree_files() {
  local files ign
  files="$(git ls-files -co --exclude-standard)"
  # The ignore set travels as ONE '|'-joined string: BSD awk rejects a newline inside a -v value.
  ign="$(printf '%s\n' "$files" \
        | awk -F/ '{ p=""; for (i = 1; i < NF; i++) { p = p $i "/"; print p }; print $0 }' | sort -u \
        | git check-attr --stdin export-ignore | awk -F': ' '$3 == "set" { print $1 }' | tr '\n' '|')"
  printf '%s\n' "$files" | awk -v ign="$ign" '
    BEGIN { n = split(ign, a, "|"); for (i = 1; i <= n; i++) if (a[i] != "") I[a[i]] = 1 }
    { keep = ($0 in I) ? 0 : 1; p = ""; nf = split($0, s, "/")
      for (i = 1; i < nf; i++) { p = p s[i] "/"; if (p in I) keep = 0 }
      if (keep) print }'
}

# Build a real runtime tarball into a mock "mirror" dir the curl mock serves (AGSEC_MOCK_DL_DIR).
# Exports: TAG, PKG (basename), MIRROR (dir). SHA of the built tarball → $BUILT_SHA.
_build_mirror() {
  # Derived from VERSION, never hardcoded: install.sh's PINNED_TAG tracks VERSION, so a pinned
  # literal here silently serves the wrong filename from the mock mirror the moment the version is
  # bumped — which is exactly how five install tests went red on the 0.1.1 -> 0.1.2 bump.
  TAG="v$(cat "$REPO_ROOT/VERSION")"; PKG="agent-secrets-${TAG}.tar.gz"
  MIRROR="$(mktemp -d "${TMPDIR:-/tmp}/agsec-mirror.XXXXXX")"
  # Archive the WORKING TREE, not HEAD. `git archive HEAD` meant every install test silently exercised
  # the PREVIOUS commit's setup.sh — a suite that goes green on code you have not committed yet is
  # measuring the wrong thing (and a new lib file was invisible until committed). Same file set the
  # release cuts: tracked + untracked-not-ignored, minus every `export-ignore` path in .gitattributes,
  # under the single prefix dir install.sh's layout guard requires.
  # A directory pattern (`tests/ export-ignore`) is matched by check-attr only against the DIRECTORY
  # path with its trailing slash, never against the files inside — so every ancestor dir is checked
  # in the same single call and a file under an ignored ancestor is dropped.
  ( cd "$REPO_ROOT" && _tree_files | tar -czf "$MIRROR/$PKG" -s "|^|agent-secrets-${TAG}/|" -T - )
  _mirror_digest
  export AGSEC_MOCK_DL_DIR="$MIRROR" TAG PKG MIRROR BUILT_SHA
}

_mirror_digest() {
  BUILT_SHA="$(shasum -a 256 "$MIRROR/$PKG" | awk '{print $1}')"
  printf '%s  %s\n' "$BUILT_SHA" "$PKG" >"$MIRROR/$PKG.sha256"
}

# Simulate the released install.sh: bake the mirror tarball's digest in (the release runbook's sed).
# Prints the baked file's path.
_bake_install() {
  local baked="$MIRROR/install.sh"
  sed "s/EXPECTED_SHA256=\"[a-f0-9]*\"/EXPECTED_SHA256=\"$BUILT_SHA\"/" "$REPO_ROOT/install.sh" >"$baked"
  printf '%s\n' "$baked"
}

# Swap the mirror tarball's dispatcher for a shim, so a full install ends by recording what it handed
# to `setup` instead of running it: argv to $AGSEC_SETUP_ARGV_LOG, and only the NAMES of its exported
# environment to $AGSEC_SETUP_ENV_LOG (never a value). Call after _build_mirror, before _bake_install.
_shim_setup_in_mirror() {
  local x="$MIRROR/shim"
  mkdir -p "$x"
  tar -xzf "$MIRROR/$PKG" -C "$x"
  # shellcheck disable=SC2016  # the shim's own variables, expanded when it runs
  printf '%s\n' '#!/usr/bin/env bash' \
    'printf "%s\n" "$@" >"$AGSEC_SETUP_ARGV_LOG"' \
    'compgen -e >"$AGSEC_SETUP_ENV_LOG"' >"$x/agent-secrets-${TAG}/bin/agent-secrets"
  chmod 0755 "$x/agent-secrets-${TAG}/bin/agent-secrets"
  ( cd "$x" && COPYFILE_DISABLE=1 tar -czf "$MIRROR/$PKG" "agent-secrets-${TAG}" )   # no ._ AppleDouble entries
  _mirror_digest
}

teardown() {
  [ -n "${MIRROR:-}" ] && [ -d "$MIRROR" ] && rm -rf "$MIRROR"
  [ -n "${AGENT_SECRETS_HOME:-}" ] && [ -d "$AGENT_SECRETS_HOME" ] && rm -rf "$AGENT_SECRETS_HOME"
}
