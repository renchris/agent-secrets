# shellcheck shell=bash
# lib/ladder.sh — the don't-share ladder (design §6). Sourced by cmd/share.sh after common.sh.
# Sharing a value is the LAST rung: the ladder runs BEFORE any encryption and, on a per-person-mintable
# name, refuses with a provider-specific "recipient should mint their own" recipe unless the sender
# asserts --singleton (a true singleton the ladder cannot second-guess) or the share is a self-share.
#
# The provider table is a HARDCODED, KNOWINGLY-STALE advisory ($0/zero-vendor = no network authority):
# it educates + redirects, backed by the mandatory human confirm. Names-only: no value is handled here.

# _ladder_print_r2 NAME PROVIDER — print the R2 refusal recipe (design §6 "Exact rung copy") to STDERR.
# Provider-specific where the table knows it; a generic recipe otherwise.
_ladder_print_r2() {
  local name="$1" provider="$2" mint
  case "$provider" in
    anthropic) mint="  Anthropic:  console → Settings → Members → invite them (needs an org admin),
              then they create their own key (Workspace Developer role)." ;;
    openai)    mint="  OpenAI:     invite them to the project, then they create their own
              project-scoped API key (individually attributable + revocable)." ;;
    github)    mint="  GitHub:     they create their own fine-grained PAT (or use Actions OIDC for
              keyless CI) — never hand over a shared token." ;;
    aws)       mint="  AWS:        add them in IAM Identity Center (or a per-user IAM principal);
              prefer roles / federation so no long-lived key need exist at all." ;;
    *)         mint="  Have the recipient mint their own per-person key at the provider
              (individually attributable + independently revocable)." ;;
  esac
  cat >&2 <<EOF
This looks like a per-person key. Before you share a value, the recipient should
mint their own — it's individually attributable and independently revocable.

$mint

Sharing a value is the last resort. If they truly can't mint their own, re-run:
  agent-secrets share $name --to <recipient> --singleton
EOF
}

# ladder_gate NAME RECIPKIND SINGLETON
#   RECIPKIND ∈ self|other   SINGLETON = non-empty when --singleton was passed.
# Return 0 → proceed (caller continues to the confirm + encrypt).
# Return 1 → refused; the caller exits 1 (the recipe was already printed to STDERR).
ladder_gate() {
  local name="${1:?ladder_gate: NAME required}" kind="${2:-other}" singleton="${3:-}"
  # R0 — self-share bypass: no third identity to mint for.
  [ "$kind" = self ] && return 0
  # R3 — the sender asserts a true singleton the ladder cannot second-guess.
  [ -n "$singleton" ] && return 0
  local up; up="$(printf '%s' "$name" | tr '[:lower:]' '[:upper:]')"
  # R3 — symmetric-by-construction: per-person keying is cryptographically meaningless.
  case "$up" in *WEBHOOK*|*HMAC*|*SIGNING*) return 0 ;; esac
  # R2 — per-person-mintable provider (advisory table). Refuse with the mint-your-own recipe.
  local provider=""
  case "$up" in
    *ANTHROPIC*)               provider=anthropic ;;
    *OPENAI*)                  provider=openai ;;
    *GITHUB*|*GH_*)            provider=github ;;
    *AWS_ACCESS*|*AWS_SECRET*) provider=aws ;;
  esac
  if [ -n "$provider" ]; then
    _ladder_print_r2 "$name" "$provider"
    return 1
  fi
  # R4 — terminal: no clean rung, but proceed with ceremony (the confirm) rather than a dead-end loop.
  return 0
}
