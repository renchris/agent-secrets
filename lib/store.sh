# shellcheck shell=bash
# lib/store.sh — sops+age secret store.  
# Baseline stub. Assumes common.sh is
# already sourced by the entry script. Names-only (store_extract is the sole value-out, JIT).
store_init()          { agsec_die "store_init: not implemented"; }
store_add()           { agsec_die "store_add: not implemented"; }
store_has()           { agsec_die "store_has: not implemented"; }
store_names()         { agsec_die "store_names: not implemented"; }
store_extract()       { agsec_die "store_extract: not implemented"; }
store_exec()          { agsec_die "store_exec: not implemented"; }
store_canary_insert() { agsec_die "store_canary_insert: not implemented"; }
