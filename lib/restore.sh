# shellcheck shell=bash
# lib/restore.sh — restore flow + returning-user fast path. 
#
# setup.sh calls these; keeping them here keeps setup.sh single-owner + under its LOC cap.
# Names-only: the age key VALUE transits ui_read_secret|kc_add (stdin), never echoed here.
restore_returning_user_check() { agsec_die "restore_returning_user_check: not implemented"; }
restore_flow()                 { agsec_die "restore_flow: not implemented"; }
