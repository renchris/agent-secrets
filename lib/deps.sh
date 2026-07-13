# shellcheck shell=bash
# lib/deps.sh — no-sudo dependency resolver for age / sops / gum / jq.
# Sourced by install.sh AFTER lib/common.sh. Names-only (never handles a secret value).
#
# WHY this exists: the original installer required Homebrew, whose bootstrap needs an interactive
# `sudo` password — the #1 blocker on a fresh/brew-less corporate Mac (ONE_COMMAND_INSTALL_FEEDBACK.md).
# age/sops/gum/jq are each a single static binary, so we resolve each WITHOUT sudo, in this order:
#   1. already on PATH and version-adequate  → use it (fastest; respects a managed toolchain)
#   2. Homebrew present (no install of brew itself) → `brew install <tool>` (still no sudo)
#   3. else → download a PINNED, SHA-256-verified static binary into <install>/vendor/bin
# The pinned digests below were computed by downloading each official GitHub release asset and
# `shasum -a 256`-ing it (verified 2026-07-13 on macOS 15.6.1 arm64). Bumping a dep = re-pin here.
#
# Corporate-hardening baked in (from the install red-team):
#   • curl -fL  — follow the github.com → objects.githubusercontent.com 302 (bare curl saves the
#                 redirect HTML as a "binary"); the SHA-256 gate then also catches a DLP-tampered body.
#   • arch via `sysctl hw.optional.arm64` — `uname -m` reports x86_64 under a Rosetta-translated shell.
#   • ad-hoc codesign only if a binary won't exec — a truly-unsigned arm64 Mach-O is SIGKILLed by AMFI;
#     Go binaries (age/sops/jq here) are already linker-ad-hoc-signed, so this is a rarely-taken safety net.
#   • curl sets NO com.apple.quarantine xattr, so Gatekeeper never gates these — no "unidentified
#     developer" wall (that is exactly why rustup/deno/bun curl-installers work). We still strip it,
#     belt-and-suspenders, for the mirror/Finder-download path.
# The one blocker with no userland fix is a binary-allowlisting agent (Santa/EDR) in lockdown mode —
# which blocks Homebrew bottles too; deps_ensure fails LOUD with the exact host to allowlist.

# --- minimum versions -----------------------------------------------------------
# sops added SOPS_AGE_KEY_CMD (the env var this tool decrypts through) in v3.10.0 (2025-03-30). An
# older sops silently ignores it and the store won't decrypt via the Keychain selector — the feedback's
# BLOCKER #4. A PATH sops below this is treated as "not adequate" and we vendor 3.13.2 instead.
DEPS_SOPS_MIN="3.10.0"

# --- pinned release coordinates (bump = re-pin the sibling SHA) ------------------
DEPS_AGE_VER="v1.3.1"
DEPS_SOPS_VER="v3.13.2"
DEPS_GUM_VER="v0.17.0"
DEPS_JQ_VER="jq-1.8.2"

# Source host — overridable for an internal mirror / air-gapped install (mirror the release assets
# under the same <org>/<repo>/releases/download/<tag>/ layout). Distinct from AGENT_SECRETS_BASE_URL
# (which points at the agent-secrets tarball mirror) so the two can live on different hosts.
_deps_base() { printf '%s\n' "${AGENT_SECRETS_DEPS_BASE_URL:-https://github.com}"; }

# Where vendored binaries land. install.sh sets AGENT_SECRETS_VENDOR_BIN=<install>/vendor/bin; at
# runtime common.sh derives the same path and prepends it to PATH.
_deps_vendor_bin() {
  if [ -n "${AGENT_SECRETS_VENDOR_BIN:-}" ]; then printf '%s\n' "$AGENT_SECRETS_VENDOR_BIN"; return; fi
  local root; root="$(cd -P "$(dirname "${BASH_SOURCE[0]:-$0}")/.." >/dev/null 2>&1 && pwd)"
  printf '%s\n' "${root:-$PWD}/vendor/bin"
}

# --- arch (Rosetta-proof) -------------------------------------------------------
# Canonical: arm64 | amd64. Per-tool asset tokens differ (gum spells Intel "x86_64") — mapped in fetchers.
deps_arch() {
  if [ "$(sysctl -n hw.optional.arm64 2>/dev/null || echo 0)" = 1 ]; then printf 'arm64\n'; return; fi
  case "$(uname -m 2>/dev/null)" in arm64|aarch64) printf 'arm64\n' ;; *) printf 'amd64\n' ;; esac
}

# --- version compare: `_deps_ver_ge A B` → 0 iff A >= B (dotted numeric) ---------
# Pure parameter-expansion (no arrays / no IFS games) so it behaves identically under bash 3.2, a newer
# bash, and zsh. Compares field-by-field left to right; a non-numeric or missing field counts as 0.
_deps_ver_ge() {
  local a="$1" b="$2" x y
  while [ -n "$a" ] || [ -n "$b" ]; do
    x="${a%%.*}"; y="${b%%.*}"                                   # leading field of each
    case "$a" in *.*) a="${a#*.}" ;; *) a="" ;; esac            # advance past it (or exhaust)
    case "$b" in *.*) b="${b#*.}" ;; *) b="" ;; esac
    case "$x" in ''|*[!0-9]*) x=0 ;; esac
    case "$y" in ''|*[!0-9]*) y=0 ;; esac
    if [ "$x" -gt "$y" ]; then return 0; fi
    if [ "$x" -lt "$y" ]; then return 1; fi
  done
  return 0   # all fields equal
}

# --- adequacy per tool (presence, + version where it matters) -------------------
deps_sops_ok() {
  agsec_have sops || return 1
  local v; v="$(sops --version 2>/dev/null | head -1 | awk '{print $2}')"
  [ -n "$v" ] || return 1
  _deps_ver_ge "$v" "$DEPS_SOPS_MIN"
}
_deps_ok() {
  case "$1" in
    age)  agsec_have age && agsec_have age-keygen ;;
    sops) deps_sops_ok ;;
    jq)   agsec_have jq ;;
    gum)  agsec_have gum ;;
    *)    return 1 ;;
  esac
}

# --- download + verify primitive (the security-critical, unit-tested core) ------
_deps_curl() { curl -fLsS --proto '=https' --tlsv1.2 "$@"; }   # -L: follow the release 302 to the CDN

# _deps_download_verify URL EXPECTED_SHA256 DEST — fetch to a temp, verify, then atomically move to
# DEST. FAILS CLOSED: on download failure OR any SHA mismatch, DEST is NOT written and we return 1.
_deps_download_verify() {
  local url="$1" want="$2" dest="$3" tmp got
  tmp="$(mktemp "${dest}.dl.XXXXXX")" || return 1
  if ! _deps_curl "$url" -o "$tmp"; then rm -f "$tmp"; return 1; fi
  got="$(shasum -a 256 "$tmp" 2>/dev/null | awk '{print $1}')"
  if [ "$got" != "$want" ]; then
    rm -f "$tmp"; agsec_warn "dependency SHA-256 mismatch — refusing ${url##*/} (got ${got:-none})"; return 1
  fi
  mv -f "$tmp" "$dest"
}

# Make a placed binary runnable, without sudo: exec bit, drop any quarantine (no-op for curl; belt for
# a mirror/Finder download), and ad-hoc self-sign ONLY if it won't already execute (rare — all current
# assets are linker-ad-hoc-signed). Verifies-by-execution, which also catches a wrong-arch download.
_deps_finalize() {
  local dest="$1"
  chmod +x "$dest" 2>/dev/null || true
  xattr -d com.apple.quarantine "$dest" 2>/dev/null || true
  if ! "$dest" --version >/dev/null 2>&1; then
    codesign -s - --force "$dest" >/dev/null 2>&1 || true
    "$dest" --version >/dev/null 2>&1
  fi
}

# --- per-tool fetchers (pinned SHA-256 inline; each returns 0 on a verified install) --------------
deps_fetch_age() {   # tar.gz → binaries at age/age and age/age-keygen
  local arch sha url vbin tmp; arch="$(deps_arch)"; vbin="$(_deps_vendor_bin)"; mkdir -p "$vbin"
  case "$arch" in
    arm64) sha="01120ea2cbf0463d4c6bd767f99f3271bbed1cdc8a9aa718a76ba1fe4f01998b" ;;
    *)     sha="2b233301ad21ab7b1eabd9ae1198a164005fa4928fcdd745d47c39f8593209d7" ;;
  esac
  url="$(_deps_base)/FiloSottile/age/releases/download/${DEPS_AGE_VER}/age-${DEPS_AGE_VER}-darwin-${arch}.tar.gz"
  tmp="$(mktemp -d)" || return 1
  _deps_download_verify "$url" "$sha" "$tmp/age.tgz" || { rm -rf "$tmp"; return 1; }
  tar -xzf "$tmp/age.tgz" -C "$tmp" age/age age/age-keygen 2>/dev/null \
    || tar -xzf "$tmp/age.tgz" -C "$tmp" 2>/dev/null || { rm -rf "$tmp"; return 1; }
  if ! cp "$tmp/age/age" "$vbin/age" || ! cp "$tmp/age/age-keygen" "$vbin/age-keygen"; then
    rm -rf "$tmp"; return 1
  fi
  rm -rf "$tmp"; _deps_finalize "$vbin/age"; _deps_finalize "$vbin/age-keygen"
}

deps_fetch_sops() {   # raw binary
  local arch sha url vbin; arch="$(deps_arch)"; vbin="$(_deps_vendor_bin)"; mkdir -p "$vbin"
  case "$arch" in
    arm64) sha="412c475b52f167f1facd75d564422ffd1fa5302aaa7a404bdf4e30087e04b5a8" ;;
    *)     sha="5a66836229ff4a73779b19644b6db28fd574a6b995c15fc333469b2f93ee2acd" ;;
  esac
  url="$(_deps_base)/getsops/sops/releases/download/${DEPS_SOPS_VER}/sops-${DEPS_SOPS_VER}.darwin.${arch}"
  _deps_download_verify "$url" "$sha" "$vbin/sops" || return 1
  _deps_finalize "$vbin/sops"
}

deps_fetch_jq() {   # raw binary (arch token amd64, like age/sops)
  local arch sha url vbin; arch="$(deps_arch)"; vbin="$(_deps_vendor_bin)"; mkdir -p "$vbin"
  case "$arch" in
    arm64) sha="2d75340ba57a4b4b4c8708a21c2dc8e958a48aaa8bba13b27f77f6e4c0eca07e" ;;
    *)     sha="e94b266e3c26690550006abe63152b782280f4e14374accdf04cbde844f00bc0" ;;
  esac
  url="$(_deps_base)/jqlang/jq/releases/download/${DEPS_JQ_VER}/jq-macos-${arch}"
  _deps_download_verify "$url" "$sha" "$vbin/jq" || return 1
  _deps_finalize "$vbin/jq"
}

deps_fetch_gum() {   # tar.gz → binary at gum_<ver>_Darwin_<token>/gum (Intel token is x86_64)
  local arch tok sha ver url vbin tmp; arch="$(deps_arch)"; vbin="$(_deps_vendor_bin)"; mkdir -p "$vbin"
  ver="${DEPS_GUM_VER#v}"                       # gum asset names drop the leading v (0.17.0)
  case "$arch" in
    arm64) tok="arm64"; sha="e2a4b8596efa05821d8c58d0c1afbcd7ad1699ba69c689cc3ff23a4a99c8b237" ;;
    *)     tok="x86_64"; sha="cd66576aeebe6cd19c771863c7e8d696e0e1d5387d1e7075666baa67c2052e53" ;;
  esac
  url="$(_deps_base)/charmbracelet/gum/releases/download/${DEPS_GUM_VER}/gum_${ver}_Darwin_${tok}.tar.gz"
  tmp="$(mktemp -d)" || return 1
  _deps_download_verify "$url" "$sha" "$tmp/gum.tgz" || { rm -rf "$tmp"; return 1; }
  tar -xzf "$tmp/gum.tgz" -C "$tmp" 2>/dev/null || { rm -rf "$tmp"; return 1; }
  cp "$tmp/gum_${ver}_Darwin_${tok}/gum" "$vbin/gum" || { rm -rf "$tmp"; return 1; }
  rm -rf "$tmp"; _deps_finalize "$vbin/gum"
}

# --- orchestration --------------------------------------------------------------
# _deps_resolve TOOL required|optional FETCH_FN — PATH → brew → pinned download; die (required) or
# warn (optional) if all three miss. gum is optional (ui.sh has a plain fallback; secret input always
# uses builtin read -s). Homebrew is skipped when AGENT_SECRETS_DEPS_NO_BREW is set (force the pinned path).
_deps_resolve() {
  local tool="$1" need="$2" fetch="$3"
  if _deps_ok "$tool"; then agsec_note "  $tool: using $(command -v "$tool")"; return 0; fi
  if agsec_have brew && [ -z "${AGENT_SECRETS_DEPS_NO_BREW:-}" ]; then
    agsec_note "  $tool: brew install…"
    brew install "$tool" >/dev/null 2>&1 || true
    hash -r 2>/dev/null || true
    _deps_ok "$tool" && { agsec_note "  $tool: installed via Homebrew"; return 0; }
  fi
  agsec_note "  $tool: fetching pinned, SHA-256-verified binary (no sudo)…"
  if "$fetch" && _deps_ok "$tool"; then agsec_ok "$tool ready (vendored)"; return 0; fi
  if [ "$need" = optional ]; then
    agsec_warn "$tool is optional and could not be installed — continuing (plain-text UI fallback)"
    return 0
  fi
  agsec_die "could not install required dependency: $tool.
  The pinned download from $(_deps_base) may be blocked. On a corporate Mac the usual causes:
    • egress allows github.com but NOT objects.githubusercontent.com (the release-asset CDN) —
      ask IT to allow *.githubusercontent.com, or set a proxy: export HTTPS_PROXY=…
    • a binary-allowlisting agent (Santa / EDR) in lockdown mode blocks un-notarized binaries
      (note: this blocks Homebrew bottles too — brew is not a workaround here)
    • air-gapped: mirror the release assets and set AGENT_SECRETS_DEPS_BASE_URL=<mirror>
  Or install $tool yourself$([ "$tool" = sops ] && printf ' (>= %s)' "$DEPS_SOPS_MIN") onto PATH, then re-run."
}

# deps_ensure — resolve the whole toolchain. Prepends vendor/bin so anything fetched here is visible
# to the rest of the install (and matches the runtime PATH common.sh sets for the wrappers).
deps_ensure() {
  local vbin; vbin="$(_deps_vendor_bin)"
  case ":$PATH:" in *":$vbin:"*) : ;; *) PATH="$vbin:$PATH"; export PATH ;; esac
  agsec_log "Ensuring toolchain (age, sops, gum, jq) — no sudo, no Homebrew required:"
  _deps_resolve age  required deps_fetch_age
  _deps_resolve sops required deps_fetch_sops
  _deps_resolve jq   required deps_fetch_jq
  _deps_resolve gum  optional deps_fetch_gum
}
