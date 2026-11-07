# shellcheck shell=bash
# lib/ui.sh — interactive UI layer.
# LINE-BASED BY CONSTRUCTION: every prompt is a plain printf + `read`. No full-screen widget, no
# cursor addressing, no terminal capability query, no raw mode. That is a hard requirement, not a
# style choice — see WHY GUM IS GONE below.
# Honors AGENT_SECRETS_PLAIN / NO_COLOR / --plain + adaptive colors (via common.sh). Sourced after
# common.sh. Names-only: ui_read_secret's value goes to STDOUT for the caller to pipe; nothing echoes.
#
# WHY GUM IS GONE (measured 2026-09-11 over a PTY, docs/plans/ONE_COMMAND_SETUP_V2.md B3/B4):
#   1. `gum confirm` has no way to receive our declared default through the old call, so
#      `ui_confirm "…" n` answered YES on Enter — the canary armed itself when the user pressed
#      Enter to skip it. A default that inverts is worse than no default.
#   2. Resizing the window mid-prompt TRUNCATED the question mid-word
#      ("Populate your login Keychain now for prompt-f") — the user loses what they are answering.
#   3. Every call emitted OSC-11 (background query) + ESC[6n (cursor report) and blocked on the
#      reply: visible `]11;?\` garbage in a cooperating terminal, an apparent hang in one that does
#      not answer. That was the reported "unresponsive UI".
#   4. `gum style --border rounded` draws a fixed-width box that can never reflow.
# A plain line-based prompt has none of these: the terminal owns the wrapping, so it is correct at
# every width and survives a resize. gum bought a Yes/No and a four-item list; it is not worth this.

# Keep each emitted line SHORT and WHOLE (one logical sentence, no manual mid-sentence split). A
# hard-wrapped line is frozen at the width it was wrapped for — broken at 46 columns and at 120, and
# no emulator can reflow it. Soft-wrapping is the terminal's job; our job is to stay under its width.
# tests/onboarding.bats holds the budget (72 columns) as an executable assertion over a real run.

# Everything a person reads goes to stderr, so a captured stdout only ever carries a result.
ui_title() { printf '\n%s== %s ==%s\n' "$E_BOLD" "$*" "$E_RESET" >&2; }
ui_say()   { printf '%s\n' "$*" >&2; }
ui_step()  { # ui_step N TOTAL TEXT
  printf '%s[%s/%s]%s %s\n' "$E_BLUE" "${1:-?}" "${2:-?}" "$E_RESET" "${3:-}" >&2; }
ui_ok()    { agsec_receipt "$*"; }
ui_warn()  { agsec_receipt_attn "$*"; }
ui_bad()   { agsec_receipt_bad "$*"; }

# ui_confirm PROMPT [default:y|n] -> exit 0 (yes) / 1 (no). [Enter] = default, n when omitted.
# The default is ALWAYS shown (capitalised in the hint) — an invisible default is a trap.
ui_confirm() {
  local prompt="${1:?ui_confirm: PROMPT required}" def="${2:-n}" ans
  local hint="[Y/n]"; [ "$def" = "n" ] && hint="[y/N]"
  printf '%s %s ' "$prompt" "$hint" >&2
  # Distinguish EOF (closed stdin, no human) from a bare Enter (human accepting the default): on EOF
  # `read` returns non-zero AND leaves ans empty, so we must NOT apply the default — fail closed to NO.
  # A bare Enter returns zero with an empty ans → the default applies.
  if ! read -r ans; then return 1; fi
  ans="${ans:-$def}"
  case "$ans" in [yY]*) return 0 ;; *) return 1 ;; esac
}

# ui_menu PROMPT OPT... -> chosen option to STDOUT. A bare Enter picks option 1. Anything else that is
# not a listed number asks again, up to 3 times: a mistyped `2x` must not pick a secret nobody chose,
# because the value pasted next would be stored under its name. EOF or a 4th bad answer returns 1 with
# nothing on stdout, which is a cancel. The callers capture stdout, so it carries only the pick.
ui_menu() {
  local prompt="$1"; shift
  printf '%s\n' "$prompt" >&2
  local i=1 opt
  for opt in "$@"; do
    if [ "$i" -eq 1 ]; then printf '  %s) %s   (default)\n' "$i" "$opt" >&2
    else printf '  %s) %s\n' "$i" "$opt" >&2; fi
    i=$((i+1))
  done
  printf '(Ctrl-D cancels)\n' >&2
  local pick bad=0
  while :; do
    printf 'choose [1-%s, Enter = 1]: ' "$#" >&2
    if ! IFS= read -r pick; then printf '\n' >&2; return 1; fi
    pick="${pick:-1}"
    i=1
    for opt in "$@"; do
      if [ "$pick" = "$i" ]; then printf '%s\n' "$opt"; return 0; fi
      i=$((i+1))
    done
    bad=$((bad+1))
    [ "$bad" -le 3 ] || return 1
    printf 'Enter a number from 1 to %s.\n' "$#" >&2
  done
}

# ui_read_secret PROMPT -> hidden builtin `read -s`. Prompt+hint to STDERR; value to STDOUT
# (caller pipes it onward, e.g. `ui_read_secret "…" | store_add NAME`). Echoes nothing to the tty.
ui_read_secret() {
  local prompt="${1:-Value}" val
  agsec_plan "  (nothing appears as you type or paste — that's on purpose; Cmd-V works)"
  printf '%s: ' "$prompt" >&2
  IFS= read -rs val || true
  printf '\n' >&2
  printf '%s' "$val"
  unset val
}
