#!/usr/bin/env bats
# tests/deps.bats — no-sudo dependency resolver (lib/deps.sh): the sops version floor that fixes the
# feedback's silent-decrypt BLOCKER #4, Rosetta-proof arch, and the SHA-256 fail-closed download core.
# Synthetic-HOME + mocked curl (no network). Never touches the real toolchain or Keychain.
load test_helper

_source_deps() {
  export AGENT_SECRETS_LIB="$REPO_ROOT/lib"
  # shellcheck source=/dev/null
  . "$REPO_ROOT/lib/common.sh"; . "$REPO_ROOT/lib/deps.sh"
}

@test "deps_ver_ge: 3.10.0 is the SOPS_AGE_KEY_CMD floor (feedback BLOCKER #4)" {
  _source_deps
  _deps_ver_ge 3.13.2 3.10.0        # newer
  _deps_ver_ge 3.10.0 3.10.0        # equal
  _deps_ver_ge 3.10 3.10.0          # short == long.0
  _deps_ver_ge 4 3.10.0             # single field, higher major
  ! _deps_ver_ge 3.9.4 3.10.0       # the feedback's failing sops
  ! _deps_ver_ge 3.9.9 3.10.0
  ! _deps_ver_ge 2.99 3.10.0
}

@test "deps_arch returns a canonical arm64|amd64 (never the raw uname)" {
  _source_deps
  run deps_arch
  [ "$status" -eq 0 ]
  case "$output" in arm64|amd64) : ;; *) printf 'unexpected arch: %s\n' "$output"; false ;; esac
}

@test "download+verify is FAIL-CLOSED: a SHA-256 mismatch writes no file; a match places it" {
  _source_deps
  local mirror; mirror="$(mktemp -d "${TMPDIR:-/tmp}/agsec-depmirror.XXXXXX")"
  printf 'pretend-binary-bytes\n' >"$mirror/asset"
  export AGSEC_MOCK_DL_DIR="$mirror"          # the curl mock serves $mirror/<url-basename> into -o
  local dest="$AGENT_SECRETS_HOME/vend/asset"; mkdir -p "$(dirname "$dest")"
  # Wrong digest → refuse, nothing written (the supply-chain guarantee).
  run _deps_download_verify "https://x.example/asset" "0000000000000000000000000000000000000000000000000000000000000000" "$dest"
  [ "$status" -ne 0 ]
  [ ! -e "$dest" ]
  # Correct digest (of the fixture) → placed atomically.
  local good; good="$(shasum -a 256 "$mirror/asset" | awk '{print $1}')"
  run _deps_download_verify "https://x.example/asset" "$good" "$dest"
  [ "$status" -eq 0 ]
  [ -f "$dest" ]
  rm -rf "$mirror"
}

@test "deps_sops_ok gates on version: sops 3.9.4 fails, 3.13.2 passes" {
  local fake; fake="$(mktemp -d "${TMPDIR:-/tmp}/agsec-fakesops.XXXXXX")"
  printf '#!/bin/sh\necho "sops 3.9.4 (latest)"\n' >"$fake/sops"; chmod +x "$fake/sops"
  PATH="$fake:$PATH" run bash -c ". '$REPO_ROOT/lib/common.sh'; . '$REPO_ROOT/lib/deps.sh'; deps_sops_ok"
  [ "$status" -ne 0 ]
  printf '#!/bin/sh\necho "sops 3.13.2 (latest)"\n' >"$fake/sops"; chmod +x "$fake/sops"
  PATH="$fake:$PATH" run bash -c ". '$REPO_ROOT/lib/common.sh'; . '$REPO_ROOT/lib/deps.sh'; deps_sops_ok"
  [ "$status" -eq 0 ]
  rm -rf "$fake"
}

@test "deps_ensure reuses an already-present sops instead of vendoring it (no download)" {
  _source_deps
  # Real sops is on PATH (CI: brew install age sops). deps_ensure must resolve to it and leave the
  # vendor dir empty. A bogus deps base URL + NO_BREW guarantees no real egress even if a tool is absent.
  export AGENT_SECRETS_VENDOR_BIN="$AGENT_SECRETS_HOME/vendor/bin"
  export AGENT_SECRETS_DEPS_NO_BREW=1
  export AGENT_SECRETS_DEPS_BASE_URL="https://127.0.0.1"   # any fetch dies fast; required tools are on PATH
  if ! command -v sops >/dev/null 2>&1; then skip "sops not on PATH in this environment"; fi
  run deps_ensure
  [ "$status" -eq 0 ]
  [ ! -e "$AGENT_SECRETS_VENDOR_BIN/sops" ]                # present sops used, not re-downloaded
}
