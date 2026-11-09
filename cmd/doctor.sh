#!/usr/bin/env bash
# cmd/doctor.sh — categorized names-only health checks.
# Categories: custody · store · injection ·
# hygiene · maintenance · supply-chain (+ --gates c/d/e). Every check catches
# its own failure so doctor NEVER crashes when nothing is set up — it reports ✗/⚠ instead.
# Names-only: no check ever writes a secret VALUE (checked via exit code / non-empty only).
set -euo pipefail
. "${AGENT_SECRETS_LIB:?AGENT_SECRETS_LIB unset — run via bin/agent-secrets}/common.sh"
case "${1:-}" in -h|--help) . "$AGENT_SECRETS_LIB/help.sh"; agsec_help_render doctor; exit 0 ;; esac
. "$AGENT_SECRETS_LIB/store.sh"       # every call below is guarded against an unset/absent store
. "$AGENT_SECRETS_LIB/keychain.sh"    # guarded against an unset/absent store
. "$AGENT_SECRETS_LIB/egress.sh"      # egress allowlist status for gate (e)
. "$AGENT_SECRETS_LIB/deps.sh"        # toolchain adequacy (sops SOPS_AGE_KEY_CMD version gate) — fn defs only
. "$AGENT_SECRETS_LIB/manifest.sh"    # marker helpers (discovery block extraction)
. "$AGENT_SECRETS_LIB/discovery.sh"   # machine-wide agent-discovery registry (per-surface status)

FORMAT=text ; REDACT=0 ; FIX=0 ; GATES=0 ; SUMMARY=0 ; FORMAT_ALIASES=""
agsec_scan_json "$@"   # so a usage error below already comes out in the selected format
for arg in "$@"; do
  case "$arg" in
    --json)        FORMAT=json ;;
    # Hidden deprecated aliases (the space form `--format json` was never accepted, and is not added).
    --format=json|--format=text) FORMAT=${arg#--format=}; FORMAT_ALIASES="$FORMAT_ALIASES $arg" ;;
    --redact)      REDACT=1 ;;
    --fix)         FIX=1 ;;
    --gates)       GATES=1 ;;
    --summary)     SUMMARY=1 ;;
    -h|--help) printf '%s\n' "usage: agent-secrets doctor [--json] [--redact] [--gates] [--summary] [--fix]"; exit 0 ;;
    *) agsec_unknown_option doctor "$arg" ;;
  esac
done
AGSEC_OUTPUT=$FORMAT   # the last format flag wins, for the document and for any error after this
agsec_parse_only_exit
for arg in $FORMAT_ALIASES; do
  case "$arg" in
    --format=json) agsec_deprecated "$arg" --json ;;
    *)             agsec_deprecated "$arg" "the default text output (no flag)" ;;
  esac
done
agsec_json_signal_traps

# Must match install.sh's SMOKE_LABEL exactly, else the maintenance check can never pass.
LAUNCHD_LABEL="${AGENT_SECRETS_LAUNCHD_LABEL:-com.agent-secrets.smoke}"
had_bad=0
SUMMARY_HIDDEN=0    # count of optional rows suppressed under --summary (reported in the footer)
JSON_ROWS=()

# Wrap at SPACES ONLY. A token wider than $1 is emitted on its own line, whole — never split.
_wrap_words() {
  awk -v w="${1:-76}" '{
    line = ""
    n = split($0, t, " ")
    for (i = 1; i <= n; i++) {
      if (line == "")                                 { line = t[i] }
      else if (length(line) + 1 + length(t[i]) <= w)  { line = line " " t[i] }
      else                                            { print line; line = t[i] }
    }
    if (line != "") print line
  }'
}

# The ONE runnable thing that clears a row, on its own line, never wrapped — so it survives a
# drag-copy at any terminal width. Silent when the row has no action.
_row_cmd() { [ -n "${1:-}" ] && printf '    → %s\n' "$1"; return 0; }

# Emit one check result.  Args: category status(ok|attn|bad) name [detail] [tier(core|optional)]
# — names-only. `tier` (default core) drives --summary presentation ONLY: a healthy fresh install
# raises ~7 aspirational `attn` rows (canary/backup/discovery/hygiene/maintenance/supply-chain) that
# read as "broken" though exit is 0. --summary hides `optional` rows that are NOT `bad`, so the wizard
# ends on core custody/toolchain/store/injection status. It NEVER changes the exit code (had_bad is set
# before any display filter) and NEVER filters JSON (agents parse the full manifest) — presentation only.
_row() {
  local cat=$1 st=$2 name=$3 detail=${4:-} tier=${5:-core} cmd=${6:-}
  if [ "$st" = bad ]; then had_bad=1; fi
  if [ "$FORMAT" = json ]; then
    # JSON keeps the historical single-field shape: the command is appended to detail, so an agent
    # parsing the manifest sees exactly what it saw before this split existed.
    JSON_ROWS+=("$(printf '{"category":"%s","status":"%s","check":"%s","detail":"%s"}' \
      "$cat" "$st" "$(agsec_js "$name")" "$(agsec_js "${detail}${cmd:+ — run: $cmd}")")")
    return 0
  fi
  # --summary text filter: keep every ✗ and every core row; hide non-bad optional rows (count them).
  if [ "$SUMMARY" = 1 ] && [ "$st" != bad ] && [ "$tier" != core ]; then
    SUMMARY_HIDDEN=$((SUMMARY_HIDDEN + 1)); return 0
  fi
  # 80-column legibility (F5): word-wrap long rows, continuations indented under the text column.
  # Presentation ONLY — the JSON branch above already returned with the unwrapped detail, and the
  # wrap threshold leaves 2 columns for the status glyph prefix.
  #
  # `fold -s` was the wrapper here and it SPLITS A TOKEN that is longer than the width — a 116-column
  # store path came out across three lines, mid-word, so it could not be drag-copied (the thing a
  # path is FOR). _wrap_words breaks at spaces only and emits an over-long token whole, letting the
  # terminal soft-wrap it, which keeps a drag-copy intact and reflows on resize.
  local line="[$cat] $name${detail:+ — $detail}"
  if [ "${#line}" -le 78 ]; then
    case "$st" in
      ok)   agsec_ok   "$line" ;;
      attn) agsec_attn "$line" ;;
      bad)  agsec_bad  "$line" ;;
    esac
    _row_cmd "$cmd"
    return 0
  fi
  local _first=1 _chunk
  printf '%s\n' "$line" | _wrap_words 76 | { while IFS= read -r _chunk; do
    if [ "$_first" = 1 ]; then
      case "$st" in
        ok)   agsec_ok   "$_chunk" ;;
        attn) agsec_attn "$_chunk" ;;
        bad)  agsec_bad  "$_chunk" ;;
      esac
      _first=0
    else
      printf '    %s\n' "$_chunk"
    fi
  done; }
  _row_cmd "$cmd"
}

# Guarded value capture — contains a die-stub/absent-lib `exit` inside a subshell so doctor
# never crashes.  Args: VAR CMD...   sets VAR to stdout, returns CMD's exit code.
_try() {
  local __v=$1; shift; local __o
  if __o=$("$@" 2>/dev/null); then printf -v "$__v" '%s' "$__o"; return 0
  else local __r=$?; printf -v "$__v" '%s' "$__o"; return "$__r"; fi
}
# Guarded exit-code-only check (value discarded — never captured, never printed).
_guard() { ( "$@" ) >/dev/null 2>&1; }

check_custody() {
  local st
  if _try st kc_status; then
    case "$st" in
      primary)   _row custody ok   "keychain custody" "primary" ;;
      degraded*) _row custody attn "keychain custody" "file custody (works, not cached by macOS)" core "agent-secrets setup --keychain" ;;
      missing)   _row custody bad  "keychain custody" "missing" ;;
      *)         _row custody attn "keychain custody" "unknown state" ;;
    esac
  else
    _row custody bad "keychain custody" "unavailable (not set up)"
  fi
  # A recovery.key lingering on disk is a PRIVATE key that belongs offline (password manager / printed),
  # not on the same disk as the primary. setup removes it after the ceremony; a leftover means an
  # interrupted or declined ceremony (a hard kill the EXIT trap couldn't catch, or a user who deferred
  # saving it). Warn so it gets moved offline and deleted — names/paths only, never the key.
  if [ -f "$(agsec_config_dir)/recovery.key" ]; then
    # The old detail told the user to `rm` a 116-column path that the wrapper then broke across
    # three lines — unpastable, and an `rm` is a poor thing to hand a first-time user anyway.
    # `setup` already RESUMES this exact handoff (_key_ceremony's idempotent branch) and deletes the
    # file itself on a verified paste-back, so the action is one short, safe command.
    _row custody attn "recovery key on disk" "not yet saved off this Mac" core "agent-secrets setup"
  fi
}

check_toolchain() {  # age + sops present, and sops NEW ENOUGH for SOPS_AGE_KEY_CMD (feedback BLOCKER #4)
  local v
  if agsec_have age && agsec_have age-keygen; then _row toolchain ok "age" "present"
  else _row toolchain bad "age" "missing — re-run the installer (or install age)"; fi
  if agsec_have sops; then
    # `|| v=""` is load-bearing: this bare command-substitution runs under `set -euo pipefail`
    # with no _try/_guard wrapper, so a PRESENT-but-nonfunctional sops (EDR-blocked exec, wrong-arch
    # vendored binary, a non-sops shim) that exits nonzero — or a SIGPIPE from head -1 — would abort
    # doctor mid-check and, in --format=json, emit NO JSON, breaking the "doctor NEVER crashes"
    # contract on exactly the broken-toolchain case this check exists to diagnose. Empty v falls
    # through to the bad-row below.
    v="$(sops --version 2>/dev/null | head -1 | awk '{print $2}')" || v=""
    if [ -n "$v" ] && _deps_ver_ge "$v" "$DEPS_SOPS_MIN"; then
      _row toolchain ok "sops" "$v (SOPS_AGE_KEY_CMD supported)"
    else
      # THE feedback failure, named: an old sops silently ignores SOPS_AGE_KEY_CMD and the store reads
      # as "canary unreadable" with no clue why. Point straight at the cause + the fix.
      _row toolchain bad "sops" "${v:-unknown} < $DEPS_SOPS_MIN — lacks SOPS_AGE_KEY_CMD; store won't decrypt via the Keychain selector. Re-run the installer (vendors $DEPS_SOPS_VER) or: brew upgrade sops"
    fi
  else
    _row toolchain bad "sops" "missing — re-run the installer (or install sops >= $DEPS_SOPS_MIN)"
  fi
}

_scan_rotate() {  # manifest.toml rotate_by scan — names + days only, never values
  local mf; mf=$(agsec_manifest_toml)
  if [ ! -f "$mf" ]; then _row store attn "rotation scan" "no manifest" optional; return 0; fi
  local today line name rb due days dname flagged=0
  today=$(date +%s); name=""
  while IFS= read -r line; do
    case "$line" in
      *name*=*) name=$(printf '%s' "$line" | sed -E 's/.*=[[:space:]]*"?([^"]*)"?[[:space:]]*$/\1/') ;;
      *rotate_by*=*)
        rb=$(printf '%s' "$line" | sed -E 's/.*=[[:space:]]*"?([0-9-]+)"?.*/\1/')
        due=$(date -j -f %Y-%m-%d "$rb" +%s 2>/dev/null) || continue
        days=$(( (due - today) / 86400 ))
        if [ "$days" -le 14 ]; then
          dname=$name; if [ "$REDACT" = 1 ]; then dname=$(printf '%s' "$name" | agsec_digest); fi
          # A past rotate_by yields negative days; "in -30d" reads wrong — say "overdue by 30d".
          if [ "$days" -lt 0 ]; then _row store attn "rotation due" "$dname overdue by $(( -days ))d" optional
          else _row store attn "rotation due" "$dname in ${days}d" optional; fi
          flagged=1
        fi ;;
    esac
  done < "$mf"
  if [ "$flagged" = 0 ]; then _row store ok "rotation scan" "none due ≤14d" optional; fi
}

check_store() {
  local sf v; sf=$(agsec_store_file)
  if [ -f "$sf" ]; then _row store ok "store file" "present"; else _row store bad "store file" "absent"; fi
  if _try v store_extract "$AGENT_SECRETS_CANARY_NAME" && [ -n "$v" ]; then
    _row store ok "decrypt self-test" "canary readable"
    # Armed-canary status: comparing against the known placeholder constant leaks nothing. Both states
    # are `optional` — an unarmed decoy is a deliberate default, not a defect (P1-4: mark "(optional)").
    if [ "$v" = "$AGENT_SECRETS_CANARY_PLACEHOLDER" ]; then
      _row store attn "canary" "INERT decoy (optional) — no breach detection until armed" optional "agent-secrets add $AGENT_SECRETS_CANARY_NAME"
    else
      _row store ok "canary" "armed" optional
    fi
  else
    _row store bad "decrypt self-test" "canary unreadable"
  fi
  v=""
  # Placeholder-credential guard: the UNATTENDED wizard seeds ANTHROPIC_API_KEY with a known fake so
  # tests never hang. It is a NON-EMPTY value, so check_injection's apiKeyHelper "returns a credential"
  # passes and the install reads healthy while Claude would auth with a placeholder. Flag it (core, so it
  # survives --summary) with the exact fix. Comparing to the known constant is names-only. Guarded via
  # _try so an absent ANTHROPIC_API_KEY (the common case) is simply skipped.
  local pv
  if _try pv store_extract ANTHROPIC_API_KEY && [ "$pv" = "$AGENT_SECRETS_UNATTENDED_PLACEHOLDER" ]; then
    _row store attn "ANTHROPIC_API_KEY" "holds the unattended TEST placeholder — replace it" core "agent-secrets add ANTHROPIC_API_KEY"
  fi
  pv=""
  _scan_rotate
}

check_injection() {
  local bd w akh out; bd=$(agsec_bin_dir)
  for w in claude-agent cursor-agent; do
    if [ -x "$bd/$w" ]; then _row injection ok "wrapper" "$w executable"
    elif [ -e "$bd/$w" ]; then _row injection attn "wrapper" "$w not executable"
    else _row injection bad "wrapper" "$w missing"; fi
  done
  # Is ANTHROPIC_API_KEY in the store at all? (names-only: store_has greps a NAME.) Everything about
  # the helper hinges on it: Claude Code ranks apiKeyHelper ABOVE its own login and treats an empty
  # helper as a hard auth failure (lib/wire.sh), so with NO key stored the correct state is "helper
  # present, NOT wired, Claude Code on its own login" — an ⚠ next-step, never a ✗. With the key
  # stored, an empty helper or an unwired settings.json IS broken.
  # store_has: 0 stored, 1 not stored, 2 the store could not be decrypted. A decrypt failure is not
  # "not stored", so it gets its own ✗ row instead of the optional "no key stored" ⚠ rows below.
  local have_key=0 key_rc=0; _guard store_has ANTHROPIC_API_KEY || key_rc=$?
  if [ "$key_rc" = 0 ]; then have_key=1
  elif [ "$key_rc" = 2 ]; then
    _row store bad "store readable" "decrypt failed — check key custody" core "agent-secrets doctor --gates"
  fi
  akh="$bd/apiKeyHelper"
  if [ -x "$akh" ]; then
    if [ "$have_key" = 1 ]; then
      if _try out "$akh" && [ -n "$out" ]; then _row injection ok "apiKeyHelper" "returns credential"
      else _row injection bad "apiKeyHelper" "empty output"; fi
      out=""
    elif [ "$key_rc" != 2 ]; then
      _row injection attn "apiKeyHelper" "no ANTHROPIC_API_KEY stored (optional) — Claude Code uses its own login until you add one" optional "agent-secrets add ANTHROPIC_API_KEY"
    fi
  else
    _row injection bad "apiKeyHelper" "missing"
  fi
  # Verify Claude Code is actually WIRED to our helper. The wrapper being executable is not enough:
  # after an uninstall(keep)→reinstall, the returning-user fast path re-symlinks the wrapper but can
  # skip _wire_tools, leaving settings.json unwired while every row above reads ok. A DIFFERENT helper
  # is `attn` not `bad` — uninstall deliberately preserves a user's own pre-existing apiKeyHelper.
  local sj helper; sj="$(agsec_home)/.claude/settings.json"
  if agsec_have jq && [ -f "$sj" ]; then
    helper="$(jq -r '.apiKeyHelper // empty' "$sj" 2>/dev/null || true)"
    if [ "$helper" = "$akh" ]; then
      if [ "$have_key" = 1 ]; then _row injection ok "settings.json apiKeyHelper" "wired"
      else _row injection bad "settings.json apiKeyHelper" "wired but no ANTHROPIC_API_KEY stored — Claude Code auth will FAIL (empty helper); store the key or unwire" core "agent-secrets add ANTHROPIC_API_KEY"; fi
    elif [ -n "$helper" ]; then _row injection attn "settings.json apiKeyHelper" "points at a different helper (kept — your edit)"
    elif [ "$have_key" = 1 ]; then _row injection bad "settings.json apiKeyHelper" "not wired" core "agent-secrets setup"
    elif [ "$key_rc" != 2 ]; then _row injection attn "settings.json apiKeyHelper" "not wired — nothing to wire until ANTHROPIC_API_KEY is stored (add wires it)" optional "agent-secrets add ANTHROPIC_API_KEY"; fi
  elif [ "$have_key" = 1 ]; then
    _row injection attn "settings.json apiKeyHelper" "settings.json/jq unavailable"
  elif [ "$key_rc" != 2 ]; then
    _row injection attn "settings.json apiKeyHelper" "not wired — nothing to wire until ANTHROPIC_API_KEY is stored (add wires it)" optional "agent-secrets add ANTHROPIC_API_KEY"
  fi
}

check_backup() {  # is an off-machine second copy configured? (makes disaster recovery real, not a hope)
  local marker; marker="$(agsec_config_dir)/backup-repo"
  if [ -f "$marker" ] && [ -s "$marker" ]; then
    # First line only, control bytes dropped: the marker is user-editable and this lands in a terminal.
    _row backup ok "off-machine backup" "configured ($(head -n1 "$marker" | tr -d '[:cntrl:]'))" optional
  elif ! agsec_have_devtool git; then
    # backup stages the ciphertext in a git repo. On a Mac without Apple's developer tools,
    # /usr/bin/git is an inert stub that only offers to install them, so name the real first link.
    _row backup attn "off-machine backup" "none — needs git: run 'xcode-select --install' once, then agent-secrets backup" optional "xcode-select --install"
  elif agsec_have gh; then
    _row backup attn "off-machine backup" "none — run gh auth login if needed, then back up" optional "agent-secrets backup"
  else
    # backup's prerequisite chain is gh → gh auth login → backup. Name the missing first link and where
    # the brew-less install recipe lives (P1-5) instead of a bare "run: agent-secrets backup" that dies.
    _row backup attn "off-machine backup" "none — needs gh first (install recipe below), then gh auth login" optional "agent-secrets help onboarding"
  fi
}

check_onboarding() {  # service-readiness triage: the external CLIs the user configures next (gh/az).
  # ALL rows are `optional` tier → hidden by --summary (they are next-steps, never failures) but shown
  # in the full report, so `doctor` doubles as a "what's left to set up" view alongside `help onboarding`
  # (which carries the brew-less install recipes). az in particular is checked nowhere else.
  if agsec_have gh; then _row onboarding ok "gh (GitHub CLI)" "installed" optional "gh auth login"
  else _row onboarding attn "gh (GitHub CLI)" "not installed (optional; enables backup)" optional "agent-secrets help onboarding"; fi
  if agsec_have az; then _row onboarding ok "az (Azure CLI)" "installed" optional "az login"
  else _row onboarding attn "az (Azure CLI)" "not installed (optional)" optional "agent-secrets help onboarding"; fi
  # git is a genuine prerequisite for `backup`, and on a stock Mac `command -v git` lies about it.
  if agsec_have_devtool git; then _row onboarding ok "git" "usable" optional
  else _row onboarding attn "git" "placeholder only — Apple's developer tools are not installed" optional "xcode-select --install"; fi
}

check_discovery() {  # machine-wide agent-discovery surfaces (ADVISORY — makes agents AWARE, not enforced)
  # Iterate the surface registry (lib/discovery.sh). The flagship "claude" surface (Claude Code + VS
  # Code Copilot, ~/.claude/CLAUDE.md) is ALWAYS surfaced as an opt-in reminder even when its dir is
  # absent; other harnesses are reported only when actually present on this Mac. A TAMPERED block
  # (integrity-marker mismatch or hidden-Unicode payload) is a `bad` row — visible even under --summary
  # AND it flips doctor's exit code, because a hostile standing-order file is a security event, not a nag.
  local key line status label path
  for key in $AGSEC_DISCOVERY_KEYS; do
    line="$(agsec_discovery_status_key "$key" 2>/dev/null)" || continue
    status="$(printf '%s' "$line" | cut -f2)"; path="$(printf '%s' "$line" | cut -f3)"; label="$(printf '%s' "$line" | cut -f4)"
    if [ "$status" = not-applicable ]; then
      if [ "$key" = claude ]; then status=absent; else continue; fi
    fi
    case "$status" in
      in-sync)  _row discovery ok   "agent rules ($label)" "present — advisory, not enforced" optional ;;
      managed)  _row discovery ok   "agent rules ($label)" "org/MDM-managed — deployment is IT's job; the installer defers (writes nothing here)" optional ;;
      stale)    _row discovery attn "agent rules ($label)" "STALE (older version) — re-run the installer to refresh the rules" optional ;;
      tampered) _row discovery bad  "agent rules ($label)" "TAMPERED / hand-edited — content does not match its integrity marker (or carries hidden-Unicode); re-run the installer to restore, or inspect $path" ;;
      *)        _row discovery attn "agent rules ($label)" "not installed (opt-in — agents won't know agent-secrets exists); add them with: agent-secrets setup --discovery" optional ;;
    esac
  done
  # Cursor has NO global rules FILE (User Rules live in an opaque, cloud-synced settings DB), so the tool
  # can NEVER verify or auto-write it — clipboard-paste is the honest ceiling. Surface a PERMANENT
  # reminder so the Cursor gap stays visible (not just once in setup's scrollback); setup copies the
  # rules to the clipboard for a one-time paste into Settings > Rules > User Rules.
  _row discovery attn "agent rules (Cursor)" "manual, unverifiable — paste once into Settings > Rules > User Rules (setup copies them to your clipboard)" optional
}

check_hygiene() {
  local pd mode sj cpd; pd="$(agsec_home)/.claude/projects"
  if [ -d "$pd" ]; then
    mode=$(stat -f '%OLp' "$pd" 2>/dev/null || echo '???')
    if [ "$mode" = 700 ]; then _row hygiene ok "projects dir mode" "700" optional
    else
      _row hygiene attn "projects dir mode" "$mode (want 700)" optional
      if [ "$FIX" = 1 ] && chmod 700 "$pd" 2>/dev/null; then _row hygiene ok "projects dir mode" "fixed → 700" optional; fi
    fi
  else _row hygiene attn "projects dir" "absent" optional; fi
  sj="$(agsec_home)/.claude/settings.json"
  if [ -f "$sj" ] && agsec_have jq; then
    cpd=$(jq -r '.cleanupPeriodDays // empty' "$sj" 2>/dev/null || echo '')
    if [ -n "$cpd" ] && [ "$cpd" -le 14 ] 2>/dev/null; then _row hygiene ok "cleanupPeriodDays" "$cpd" optional
    elif [ -n "$cpd" ]; then _row hygiene attn "cleanupPeriodDays" "$cpd (want ≤14)" optional
    else _row hygiene attn "cleanupPeriodDays" "unset (want ≤14)" optional; fi
  else _row hygiene attn "cleanupPeriodDays" "settings.json/jq unavailable" optional; fi
}

check_maintenance() {
  if _guard launchctl list "$LAUNCHD_LABEL"; then _row maintenance ok "weekly smoke job" "loaded" optional
  else _row maintenance attn "weekly smoke job" "not loaded ($LAUNCHD_LABEL)" optional; fi
}

check_supply() {
  local val
  if agsec_have npm && _try val npm config get ignore-scripts && [ "$val" = true ]; then
    _row supply-chain ok "npm ignore-scripts" "true" optional
  else
    _row supply-chain attn "npm ignore-scripts" "not set (want true)" optional
    if [ "$FIX" = 1 ] && agsec_have npm && npm config set ignore-scripts true >/dev/null 2>&1; then
      _row supply-chain ok "npm ignore-scripts" "fixed → true" optional
    fi
  fi
}

check_gates() {  # execution gates (c)/(d)/(e) — (c) degradation is a note, never a block/error
  local st
  # Distinguish missing custody from the file-custody fallback (a virgin machine has NO file to fall
  # back TO — labeling it "degraded (file custody)" asserts a fallback that doesn't exist). Every
  # non-primary state stays `attn`: gate (c) is a note, never a block (do NOT copy check_custody's
  # `bad` for missing — a gate must not flip exit code).
  if _try st kc_status; then
    case "$st" in
      primary)   _row gate ok   "(c) keychain read" "primary" optional ;;
      degraded*) _row gate attn "(c) keychain read" "degraded (file custody)" optional ;;
      missing)   _row gate attn "(c) keychain read" "no key custody — run: agent-secrets setup" optional ;;
      *)         _row gate attn "(c) keychain read" "unknown state" optional ;;
    esac
  else
    _row gate attn "(c) keychain read" "unavailable (not set up)" optional
  fi
  if _guard store_exec -- true; then _row gate ok "(d) sops exec-env" "works" optional
  else _row gate attn "(d) sops exec-env" "unavailable (fallback: apiKeyHelper-only)" optional; fi
  # (e) egress: OUR process-scoped allowlist (the bound `run` applies) is primary; a system-wide
  # firewall app is reported as defense-in-depth. perl + the proxy script present ⇒ the bound can start.
  local ef; ef="$(egress_allow_file)"
  if egress_enabled && [ -x /usr/bin/perl ] && [ -f "$(egress_proxy_script)" ]; then
    _row gate ok "(e) egress allowlist" "active — $(egress_rule_count) rule(s); run bounds child HTTP(S) to them" optional
  elif [ -f "$ef" ]; then
    _row gate attn "(e) egress allowlist" "present but no rules — add hosts to $ef to bound run" optional
  else
    _row gate attn "(e) egress allowlist" "not configured — create $ef to bound where run can send data" optional
  fi
  if [ -d "/Applications/LuLu.app" ] || ls -d "/Applications/Little Snitch"*.app >/dev/null 2>&1; then
    _row gate ok "(e) egress firewall" "system-wide firewall app present (ruleset unverified) — extra layer" optional
  fi
}

run_checks() {
  check_custody
  check_toolchain
  check_store
  check_backup
  check_injection
  check_discovery
  check_hygiene
  check_maintenance
  check_supply
  check_onboarding
  if [ "$GATES" = 1 ]; then check_gates; fi
}

run_checks
# --summary footer: reassure that the hidden rows are optional hardening, not failures, and name the
# one command that shows them. Only when something was actually hidden; same stream as the rows.
if [ "$SUMMARY" = 1 ] && [ "$FORMAT" = text ] && [ "$SUMMARY_HIDDEN" -gt 0 ]; then
  printf '%s+%d optional check(s) hidden — full report: agent-secrets doctor%s\n' \
    "$C_DIM" "$SUMMARY_HIDDEN" "$C_RESET"
fi
if [ "$FORMAT" = json ]; then
  doc=""
  for row in ${JSON_ROWS[@]+"${JSON_ROWS[@]}"}; do doc="${doc:+$doc,}$row"; done
  # warnings (deprecations) is an extra key; agents read only checks and exit.
  printf '{"checks":[%s],"exit":%d%s}\n' "$doc" "$had_bad" \
    "${AGSEC_WARNINGS:+,\"warnings\":[$AGSEC_WARNINGS]}" | agsec_json_out
fi
exit "$had_bad"
