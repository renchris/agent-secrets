# shellcheck shell=bash
# lib/ui.sh — interactive UI layer. 
# gum is used ONLY for navigation/momentum; every SECRET input uses builtin `read -s` (never gum).
# Honors AGENT_SECRETS_PLAIN / NO_COLOR / --plain + adaptive colors (via common.sh). Sourced after
# common.sh. Names-only: ui_read_secret's value goes to STDOUT for the caller to pipe; nothing echoes.

_ui_gum() { [ -z "${AGENT_SECRETS_PLAIN:-}" ] && ! agsec_use_plain && agsec_have gum; }

ui_title() { if _ui_gum; then gum style --bold --border rounded --padding "0 1" -- "$*"; else printf '\n%s== %s ==%s\n' "$C_BOLD" "$*" "$C_RESET"; fi; }
ui_say()   { printf '%s\n' "$*"; }
ui_step()  { # ui_step N TOTAL TEXT
  printf '%s[%s/%s]%s %s\n' "$C_BLUE" "${1:-?}" "${2:-?}" "$C_RESET" "${3:-}"; }
ui_ok()    { agsec_ok "$*"; }
ui_warn()  { agsec_attn "$*"; }
ui_bad()   { agsec_bad "$*"; }

# ui_confirm PROMPT [default:y|n] -> exit 0 (yes) / 1 (no). [Enter] = default.
ui_confirm() {
  local prompt="${1:-Continue?}" def="${2:-y}" ans
  if _ui_gum; then gum confirm "$prompt" && return 0 || return 1; fi
  local hint="[Y/n]"; [ "$def" = "n" ] && hint="[y/N]"
  printf '%s %s ' "$prompt" "$hint" >&2
  read -r ans || true
  ans="${ans:-$def}"
  case "$ans" in [yY]*) return 0 ;; *) return 1 ;; esac
}

# ui_menu PROMPT OPT... -> chosen option to STDOUT.
ui_menu() {
  local prompt="$1"; shift
  if _ui_gum; then gum choose --header "$prompt" -- "$@"; return; fi
  printf '%s\n' "$prompt" >&2
  local i=1 opt
  for opt in "$@"; do printf '  %s) %s\n' "$i" "$opt" >&2; i=$((i+1)); done
  local pick; printf 'choose [1-%s]: ' "$#" >&2; read -r pick || true
  case "$pick" in ''|*[!0-9]*) pick=1 ;; esac
  [ "$pick" -ge 1 ] 2>/dev/null && [ "$pick" -le "$#" ] 2>/dev/null || pick=1
  eval "printf '%s\n' \"\${$pick}\""
}

# ui_read_secret PROMPT -> hidden builtin read (NEVER gum). Prompt+hint to STDERR; value to STDOUT
# (caller pipes it onward, e.g. `ui_read_secret "…" | store_add NAME`). Echoes nothing to the tty.
ui_read_secret() {
  local prompt="${1:-Value}" val
  printf '%s%s%s\n' "$C_DIM" "  (you won't see anything as you type or paste — that's on purpose; Cmd-V pastes here)" "$C_RESET" >&2
  printf '%s: ' "$prompt" >&2
  IFS= read -rs val || true
  printf '\n' >&2
  printf '%s' "$val"
  unset val
}
