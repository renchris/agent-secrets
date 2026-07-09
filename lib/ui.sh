# shellcheck shell=bash
# lib/ui.sh — interactive UI (gum for navigation only; plain-read fallback mandatory).
#
# ui_read_secret uses builtin `read -s` ONLY — never gum, never echo
ui_title()       { agsec_die "ui_title: not implemented"; }
ui_say()         { agsec_die "ui_say: not implemented"; }
ui_step()        { agsec_die "ui_step: not implemented"; }
ui_ok()          { agsec_die "ui_ok: not implemented"; }
ui_warn()        { agsec_die "ui_warn: not implemented"; }
ui_bad()         { agsec_die "ui_bad: not implemented"; }
ui_confirm()     { agsec_die "ui_confirm: not implemented"; }
ui_menu()        { agsec_die "ui_menu: not implemented"; }
ui_read_secret() { agsec_die "ui_read_secret: not implemented"; }
