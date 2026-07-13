# shellcheck shell=bash
# lib/manifest.sh — the INSTALL manifest (distinct from the store's values-free manifest.toml).
# A JSON array at agsec_install_manifest() recording TOOL artifacts only
# (never a secret value) so setup is idempotent and uninstall/rollback is total.
# Sourced AFTER lib/common.sh (uses its path/log helpers). Requires jq.
# Record types:
#   file      {type,path,sha256,mode}
#   edit      {type,path,backup,marker}   — revert a third-party config edit (e.g. settings.json)
#   keychain  {type,service}
#   launchd   {type,label,plist}
#   pathblock {type,file,marker}

# --- marker format (single owner: write + strip MUST agree) ---------------------
_manifest_block_begin() { printf '# >>> %s >>>' "$1"; }
_manifest_block_end()   { printf '# <<< %s <<<' "$1"; }

# --- low-level append (idempotent init; jq is the only writer) ------------------
_manifest_append() {
  local rec="$1" mf tmp
  mf="$(agsec_install_manifest)"
  manifest_init
  tmp="$(mktemp "${mf}.XXXXXX")"
  jq --argjson r "$rec" '. += [$r]' "$mf" >"$tmp" && mv "$tmp" "$mf"
}

manifest_init() {
  local mf dir
  mf="$(agsec_install_manifest)"
  dir="$(dirname "$mf")"
  [ -d "$dir" ] || { mkdir -p "$dir"; chmod 0700 "$dir"; }
  [ -f "$mf" ] || printf '[]\n' >"$mf"
}

# --- record ---------------------------------------------------------------------
manifest_record_file() {
  local p="$1" sha mode
  [ -e "$p" ] || { agsec_warn "manifest_record_file: not found: $p"; return 1; }
  sha="$(shasum -a 256 "$p" 2>/dev/null | awk '{print $1}')"
  mode="$(stat -f '%Lp' "$p" 2>/dev/null)"
  _manifest_append "$(jq -cn --arg path "$p" --arg sha "$sha" --arg mode "$mode" \
    '{type:"file",path:$path,sha256:$sha,mode:$mode}')"
}

manifest_record_edit() {
  local p="$1" backup="$2" marker="${3:-}" created="${4:-}"
  # created="created" ⇒ the tool CREATED this file (there was nothing before); rollback DELETES it
  # rather than restoring the backup (which would leave an empty {} residue).
  _manifest_append "$(jq -cn --arg path "$p" --arg backup "$backup" --arg marker "$marker" --arg created "$created" \
    '{type:"edit",path:$path,backup:$backup,marker:$marker,created:($created=="created")}')"
}

manifest_record_keychain() {
  _manifest_append "$(jq -cn --arg service "$1" '{type:"keychain",service:$service}')"
}

manifest_record_launchd() {
  _manifest_append "$(jq -cn --arg label "$1" --arg plist "$2" \
    '{type:"launchd",label:$label,plist:$plist}')"
}

manifest_record_pathblock() {
  _manifest_append "$(jq -cn --arg file "$1" --arg marker "$2" --arg created "${3:-0}" \
    '{type:"pathblock",file:$file,marker:$marker,created:($created=="1")}')"
}

# --- write a marker-delimited PATH block idempotently + record it ---------------
# install.sh delegates here so the WRITE format matches the rollback STRIP format.
manifest_pathblock_install() {
  local file="$1" marker="$2" line="$3" body created=0
  [ -f "$file" ] || { created=1; : >"$file"; }          # note when WE create the rc / CLAUDE.md file
  body="$(_manifest_strip_block "$file" "$marker")"      # drop any prior block first
  {
    printf '%s\n' "$body"
    _manifest_block_begin "$marker"; printf '\n'
    printf '%s\n' "$line"
    _manifest_block_end "$marker"; printf '\n'
  } >"${file}.new" && mv "${file}.new" "$file"
  manifest_record_pathblock "$file" "$marker" "$created"
}

# --- list -----------------------------------------------------------------------
manifest_list() {
  local mf; mf="$(agsec_install_manifest)"
  [ -f "$mf" ] || return 0
  if [ -n "${1:-}" ]; then
    jq -c --arg t "$1" '.[] | select(.type==$t)' "$mf"
  else
    jq -c '.[]' "$mf"
  fi
}

# --- rollback -------------------------------------------------------------------
# Strip the COMPLETE marker-delimited block (begin..end) from FILE, print the remainder. If a begin
# marker has NO matching end before EOF (a user corrupted/trimmed the end line), keep EVERYTHING —
# never delete begin→EOF, which would eat unrelated content below a hand-edited ~/.claude/CLAUDE.md.
_manifest_strip_block() {
  local file="$1" marker="$2" b e
  b="$(_manifest_block_begin "$marker")"
  e="$(_manifest_block_end "$marker")"
  [ -f "$file" ] || return 0
  awk -v b="$b" -v e="$e" '
    $0==b { if(bufn){ for(i=1;i<=bufn;i++) print buf[i] }; buffering=1; bufn=0; buf[++bufn]=$0; next }
    buffering && $0==e { buffering=0; bufn=0; next }        # complete block → drop it
    buffering { buf[++bufn]=$0; next }
    { print }
    END { if(buffering){ for(i=1;i<=bufn;i++) print buf[i] } }   # unterminated block → keep it all
  ' "$file"
}

# Enumerate login-keychain generic-password services the tool created — scoped to the EXACT service
# (not the broad `agent-` prefix, which would over-delete a user's unrelated `agent-*` items). An
# attribute dump does NOT prompt (only reading a secret data blob would); best-effort.
_manifest_kc_by_prefix() {
  security dump-keychain 2>/dev/null \
    | sed -n 's/^[[:space:]]*"svce"<blob>="\(.*\)"$/\1/p' \
    | grep -Fx "$AGENT_SECRETS_KC_SERVICE" 2>/dev/null | sort -u
}

_manifest_kc_delete() {  # delete every item under a service (loops to clear duplicates)
  local svc="$1"
  while security delete-generic-password -s "$svc" >/dev/null 2>&1; do :; done
}

manifest_rollback() {
  local dry=0
  [ "${1:-}" = "--dry-run" ] && dry=1
  local mf; mf="$(agsec_install_manifest)"
  [ -f "$mf" ] || { agsec_note "no install manifest — nothing to roll back"; return 0; }

  local rec type
  # Reverse order so later artifacts undo before earlier ones (LIFO).
  while IFS= read -r rec; do
    [ -n "$rec" ] || continue
    type="$(jq -r '.type' <<<"$rec")"
    case "$type" in
      file)      _manifest_rb_file "$rec" "$dry" ;;
      edit)      _manifest_rb_edit "$rec" "$dry" ;;
      keychain)  _manifest_rb_keychain "$rec" "$dry" ;;
      launchd)   _manifest_rb_launchd "$rec" "$dry" ;;
      pathblock) _manifest_rb_pathblock "$rec" "$dry" ;;
    esac
  done < <(jq -c 'reverse[]' "$mf")

  # Belt-and-suspenders: purge any lingering agent-* Keychain item not in a record.
  local svc
  while IFS= read -r svc; do
    [ -n "$svc" ] || continue
    if [ "$dry" -eq 1 ]; then agsec_note "(dry-run) keychain purge (prefix): $svc"
    else _manifest_kc_delete "$svc"; agsec_ok "keychain purged (prefix): $svc"; fi
  done < <(_manifest_kc_by_prefix)

  if [ "$dry" -eq 1 ]; then
    agsec_note "(dry-run) install manifest would be cleared"
  else
    printf '[]\n' >"$mf"; agsec_ok "install manifest cleared"
  fi
}

_manifest_rb_file() {
  local rec="$1" dry="$2" p; p="$(jq -r '.path' <<<"$rec")"
  if [ "$dry" -eq 1 ]; then agsec_note "(dry-run) rm: $p"; return 0; fi
  # A recorded real directory (the unpacked $INSTALL_DIR) is removed recursively; everything else
  # (files, and symlinks-to-dirs) is rm -f so we never delete THROUGH a symlink.
  if [ -d "$p" ] && [ ! -L "$p" ]; then rm -rf "$p" && agsec_ok "removed dir: $p"
  else rm -f "$p" && agsec_ok "removed: $p"; fi
}

_manifest_rb_edit() {
  local rec="$1" dry="$2" p backup created marker
  p="$(jq -r '.path' <<<"$rec")"; backup="$(jq -r '.backup' <<<"$rec")"
  created="$(jq -r '.created // false' <<<"$rec")"; marker="$(jq -r '.marker // ""' <<<"$rec")"
  if [ "$dry" -eq 1 ]; then
    if [ -n "$marker" ]; then agsec_note "(dry-run) remove key .$marker from: $p$([ "$created" = true ] && printf ' (delete if now empty)')"
    elif [ "$created" = true ]; then agsec_note "(dry-run) remove tool-created file: $p"
    else agsec_note "(dry-run) restore edit: $p <- $backup"; fi
    return 0
  fi
  # SURGICAL revert: the tool only ADDED one key (marker, e.g. apiKeyHelper). Remove exactly that key
  # and PRESERVE the user's later edits — a whole-file restore/delete would silently discard their
  # Claude Code config (model/hooks/permissions added after install).
  if [ -n "$marker" ] && [ -f "$p" ] && agsec_have jq; then
    local tmp orig; tmp="$(mktemp)"
    # The user's PRE-INSTALL value for this key (null if the tool added it fresh, or no backup exists).
    orig="$(jq -c ".\"$marker\" // null" "$backup" 2>/dev/null || echo null)"
    # RESTORE only for a PRE-EXISTING file (created=false). A tool-created file never has a valid
    # same-install backup for this key; a stale cross-cycle backup must not resurrect a historical value.
    if [ "$created" != true ] && [ "$orig" != null ] && jq --argjson v "$orig" ".\"$marker\" = \$v" "$p" >"$tmp" 2>/dev/null; then
      # The user had their OWN apiKeyHelper before install → RESTORE it, don't delete the key.
      mv -f "$tmp" "$p"; agsec_ok "restored pre-install .$marker: $p"; return 0
    fi
    if jq "del(.\"$marker\")" "$p" >"$tmp" 2>/dev/null; then
      # Tool added the key fresh (no pre-install value) → remove it, preserving the user's other keys.
      if [ "$created" = true ] && [ "$(tr -d '[:space:]' <"$tmp")" = "{}" ]; then
        rm -f "$tmp" "$p"; rmdir "$(dirname "$p")" 2>/dev/null || true
        agsec_ok "removed tool-created (now empty): $p"
      else
        mv -f "$tmp" "$p"; agsec_ok "reverted edit (removed .$marker): $p"
      fi
      return 0
    fi
    rm -f "$tmp"   # jq failed → fall through to the coarse path
  fi
  # Fallback (no marker recorded / no jq / not a regular file): the coarse behavior.
  if [ "$created" = true ]; then
    rm -f "$p" && agsec_ok "removed tool-created: $p"; rmdir "$(dirname "$p")" 2>/dev/null || true
  elif [ -f "$backup" ]; then cp "$backup" "$p" && agsec_ok "reverted edit: $p"
  else agsec_warn "edit backup missing, left as-is: $p"; fi
}

_manifest_rb_keychain() {
  local rec="$1" dry="$2" svc; svc="$(jq -r '.service' <<<"$rec")"
  if [ "$dry" -eq 1 ]; then agsec_note "(dry-run) keychain delete: $svc"; return 0; fi
  _manifest_kc_delete "$svc"; agsec_ok "keychain deleted: $svc"
}

_manifest_rb_launchd() {
  local rec="$1" dry="$2" label plist
  label="$(jq -r '.label' <<<"$rec")"; plist="$(jq -r '.plist' <<<"$rec")"
  if [ "$dry" -eq 1 ]; then agsec_note "(dry-run) launchctl bootout + rm: $label"; return 0; fi
  launchctl bootout "gui/$(id -u)/$label" >/dev/null 2>&1 || true
  rm -f "$plist" && agsec_ok "launchd booted out: $label"
}

_manifest_rb_pathblock() {
  local rec="$1" dry="$2" file marker stripped created
  file="$(jq -r '.file' <<<"$rec")"; marker="$(jq -r '.marker' <<<"$rec")"; created="$(jq -r '.created // false' <<<"$rec")"
  if [ "$dry" -eq 1 ]; then agsec_note "(dry-run) strip block '$marker' from: $file"; return 0; fi
  [ -f "$file" ] || return 0
  stripped="$(_manifest_strip_block "$file" "$marker")"
  # If WE created this file and only blank lines remain after stripping our block, remove it — don't
  # leave an orphaned empty ~/.zshenv / ~/.claude/CLAUDE.md (the "zero tool residue" claim).
  if [ "$created" = true ] && ! printf '%s' "$stripped" | grep -q '[^[:space:]]'; then
    rm -f "$file" && agsec_ok "removed tool-created: $file"
    rmdir "$(dirname "$file")" 2>/dev/null || true   # drop a now-empty tool-created dir (e.g. ~/.claude)
  else
    printf '%s\n' "$stripped" >"${file}.new" && mv "${file}.new" "$file"
    agsec_ok "stripped block: $file"
  fi
}
