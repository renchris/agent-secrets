# shellcheck shell=bash
# lib/manifest.sh — INSTALL manifest (JSON at agsec_install_manifest; distinct from the store's
# manifest.toml). Records TOOL artifacts for total uninstall. 
# Uses jq. No secret values here.
manifest_init()            { agsec_die "manifest_init: not implemented"; }
manifest_record_file()     { agsec_die "manifest_record_file: not implemented"; }
manifest_record_edit()     { agsec_die "manifest_record_edit: not implemented"; }
manifest_record_keychain() { agsec_die "manifest_record_keychain: not implemented"; }
manifest_record_launchd()  { agsec_die "manifest_record_launchd: not implemented"; }
manifest_record_pathblock(){ agsec_die "manifest_record_pathblock: not implemented"; }
manifest_list()            { agsec_die "manifest_list: not implemented"; }
manifest_rollback()        { agsec_die "manifest_rollback: not implemented"; }
