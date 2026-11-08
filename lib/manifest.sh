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
#   pathblock {type,file,marker,created,style}   — style: sh ('#' markers) | md (HTML-comment markers)

# --- marker format (single owner: write + strip MUST agree) ---------------------
# Two styles: 'sh' (# comment — shell rc) and 'md' (HTML comment — markdown surfaces like CLAUDE.md /
# AGENTS.md / GEMINI.md, where a bare '# >>>' line renders as an H1 heading). The writer picks the style
# and it is recorded; _manifest_strip_block matches BOTH styles unconditionally, so uninstall stays
# correct across a style migration AND for legacy '#' blocks written by earlier versions (dual-marker
# strip is permanent, not a transition window). Claude Code strips block HTML comments before injecting
# CLAUDE.md, so the md markers are disk-level grep targets, invisible to the agent — the rule body
# between them is plain markdown and stays agent-visible.
_manifest_block_begin() { case "${2:-sh}" in md) printf '<!-- >>> %s >>> -->' "$1";; *) printf '# >>> %s >>>' "$1";; esac; }
_manifest_block_end()   { case "${2:-sh}" in md) printf '<!-- <<< %s <<< -->' "$1";; *) printf '# <<< %s <<<' "$1";; esac; }

# Replace FILE with TMP (from agsec_tmp_sibling, never a fixed FILE.new that would clobber a user's own
# ~/.zshenv.new). agsec_commit writes THROUGH a symlink (a stow/chezmoi-managed ~/.zshenv or
# ~/.claude/CLAUDE.md must stay a link) and keeps FILE's mode; regular files keep the atomic mv.
_manifest_replace() {  # FILE TMP
  agsec_commit "$2" "$1"
}

# --- low-level append (idempotent init; jq is the only writer) ------------------
_manifest_append() {
  local rec="$1" mf tmp
  mf="$(agsec_install_manifest)"
  manifest_init
  tmp="$(mktemp "${mf}.XXXXXX")"
  # MOVE-TO-TAIL dedup: drop any identical earlier record and append this one at the END. A re-install /
  # rewire records the same symlink/PATH-block/launchd rows, so a blind append grew the manifest
  # unbounded — but merely DROPPING a re-record was worse: it left the record in its ORIGINAL position,
  # inverting LIFO. (S4 case: an `edit{restore user file}` recorded on a rewire must be undone AFTER the
  # `file{symlink}` is removed; if the file record kept its old position BEFORE the edit, rollback
  # restored the user's file then rm'd it — data loss.) Repositioning the identical record to the tail
  # keeps exactly one copy AND the invariant "most-recently recorded is rolled back first". Never sorts.
  jq --argjson r "$rec" 'map(select(. != $r)) + [$r]' "$mf" >"$tmp" && mv "$tmp" "$mf"
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
  # style is STABLE per file (a given surface always uses the same marker style), so it does not break
  # the move-to-tail dedup on re-install. No content hash is recorded: doctor detects a STALE block by
  # comparing the installed block's body to the current agsec_render_rules output, which avoids a
  # per-version hash churning the dedup (a changed hash would leave two pathblock records for one file).
  _manifest_append "$(jq -cn --arg file "$1" --arg marker "$2" --arg created "${3:-0}" --arg style "${4:-sh}" \
    '{type:"pathblock",file:$file,marker:$marker,created:($created=="1"),style:$style}')"
}

# --- write a marker-delimited PATH block idempotently + record it ---------------
# install.sh delegates here so the WRITE format matches the rollback STRIP format.
# manifest_pathblock_install <file> <marker> <line> [style=sh]
#   style 'sh' → '# >>>' markers (shell rc); 'md' → HTML-comment markers (markdown surfaces).
manifest_pathblock_install() {
  local file="$1" marker="$2" line="$3" style="${4:-sh}" body created=0 tmp
  # The user's file mode survives the rewrite: agsec_commit copies it onto the temp before the mv.
  [ -f "$file" ] || { created=1; : >"$file"; }            # note when WE create the rc / CLAUDE.md file
  body="$(_manifest_strip_block "$file" "$marker")"        # drop any prior block first (either style)
  tmp="$(agsec_tmp_sibling "$file")" || return 1
  {
    printf '%s\n' "$body"
    _manifest_block_begin "$marker" "$style"; printf '\n'
    printf '%s\n' "$line"
    _manifest_block_end "$marker" "$style"; printf '\n'
  } >"$tmp" || { rm -f "$tmp"; return 1; }
  _manifest_replace "$file" "$tmp" || return 1
  manifest_record_pathblock "$file" "$marker" "$created" "$style"
}

# --- back up a user's own file before linking over it ---------------------------
# Physical parent plus basename: the leaf may legitimately be a link, so only the parent is resolved.
_manifest_canon() {  # PATH → canonical path, or non-zero when the parent does not exist
  local d; d="$(cd -P "$(dirname "$1")" 2>/dev/null && pwd -P)" || return 1
  printf '%s/%s\n' "${d%/}" "$(basename "$1")"
}

# Ours = a LIVE symlink whose target is OURS by canonical path. A dangling link, a link elsewhere, or a
# regular file is the user's. A false "foreign" would back up our own link, so compare canonically.
_manifest_is_ours() {  # T OURS
  local t="$1" ours="$2" dest a b
  [ -L "$t" ] && [ -e "$t" ] || return 1
  dest="$(readlink "$t")" || return 1
  case "$dest" in /*) ;; *) dest="$(dirname "$t")/$dest" ;; esac
  a="$(_manifest_canon "$dest")" && b="$(_manifest_canon "$ours")" && [ "$a" = "$b" ]
}

_manifest_same_entry() {  # A B — same link text, or same bytes for two regular files
  if [ -L "$1" ] || [ -L "$2" ]; then
    [ -L "$1" ] && [ -L "$2" ] && [ "$(readlink "$1")" = "$(readlink "$2")" ]
  else
    cmp -s "$1" "$2"
  fi
}

# Usage: manifest_backup_user_target T BASENAME [OURS=$AGENT_SECRETS_ROOT/bin/<basename T>]
# Backs up a user's own file or symlink at T to $(agsec_state_dir)/BASENAME and records one edit record,
# so uninstall restores it after removing our link. Returns 0 when T is absent, a directory or already
# ours; non-zero when the copy or the record fails. A changed user file refreshes the backup and keeps the
# previous one as BASENAME.<UTC timestamp>; the single record stays, since a second one would make LIFO
# rollback restore the older file last.
manifest_backup_user_target() {
  local t="${1:-}" base="${2:-}" ours dir b old tmpd
  [ -n "$t" ] && [ -n "$base" ] || return 1
  ours="${3:-${AGENT_SECRETS_ROOT:-}/bin/$(basename "$t")}"
  [ -L "$t" ] || [ -f "$t" ] || return 0
  ! _manifest_is_ours "$t" "$ours" || return 0
  dir="$(agsec_state_dir)"; b="$dir/$base"
  [ -d "$dir" ] || { mkdir -p "$dir" && chmod 0700 "$dir"; } || return 1
  if [ -e "$b" ] || [ -L "$b" ]; then
    if _manifest_same_entry "$t" "$b"; then
      manifest_record_edit "$t" "$b"; return
    fi
    old="$b.$(date -u +%Y%m%d%H%M%S)"
    [ ! -e "$old" ] && [ ! -L "$old" ] || old="$old.$$"
    mv -f "$b" "$old" || return 1
    agsec_receipt "kept the earlier backup of $t as $old"
  fi
  # cp -p would follow a link; -PR copies the link itself. A private dir keeps the copy off $b until done.
  tmpd="$(mktemp -d "$dir/.$base.XXXXXX")" || return 1
  if cp -PR "$t" "$tmpd/entry" && mv -f "$tmpd/entry" "$b"; then
    rmdir "$tmpd" 2>/dev/null || true
  else
    rm -f "$tmpd/entry"; rmdir "$tmpd" 2>/dev/null || true
    return 1
  fi
  manifest_record_edit "$t" "$b"
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
  local file="$1" marker="$2" bsh esh bmd emd
  bsh="$(_manifest_block_begin "$marker" sh)"; esh="$(_manifest_block_end "$marker" sh)"
  bmd="$(_manifest_block_begin "$marker" md)"; emd="$(_manifest_block_end "$marker" md)"
  [ -f "$file" ] || return 0
  # Match EITHER marker style (sh '#' or md HTML-comment) so a legacy '#' block and a new md block are
  # both stripped — dual-marker strip is permanent. A block is always written with matching begin/end
  # styles, so accepting either end after either begin is safe (we never nest/mix within one block).
  # Compare on a CR-stripped copy of the line (line) but PRINT the original ($0): a CRLF-saved rc /
  # CLAUDE.md (cross-platform editor, synced dotfile) would otherwise never match the CR-free marker
  # and leave the whole block as residue. Preserving $0 keeps the user's own CRLF lines byte-for-byte.
  awk -v bsh="$bsh" -v esh="$esh" -v bmd="$bmd" -v emd="$emd" '
    { line=$0; sub(/\r$/,"",line) }
    (line==bsh || line==bmd) { if(bufn){ for(i=1;i<=bufn;i++) print buf[i] }; buffering=1; bufn=0; buf[++bufn]=$0; next }
    buffering && (line==esh || line==emd) { buffering=0; bufn=0; next }   # complete block → drop it
    buffering { buf[++bufn]=$0; next }
    { print }
    END { if(buffering){ for(i=1;i<=bufn;i++) print buf[i] } }   # unterminated block → keep it all
  ' "$file"
}

# Enumerate login-keychain generic-password services the tool created — scoped to the EXACT service
# via `grep -Fx` (whole-line match on the single service name), NOT a broad `agent-` prefix that would
# over-delete a user's unrelated `agent-*` items. An attribute dump does NOT prompt (only reading a
# secret data blob would); best-effort.
_manifest_kc_exact() {
  security dump-keychain 2>/dev/null \
    | sed -n 's/^[[:space:]]*"svce"<blob>="\(.*\)"$/\1/p' \
    | grep -Fx "$AGENT_SECRETS_KC_SERVICE" 2>/dev/null | sort -u
}

_manifest_kc_delete() {  # delete every item under a service (loops to clear duplicates); 1 if one survives
  local svc="$1"
  while security delete-generic-password -s "$svc" >/dev/null 2>&1; do :; done
  if security find-generic-password -s "$svc" >/dev/null 2>&1; then
    agsec_receipt_bad "keychain item still present: $svc"
    return 1
  fi
}

# Rollback helpers return 0 (gone), 1 (failed: the record is kept for a retry) or 3 (skipped: nothing left
# to undo). Each is called as `|| rc=$?` so a failure under set -e cannot abort the remaining records.
_manifest_rb_count() {  # RC REC
  case "$1" in
    0) _rb_ok=$((_rb_ok + 1)) ;;
    3) _rb_skip=$((_rb_skip + 1)) ;;
    *) _rb_fail=$((_rb_fail + 1)); _rb_failed+=("$2") ;;
  esac
}

manifest_rollback() {
  local dry=0
  [ "${1:-}" = "--dry-run" ] && dry=1
  local mf; mf="$(agsec_install_manifest)"
  [ -f "$mf" ] || { agsec_note "no install manifest — nothing to roll back"; return 0; }
  # A CORRUPTED manifest makes `jq reverse[]` emit nothing → the loop rolls back ZERO records, yet the
  # tail still clears the manifest + prints "every artifact removed" while everything stays on disk and
  # the evidence is gone. Validate it parses first; on failure fail LOUD and preserve the file.
  jq -e 'type=="array"' "$mf" >/dev/null 2>&1 \
    || agsec_die "install manifest is not a valid JSON array — refusing to clear it or claim zero residue; inspect $mf (each recorded artifact is still on disk)"

  local rec type p rc i total=0
  local _rb_ok=0 _rb_fail=0 _rb_skip=0
  local -a _rb_failed=() deferred_paths=() deferred_recs=()
  # Reverse order so later artifacts undo before earlier ones (LIFO). BUT a `file` record that points at
  # an existing DIRECTORY (the install root, which holds the vendored jq/age/sops on a no-brew install)
  # is DEFERRED to a final pass: removing it mid-loop deletes jq and every later `jq -r '.type'` exits
  # 127, aborting the rest of the rollback under set -e — stranding the settings.json edit, the Keychain
  # item, and user-file restores. A re-install re-records the install-dir path and move-to-tail floats it
  # toward the front, so this ordering guard is load-bearing (not just belt-and-suspenders). Paths are
  # extracted NOW (jq still present) and removed after the loop, so no jq call outlives the install dir.
  while IFS= read -r rec; do
    [ -n "$rec" ] || continue
    total=$((total + 1))
    type="$(jq -r '.type' <<<"$rec")"
    if [ "$type" = file ]; then
      p="$(jq -r '.path' <<<"$rec")"
      if [ -d "$p" ] && [ ! -L "$p" ]; then deferred_paths+=("$p"); deferred_recs+=("$rec"); continue; fi
    fi
    rc=0
    case "$type" in
      file)      _manifest_rb_file "$rec" "$dry" || rc=$? ;;
      edit)      _manifest_rb_edit "$rec" "$dry" || rc=$? ;;
      keychain)  _manifest_rb_keychain "$rec" "$dry" || rc=$? ;;
      launchd)   _manifest_rb_launchd "$rec" "$dry" || rc=$? ;;
      pathblock) _manifest_rb_pathblock "$rec" "$dry" || rc=$? ;;
      *)         rc=3 ;;
    esac
    _manifest_rb_count "$rc" "$rec"
  done < <(jq -c 'reverse[]' "$mf")
  # Deferred directory removals LAST (no jq needed — paths already captured; removing the install dir
  # takes the vendored jq with it).
  i=0
  while [ "$i" -lt "${#deferred_paths[@]}" ]; do
    p="${deferred_paths[$i]}"; rc=0
    if [ "$dry" -eq 1 ]; then agsec_plan "(dry-run) rm dir: $p"
    elif rm -rf "$p"; then agsec_receipt "removed dir: $p"
    else agsec_receipt_bad "could not remove dir: $p"; rc=1; fi
    _manifest_rb_count "$rc" "${deferred_recs[$i]}"
    i=$((i + 1))
  done

  # Belt-and-suspenders: purge our EXACT-service Keychain item even if its record was lost. A survivor
  # is kept as a keychain record so the retry targets it.
  local svc
  while IFS= read -r svc; do
    [ -n "$svc" ] || continue
    if [ "$dry" -eq 1 ]; then agsec_plan "(dry-run) keychain purge (exact service): $svc"; continue; fi
    total=$((total + 1)); rc=0
    if _manifest_kc_delete "$svc"; then agsec_receipt "keychain purged (exact service): $svc"; else rc=1; fi
    _manifest_rb_count "$rc" "{\"type\":\"keychain\",\"service\":\"$(agsec_js "$svc")\"}"
  done < <(_manifest_kc_exact)

  if [ "$dry" -eq 1 ]; then
    agsec_plan "(dry-run) install manifest would be cleared"
    return 0
  fi
  if [ "$_rb_fail" -eq 0 ]; then
    printf '[]\n' | agsec_atomic_write "$mf" || { agsec_receipt_bad "could not clear the install manifest: $mf"; return 1; }
    agsec_receipt "install manifest cleared"
    return 0
  fi
  _manifest_keep_failed "$mf" ${_rb_failed[@]+"${_rb_failed[@]}"} \
    || agsec_receipt_bad "could not rewrite the install manifest: $mf (it still lists every record)"
  agsec_receipt_bad "Removed $_rb_ok of $total artifacts. $_rb_fail failed, $_rb_skip skipped. Re-run agent-secrets uninstall to retry the rest."
  return 1
}

# Rewrite MF to hold only the failed records, in their original (install) order. They arrive in rollback
# (reverse) order. The install dir may have taken a vendored jq with it, so the jq-free fallback joins the
# records, each already one compact JSON object from `jq -c`.
_manifest_keep_failed() {  # MF REC...
  local mf="$1" tmp joined="" r; shift
  tmp="$(agsec_tmp_sibling "$mf")" || return 1
  if agsec_have jq; then
    jq -n '$ARGS.positional | reverse' --jsonargs "$@" >"$tmp" || { rm -f "$tmp"; return 1; }
  else
    for r in "$@"; do joined="$r${joined:+,$joined}"; done
    printf '[%s]\n' "$joined" >"$tmp" || { rm -f "$tmp"; return 1; }
  fi
  agsec_commit "$tmp" "$mf"
}

_manifest_rb_file() {
  local rec="$1" dry="$2" p; p="$(jq -r '.path' <<<"$rec")"
  if [ "$dry" -eq 1 ]; then agsec_plan "(dry-run) rm: $p"; return 0; fi
  # A recorded real directory (the unpacked $INSTALL_DIR) is removed recursively; everything else
  # (files, and symlinks-to-dirs) is rm -f so we never delete THROUGH a symlink.
  if [ -d "$p" ] && [ ! -L "$p" ]; then
    rm -rf "$p" && { agsec_receipt "removed dir: $p"; return 0; }
  else
    rm -f "$p" && { agsec_receipt "removed: $p"; return 0; }
  fi
  agsec_receipt_bad "could not remove: $p"
  return 1
}

_manifest_rb_edit() {
  local rec="$1" dry="$2" p backup created marker
  p="$(jq -r '.path' <<<"$rec")"; backup="$(jq -r '.backup' <<<"$rec")"
  created="$(jq -r '.created // false' <<<"$rec")"; marker="$(jq -r '.marker // ""' <<<"$rec")"
  if [ "$dry" -eq 1 ]; then
    if [ -n "$marker" ]; then agsec_plan "(dry-run) remove key .$marker from: $p$([ "$created" = true ] && printf ' (delete if now empty)')"
    elif [ "$created" = true ]; then agsec_plan "(dry-run) remove tool-created file: $p"
    else agsec_plan "(dry-run) restore edit: $p <- $backup"; fi
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
      mv -f "$tmp" "$p"; agsec_receipt "restored pre-install .$marker: $p"; return 0
    fi
    if jq "del(.\"$marker\")" "$p" >"$tmp" 2>/dev/null; then
      # Tool added the key fresh (no pre-install value) → remove it, preserving the user's other keys.
      if [ "$created" = true ] && [ "$(tr -d '[:space:]' <"$tmp")" = "{}" ]; then
        rm -f "$tmp" "$p"; rmdir "$(dirname "$p")" 2>/dev/null || true
        agsec_receipt "removed tool-created (now empty): $p"
      else
        mv -f "$tmp" "$p"; agsec_receipt "reverted edit (removed .$marker): $p"
      fi
      return 0
    fi
    rm -f "$tmp"   # jq failed → fall through to the coarse path
  fi
  # Fallback (no marker recorded / no jq / not a regular file): the coarse behavior.
  if [ "$created" = true ]; then
    rm -f "$p" || { agsec_receipt_bad "could not remove tool-created: $p"; return 1; }
    agsec_receipt "removed tool-created: $p"; rmdir "$(dirname "$p")" 2>/dev/null || true
    return 0
  fi
  # A link backup (manifest_backup_user_target copies links as links) comes back as the same link, live
  # or dangling; `[ -f ]` would deref a live one into a copy and call a dangling one missing.
  if [ -L "$backup" ]; then
    rm -f "$p" && ln -s "$(readlink "$backup")" "$p" && { agsec_receipt "reverted edit (link): $p"; return 0; }
    agsec_receipt_bad "could not restore the link at: $p (backup: $backup)"; return 1
  fi
  if [ -f "$backup" ]; then
    cp "$backup" "$p" && { agsec_receipt "reverted edit: $p"; return 0; }
    agsec_receipt_bad "could not restore: $p (backup: $backup)"; return 1
  fi
  agsec_warn "edit backup missing, left as-is: $p (expected backup: $backup)"
  return 1
}

_manifest_rb_keychain() {
  local rec="$1" dry="$2" svc; svc="$(jq -r '.service' <<<"$rec")"
  if [ "$dry" -eq 1 ]; then agsec_plan "(dry-run) keychain delete: $svc"; return 0; fi
  _manifest_kc_delete "$svc" || return 1
  agsec_receipt "keychain deleted: $svc"
}

_manifest_rb_launchd() {
  local rec="$1" dry="$2" label plist
  label="$(jq -r '.label' <<<"$rec")"; plist="$(jq -r '.plist' <<<"$rec")"
  if [ "$dry" -eq 1 ]; then agsec_plan "(dry-run) launchctl bootout + rm: $label"; return 0; fi
  launchctl bootout "gui/$(id -u)/$label" >/dev/null 2>&1 || true   # "not loaded" is fine; print decides
  if launchctl print "gui/$(id -u)/$label" >/dev/null 2>&1; then
    agsec_receipt_bad "launchd job still loaded: $label"; return 1
  fi
  rm -f "$plist" || { agsec_receipt_bad "could not remove launchd plist: $plist"; return 1; }
  agsec_receipt "launchd booted out: $label"
}

_manifest_rb_pathblock() {
  local rec="$1" dry="$2" file marker stripped created tmp
  file="$(jq -r '.file' <<<"$rec")"; marker="$(jq -r '.marker' <<<"$rec")"; created="$(jq -r '.created // false' <<<"$rec")"
  if [ "$dry" -eq 1 ]; then agsec_plan "(dry-run) strip block '$marker' from: $file"; return 0; fi
  [ -f "$file" ] || return 3
  stripped="$(_manifest_strip_block "$file" "$marker")"
  # If WE created this file and only blank lines remain after stripping our block, remove it — don't
  # leave an orphaned empty ~/.zshenv / ~/.claude/CLAUDE.md (the "zero tool residue" claim).
  if [ "$created" = true ] && ! printf '%s' "$stripped" | grep -q '[^[:space:]]'; then
    rm -f "$file" || { agsec_receipt_bad "could not remove tool-created: $file"; return 1; }
    agsec_receipt "removed tool-created: $file"
    rmdir "$(dirname "$file")" 2>/dev/null || true   # drop a now-empty tool-created dir (e.g. ~/.claude)
  else
    if tmp="$(agsec_tmp_sibling "$file")"; then
      if printf '%s\n' "$stripped" >"$tmp" && _manifest_replace "$file" "$tmp"; then
        agsec_receipt "stripped block: $file"; return 0
      fi
      rm -f "$tmp"
    fi
    agsec_receipt_bad "could not strip block: $file"
    return 1
  fi
}
