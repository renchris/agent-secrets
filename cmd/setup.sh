#!/usr/bin/env bash
# cmd/setup.sh — onboarding wizard. Six screens, numbered 1..6 from the wizard's OWN first
# screen (the installer's consent gate is the installer's, not step 1 of this).
#
# Three modes, one code path:
#   interactive  a human at a terminal (tty on stdin, or /dev/tty attachable): the prompts below.
#   headless     NO human to prompt — a coding-agent session (Claude Code / Cursor: the transcript is
#                secret-bearing) or no attachable terminal (ssh -T, cron, CI) — or `--headless`.
#                REAL keys, no prompts, and NO secret on any fd: keys are minted to files, the Keychain
#                takes its key over a pipe (kc_populate_stdin), a first secret comes only from the
#                caller's own environment (--import-env), and the output is names, paths and status.
#                This replaced the former agent-session REFUSAL (docs/plans/AGENT_ENTRYPOINT_HEADLESS.md
#                M2): the refusal guarded the clipboard and the hidden prompt, and headless has neither.
#   unattended   AGENT_SECRETS_UNATTENDED=1 — tests/CI with FAKE placeholder values. Unchanged.
# Idempotent: re-running never mints a second key. Names-only.
set -euo pipefail
. "${AGENT_SECRETS_LIB:?run via bin/agent-secrets}/common.sh"
# help guard — first, so `setup --help` self-documents in every mode
case "${1:-}" in -h|--help) . "$AGENT_SECRETS_LIB/help.sh"; agsec_help_render setup; exit 0 ;; esac
for _m in ui store keychain manifest restore wire discovery; do . "$AGENT_SECRETS_LIB/$_m.sh"; done

UNATTENDED="${AGENT_SECRETS_UNATTENDED:-}"
HEADLESS=""            # set by --headless, or auto-detected in main (no human to prompt)
HEADLESS_WHY=""        # the ONE reason headless was chosen, for the done screen
IMPORT_ENV=""          # --import-env NAME[,NAME…]: seed the store from the caller's own environment
DISCOVERY=""           # headless default 1 (write the machine-wide agent rules); --no-discovery → 0
FIRST_SECRET=""        # the NAME the interactive first-secret screen stored, for the no-prompt replay
STATE="$(agsec_wizard_state)"
_state() { mkdir -p "$(dirname "$STATE")"; printf '%s\n' "$1" >"$STATE"; }
# UNATTENDED answers every confirm YES (legacy test contract). HEADLESS answers with the DECLARED
# default — there is nobody to ask, so the safe answer is the one the prompt would have suggested.
_confirm() {
  [ -n "$UNATTENDED" ] && return 0
  if [ -n "$HEADLESS" ]; then [ "${2:-y}" = y ]; return; fi
  ui_confirm "$@"
}
# A human is present iff we are NOT headless/unattended — the one predicate every screen branches on.
_human() { [ -z "$UNATTENDED" ] && [ -z "$HEADLESS" ]; }

_preflight() {
  if agsec_have fdesetup && fdesetup status 2>/dev/null | grep -q On; then ui_ok "FileVault on"
  else ui_warn "FileVault off — enable it for at-rest protection (guided, not silent)"; fi
  if agsec_have age && agsec_have sops; then ui_ok "age + sops present"; else ui_warn "age/sops missing — the installer bootstraps them"; fi
  if agsec_have gh; then ui_ok "gh present (enables: agent-secrets backup)"; else ui_say "  gh not present (optional — install it to use: agent-secrets backup)"; fi
  # The don't-store-raw-tokens ladder (lib/ladder.sh's stance), surfaced in the UX: most services
  # authenticate with their own per-user login, which is safer than a long-lived token in the store.
  # Show it up front so the user configures GitHub/Azure the right way and reaches for `add` last.
  ui_say ""
  ui_say "Recommended order (prefer a CLI login over a raw token in the store):"
  ui_say "  1. gh auth login     — GitHub (also enables: agent-secrets backup)"
  ui_say "  2. az login          — Azure"
  ui_say "  3. agent-secrets add — only for keys that must live in env"
  ui_say "     (e.g. ANTHROPIC_API_KEY)"
  ui_say "  Install recipes for gh/az (brew-less):  agent-secrets help onboarding"
}

_key_ceremony() {
  local cfg; cfg="$(agsec_config_dir)"; mkdir -p "$cfg"; chmod 700 "$cfg" 2>/dev/null || true
  local kf pf; kf="$(agsec_age_key_file)"; pf="$(agsec_age_pub_file)"
  # Idempotency gates on the PRIVATE key ALONE — age.pub is a non-secret recipient we can always
  # re-derive. Requiring BOTH wedged setup permanently: with age.key present but age.pub missing
  # (an interrupt between the two keygens, or the user deleting the "non-secret" pubkey), the guard
  # fell through to `age-keygen -o`, which REFUSES to overwrite the existing key (exit 1); the
  # `2>/dev/null` hid the error and `set -e` aborted the wizard silently → permanent onboarding lockout.
  if [ -s "$kf" ]; then
    # NOTE: do NOT sweep a lingering recovery.key here. A recovery.key on disk means a previous
    # run's handoff never VERIFIED (interrupt, or the user kept it) — deleting it would destroy a
    # possibly-unsaved private key (the F2 loss). Instead, resume the verified handoff below.
    [ -s "$pf" ] || age-keygen -y "$kf" >"$pf"      # re-derive the public recipient when it's absent
    ui_ok "key already exists — not minting a second one"; kc_write_selector; store_init
    if [ -s "$cfg/recovery.key" ]; then
      if _human; then
        _two_key_model
        _recovery_handoff "$cfg/recovery.key"
      elif [ -n "$HEADLESS" ]; then
        _recovery_kept_note "$cfg/recovery.key"
      fi
    fi
    return 0
  fi
  if [ -f "$kf" ]; then rm -f "$kf"; fi             # clear a 0-byte/partial key from an interrupted mint (age-keygen -o is O_EXCL)
  # Strand guard: a store already present + no key = a restore scenario. Minting a NEW key here would
  # make that store permanently undecryptable — route the user to the restore path instead.
  if [ -s "$(agsec_store_file)" ]; then
    agsec_die "a store exists at $(agsec_store_file) but there is no key to decrypt it — run: agent-secrets setup --restore (paste your saved age key). Minting a new key would strand it."
  fi
  # _keygen suppresses age-keygen's "Public key: age1…" stderr banner on SUCCESS (two unlabelled
  # key lines printed before any explanation read as something the user must write down) while
  # replaying the FULL stderr on failure — the reason the old code refused a bare 2>/dev/null.
  _keygen() {
    local out
    if ! out="$(age-keygen -o "$1" 2>&1)"; then
      printf '%s\n' "$out" >&2
      agsec_die "could not generate a key at $1 — see the error above"
    fi
  }
  _keygen "$kf"; chmod 600 "$kf"
  age-keygen -y "$kf" >"$pf"
  # Same O_EXCL hardening as the primary key above: clear a stale/partial recovery.key so age-keygen -o
  # (which REFUSES to overwrite) can recreate it, and drop 2>/dev/null so a real keygen failure surfaces
  # instead of silently aborting the wizard under set -e (the exact wedge the primary key mint had).
  local rec="$cfg/recovery.key"; [ -f "$rec" ] && rm -f "$rec"   # clear a stale partial (primary absent ⇒ no live handoff pending)
  # Clipboard guard: an interrupt anywhere in the ceremony below — ^C at the macOS Keychain
  # double-prompt, SIGTERM, or a set -e/agsec_die death — must never leave key material on the
  # clipboard. The recovery PRIVATE key deliberately STAYS on disk on an interrupt (0600, beside
  # age.key): the pre-rebuild trap deleted it, which destroyed a possibly-unsaved key (F2's loss
  # class); now the next setup run resumes the verified handoff, and doctor reminds meanwhile.
  trap "command -v pbcopy >/dev/null 2>&1 && printf '' | pbcopy 2>/dev/null || true" EXIT
  _keygen "$rec"; age-keygen -y "$rec" >"$cfg/recovery.pub"
  kc_write_selector
  ui_ok "generated your two keys (the store encrypts to both)"
  if _human; then
    # The PRIMARY key needs NO save ceremony: it lives on this Mac (0600 file; Keychain populated
    # right after this ceremony) and the RECOVERY key covers the dead-Mac case. Pre-rebuild, the
    # primary ALSO transited the clipboard "for your password manager" plus a public-key echo-back
    # that verified nothing — two prompts deleted, one real verification below instead (F1/F2).
    _two_key_model
    _recovery_handoff "$rec"
  elif [ -n "$HEADLESS" ]; then
    # Nobody can save it off this Mac right now, so it stays where it is safe today — the 0600 file
    # (the same state a human's "n = later" leaves). Deleting it would destroy the only copy of the
    # dead-Mac key; doctor reminds, and a human proves the save later with a plain `setup`.
    _recovery_kept_note "$rec"
  else
    rm -f "$rec"       # UNATTENDED (tests/CI, fake store): no interactive handoff; keep recovery.pub only
  fi
  trap - EXIT                                  # ceremony done — disarm the clipboard guard
  store_init
}

# Headless: the recovery key is kept on disk; say where, and the one command that finishes the job.
_recovery_kept_note() {
  ui_say "RECOVERY key kept on this Mac (0600 file) — save it off-machine later:"
  ui_say "  $1"
  ui_say "  A human proves the save and clears the file with:  agent-secrets setup"
}

# The two-key mental model, stated BEFORE the user is asked to act on it (F6). One job each.
_two_key_model() {
  ui_say ""
  ui_say "You now have two keys, one job each:"
  ui_say "  PRIMARY  — decrypts day-to-day. Lives ON this Mac (file + Keychain)."
  ui_say "             Nothing for you to save; it dies with this Mac."
  ui_say "  RECOVERY — your way back in when this Mac is gone. Only useful OFF"
  ui_say "             this Mac (password manager / printed sheet), paired with"
  ui_say "             an off-machine store copy:  agent-secrets backup"
}

# RECOVERY-key handoff (F1+F2 rebuild). Invariants:
#   * The 0600 file at $1 is the AUTHORITATIVE copy and stays on disk until the user PROVES the
#     offline copy — so a screenshot, a stray Cmd-C, or an interrupt can never destroy the only
#     copy (the measured first-run loss). The clipboard is a CONVENIENCE copy, re-issuable at will.
#   * Deletion fires ONLY on a verified paste-back. Every verification read happens with a
#     freshly-SCRUBBED clipboard, so a match proves the key came from somewhere durable (the
#     password manager), not from the copy this wizard just issued — unlike the old public-key
#     echo-back, which verified nothing (F2).
#   * Two empty entries = keep the file and move on (doctor carries the reminder row). Names-only:
#     the key transits pbcopy and a hidden read; it is never echoed, logged, or put in argv.
_recovery_handoff() {
  local rec="$1" line try pasted was_empty
  line="$(grep -m1 '^AGE-SECRET-KEY-' "$rec" 2>/dev/null)" || true
  if [ -z "$line" ]; then ui_warn "recovery.key unreadable at $rec — leaving it in place"; return 0; fi
  ui_say ""
  ui_say "Your RECOVERY key is in a 0600 file on this Mac right now."
  ui_say "That is safe today. It is not safe against this Mac dying."
  ui_say "So: save one copy off this Mac — password manager, or paper."
  ui_say ""
  # An OPT-IN gate, default yes. Before this, the wizard demanded a verified paste-back from a
  # password manager the first-time user had not opened yet, so the common path was two hidden
  # prompts they could only fail, ending in a warning. Declining is now a first-class answer that
  # changes nothing about safety: the file stays, and doctor carries the reminder either way.
  if ! _confirm "Save it off this Mac now? (n = later, the file stays put)" y; then
    ui_say ""
    ui_say "Later it is — nothing is lost. The key stays in this file:"
    ui_say "  $rec"
    ui_say "When you have, run setup again to prove it and clear the file:"
    ui_say "  agent-secrets setup"
    return 0
  fi
  if agsec_have pbcopy; then
    printf '%s' "$line" | pbcopy
    ui_say ""
    ui_say "It is on your clipboard now — paste it where you keep it."
    ui_say "The file above stays until you prove the save, so losing the"
    ui_say "clipboard costs you nothing."
  else
    ui_say ""
    ui_say "Copy the AGE-SECRET-KEY line out of this file:"
    ui_say "  $rec"
    ui_say "It stays there until you prove the save."
  fi
  for try in 1 2; do
    agsec_have pbcopy && printf '' | pbcopy    # scrub: the paste-back must come from the SAVED copy
    ui_say ""
    ui_say "Clipboard cleared. Prove the save: copy the key from your password"
    ui_say "manager entry (not this screen) and paste it below."
    pasted="$(ui_read_secret 'RECOVERY key (from where you saved it)')"
    was_empty=0; [ -n "$pasted" ] || was_empty=1
    if [ "$pasted" = "$line" ]; then
      unset pasted
      ui_ok "recovery key verified saved — removing the on-disk copy (offline is its home)"
      rm -f "$rec"
      return 0
    fi
    unset pasted
    if [ "$try" -eq 1 ]; then
      if [ "$was_empty" -eq 1 ]; then ui_warn "nothing was pasted."; else ui_warn "that didn't match."; fi
      if agsec_have pbcopy; then
        printf '%s' "$line" | pbcopy
        ui_say "  It is back on your clipboard. Save it, then paste it once more."
        ui_say "  Press Enter on its own to stop and keep the file instead."
      else
        ui_say "  Copy it again from the file above, save it, then paste once more."
        ui_say "  Press Enter on its own to stop and keep the file instead."
      fi
    fi
  done
  agsec_have pbcopy && printf '' | pbcopy      # scrub — the file remains the retrievable copy
  ui_say ""
  ui_say "Not verified, so the key stays where it is safe — this file:"
  ui_say "  $rec"
  ui_say "Once it really is saved, run setup again to prove it and clear"
  ui_say "the file — no rush, and doctor will remind you meanwhile:"
  ui_say "  agent-secrets setup"
  return 0
}

# Interactive value entry with a forgiving ladder (F3): an EMPTY entry explains the likely
# cause (an empty/scrubbed clipboard — setup scrubs it after key steps, so the Cmd-V the
# wizard itself taught two screens earlier can paste nothing) and re-prompts ONCE; a second
# empty entry SKIPS the secret (store it later via `add`) instead of aborting; a store_add
# refusal (fail-closed stays) warns and continues. Screen [4/7] must always reach [5/7].
# rc: 0 = stored · 1 = not stored (already explained). Value stays in-process (names-only).
_read_secret_store() {
  local name="$1" prompt="${2:-Value for $1}" val
  val="$(ui_read_secret "$prompt")"
  if [ -z "$val" ]; then
    ui_warn "nothing was entered. If you pasted: the clipboard may be empty —"
    ui_say  "  setup scrubs it after key steps. Copy the value again and paste"
    ui_say  "  here, or press Enter once more to skip this secret."
    val="$(ui_read_secret "$prompt")"
  fi
  if [ -z "$val" ]; then
    ui_warn "skipped — store it anytime:  agent-secrets add $name"
    return 1
  fi
  if printf '%s' "$val" | store_add "$name"; then unset val; return 0; fi
  unset val
  ui_warn "could not store $name (see the error above) — setup continues;"
  ui_say  "  store it later with:  agent-secrets add $name"
  return 1
}

# Headless seed: import each NAME in $IMPORT_ENV that is present and NON-EMPTY in this process's own
# environment. The value moves ${!name} → pipe → store_add: never argv, never stdout, never a
# transcript (the agent's command names the VARIABLE, not the value — AGENTS.md golden rule 2).
# Absent/empty names are reported BY NAME and skipped. Nothing is read from stdin, so this can never
# hang on an agent's open-but-empty pipe. rc 0 always (a skipped import is not a failed setup).
_import_env() {
  local name stored=0 skipped=0
  [ -n "$IMPORT_ENV" ] || return 0
  for name in $(printf '%s' "$IMPORT_ENV" | tr ',' ' '); do
    [ -n "$name" ] || continue
    if [ -n "${!name:-}" ]; then
      if printf '%s' "${!name}" | store_add "$name"; then ui_ok "imported $name from the environment (value never shown)"; stored=$((stored + 1))
      else ui_warn "could not store $name (see the error above)"; fi
    else
      ui_warn "$name is not set in this environment — skipped (nothing was stored)"
      skipped=$((skipped + 1))
    fi
  done
  [ "$skipped" -eq 0 ] || ui_say "  Store a skipped one later: printf '%s' \"\$NAME\" | agent-secrets add NAME"
  return 0
}

_first_secret() {
  local name val
  if [ -n "$HEADLESS" ]; then
    if [ -n "$IMPORT_ENV" ]; then _import_env
    else
      ui_say "No secret stored yet (headless: nothing is read from a prompt)."
      ui_say "  From a variable you already hold:  printf '%s' \"\$NAME\" | agent-secrets add NAME"
      ui_say "  From a human, hidden prompt:       agent-secrets add NAME"
    fi
    return 0
  fi
  if [ -n "$UNATTENDED" ]; then
    name="${AGENT_SECRETS_SEED_NAME:-ANTHROPIC_API_KEY}"
    # Seed-value resolution that CANNOT hang (feedback BLOCKER #3): the old `val="$(cat)"` blocked on
    # `cat` forever when stdin was an OPEN-but-empty pipe (an agent session's inherited stdin never
    # sends EOF). Resolve in priority order, none of which blocks unboundedly:
    #   1. AGENT_SECRETS_SEED_VALUE env var (deterministic automation — no stdin plumbing needed)
    #   2. a single piped line, read with a BOUNDED timeout (works with or without a trailing newline;
    #      a 5s ceiling turns the old infinite hang into a fast fall-through)
    #   3. a fake placeholder (the test/CI default)
    if [ -n "${AGENT_SECRETS_SEED_VALUE:-}" ]; then
      val="$AGENT_SECRETS_SEED_VALUE"                 # set AND non-empty (an empty SEED_VALUE falls through)
    elif ! agsec_stdin_is_tty; then
      IFS= read -r -t 5 val 2>/dev/null || true      # val is set even on EOF-without-newline; timeout ⇒ empty
      [ -n "$val" ] || val="$AGENT_SECRETS_UNATTENDED_PLACEHOLDER"
    else
      val="$AGENT_SECRETS_UNATTENDED_PLACEHOLDER"
    fi
    [ -n "$val" ] || val="$AGENT_SECRETS_UNATTENDED_PLACEHOLDER"   # never feed store_add an empty value (it fail-closes)
    # Explicit die (not bare set -e) so an UNATTENDED seed failure stays a hard CI failure even
    # when the caller runs this screen inside an errexit-suppressed guard (see main).
    printf '%s' "$val" | store_add "$name" || agsec_die "unattended seed failed for $name — see the error above"
    unset val; ui_ok "stored $name"; return 0
  fi
  # ui_menu returns 1 on EOF or a 4th bad answer: a cancel, so nothing is stored under a name nobody chose.
  name="$(ui_menu 'Which secret first? (you can finish setup without one)' ANTHROPIC_API_KEY OPENAI_API_KEY 'custom' 'skip for now')" \
    || { ui_say "Skipped. Store one anytime:  agent-secrets add <NAME>"; return 0; }
  case "$name" in
    'skip for now') ui_say "Skipped — store one anytime:  agent-secrets add <NAME>"; return 0 ;;
  esac
  if [ "$name" = custom ]; then
    # Validate the name HERE with a re-prompt — pre-fix, a bad name reached store_add, whose
    # die aborted the whole wizard at [4/7] (the F3 failure class). EOF (Ctrl-D) skips.
    while :; do
      printf 'name: ' >&2
      if ! IFS= read -r name; then
        ui_warn "no name received — skipping; store one anytime:  agent-secrets add <NAME>"
        return 0
      fi
      case "$name" in
        '') ui_warn "enter a name (or Ctrl-D to skip this secret)" ;;
        [A-Za-z_]*[!A-Za-z0-9_]* | [!A-Za-z_]*)
          ui_warn "invalid name '$name' — letters, digits, underscore only"
          ui_say  "  (must start with a letter or _), e.g. CODA_API_TOKEN" ;;
        *) break ;;
      esac
    done
  fi
  if _read_secret_store "$name" "Value for $name"; then ui_ok "stored $name (value never shown)"; FIRST_SECRET="$name"; fi
}

# The breach canary is NOT offered here any more. It ships as an inert decoy, arming is opt-in, and
# the prompt was a default-`no` keystroke almost every first run spent on "Enter" — one touchpoint
# for no information. `doctor` carries the reminder with the exact command
# (`agent-secrets add $AGENT_SECRETS_CANARY_NAME`, value via the hidden prompt), which is the same
# path arming always took underneath.

_wire_tools() {
  local bindir; bindir="$(agsec_bin_dir)"; mkdir -p "$bindir"
  local w
  for w in claude-agent cursor-agent apiKeyHelper; do
    [ -f "$AGENT_SECRETS_ROOT/bin/$w" ] || continue
    # A pre-existing file or symlink at the target that is not our link is the USER'S own — `ln -sfn`
    # would clobber it and uninstall's `rm -f` on the `file` record would then finish the loss. Back it
    # up with an `edit` record so uninstall RESTORES it. The edit record is appended BEFORE the file
    # record: rollback is LIFO, so our symlink is removed first, then the user's entry restored. A
    # re-run keeps the backup while the entry is unchanged; a changed one refreshes it and keeps the
    # previous backup beside it (manifest_backup_user_target). If the backup fails, nothing is replaced.
    manifest_backup_user_target "$bindir/$w" "wrapper-$w.bak" >/dev/null \
      || agsec_die "could not back up your existing $bindir/$w — it was left as is; move it aside, then re-run: agent-secrets setup"
    # Symlink (not copy) so the wrapper follows the link back to its sibling lib/ under the install root.
    ln -sfn "$AGENT_SECRETS_ROOT/bin/$w" "$bindir/$w"
    manifest_record_file "$bindir/$w" >/dev/null 2>&1 || true
  done
  ui_ok "installed wrappers to $bindir"
  # The settings.json edit lives in lib/wire.sh and is CONDITIONAL on ANTHROPIC_API_KEY being in the
  # store — a wired helper with nothing to print breaks Claude Code's auth outright (M4). `add
  # ANTHROPIC_API_KEY` completes the wiring later. rc 1/2 are explained by the function; never fatal.
  agsec_wire_apikeyhelper || true
  ui_say "The Dock Cursor stays secret-free — use 'cursor-agent' for agent work."
}

# Machine-wide agent discovery (lib/discovery.sh): the advisory, reversible, integrity-marked rule
# block in every present harness's instruction file. The INTERACTIVE installer owns the informed
# opt-in prompt (each file named + the block previewed). Here: the headless default, and the
# standalone `setup --discovery` — the one-command later opt-in that used to be "re-run the installer".
# The plan (every file that WILL be written) is printed before the write, so a headless run is
# announced, never silent. An org/MDM-managed machine is deferred by the registry itself.
_discovery_screen() {
  # Render the rules against the PATH command (the ~/bin symlink), matching the installer's choice, so
  # the block a later `setup --discovery` writes is byte-identical to the installer's — not a second
  # variant pointing at the install-root dispatcher.
  if [ -z "${AGENT_SECRETS_BIN:-}" ] && [ -x "$(agsec_bin_dir)/agent-secrets" ]; then
    AGENT_SECRETS_BIN="$(agsec_bin_dir)/agent-secrets"; export AGENT_SECRETS_BIN
  fi
  local plan; plan="$(agsec_discovery_plan)"
  if [ -z "$plan" ]; then
    ui_say "No writable agent surfaces detected (or all are org/MDM-managed)."
    ui_say "  Machine-wide discovery skipped — nothing to write."
    return 0
  fi
  ui_say "Writing the agent-secrets rules (advisory, recorded in the manifest) into:"
  printf '%s\n' "$plan" | while IFS="$(printf '\t')" read -r _lbl _pth; do ui_say "  $_pth"; done
  local wrote; wrote="$(agsec_discovery_install_all)"
  if [ -n "$wrote" ]; then
    printf '%s\n' "$wrote" | while IFS= read -r _l; do ui_ok "aware: $_l"; done
  else
    ui_warn "nothing written (targets became unwritable)"
  fi
  ui_say "  Undo with uninstall; verify anytime with:  agent-secrets doctor"
}

_done_screen() {
  ui_title "You're set up"
  if [ -n "$HEADLESS" ]; then _done_screen_headless; return 0; fi
  ui_say "The 3 commands you'll use:"
  ui_say "  agent-secrets add <NAME>    — add a secret (value never shown)"
  ui_say "  agent-secrets run -- <cmd>  — run a command with secrets injected"
  ui_say "  agent-secrets doctor        — health check"
  ui_say "Off-machine backup:  agent-secrets backup   (doctor tracks it)."
  # No custody hint here. Screen [5/6]'s health check prints that row — with its own runnable
  # command — one screen above, and _kc_offer printed it again on decline. Saying it a third time
  # is noise, not handholding.
  # Next steps: gh/az are deliberately NOT vendored (different lifecycle) — point at the self-contained
  # in-product recipes so a user who needs GitHub/Azure isn't left hunting blog posts. `help onboarding`
  # is the SSOT (docs/ is not shipped in the tarball); POST_INSTALL.md is the web copy. (P0-1)
  ui_say ""
  ui_say "Next steps — GitHub / Azure / more keys (brew-less recipes):"
  ui_say "  agent-secrets help onboarding"
  # Cursor has no stable file-based global-rules path, so this is the one manual step left; hand the user
  # the exact text AND (P0-2) put it on the clipboard so it's a single paste, not a retype. Claude Code is
  # covered by the installer's opt-in ~/.claude/CLAUDE.md block. Single source: agsec_agent_rules (no drift).
  # The rule lines are 90-110 columns and are meant to be PASTED, so printing them breaks an
  # 80-column terminal and wrapping them would corrupt the paste. When the clipboard is available
  # we put them there and say so; only a machine without pbcopy sees the raw block.
  ui_say ""
  if agsec_have pbcopy && agsec_agent_rules | pbcopy 2>/dev/null; then
    ui_say "Using Cursor? Its agent rules are on your clipboard now."
    ui_say "Paste them into: Cursor Settings → Rules → User Rules."
    ui_say "(Claude Code reads the agent rules in ~/.claude/CLAUDE.md,"
    ui_say " if you added them.)"
  else
    ui_say "Using Cursor? Paste these into Settings → Rules → User Rules:"
    agsec_agent_rules | while IFS= read -r _rule; do ui_say "  $_rule"; done
  fi
  # Only after the prompting wizard: a restore's replay is not this command, and an unattended run
  # asked nothing.
  if _human && [ "${1:-}" != restore ]; then
    ui_say ""
    ui_say "Run this again without prompts:"
    ui_say "  $(_replay_cmd)"
  fi
  ui_say ""
  ui_say "Docs: https://github.com/renchris/agent-secrets"
}

# The prompt-free equivalent of the interactive run just finished. --no-discovery because the
# interactive wizard writes no machine-wide rules; --import-env names the stored secret, whose value
# the replay reads from the variable of that name, so no value is ever part of the command.
_replay_cmd() {  # [NAME=$FIRST_SECRET]
  local name="${1:-$FIRST_SECRET}"
  printf 'agent-secrets setup --headless --no-discovery%s\n' "${name:+ --import-env $name}"
}

# The headless done screen is written for the reader it has: an agent, or a log. It names the
# ABSOLUTE binary (the calling shell predates the ~/.zshenv PATH line, so a bare `agent-secrets`
# is "command not found" until a new shell), the one-line usage, and — only if any — the steps a
# human still owns. No clipboard: an agent must never overwrite the user's clipboard.
_done_screen_headless() {
  ui_say "Set up headless${HEADLESS_WHY:+ ($HEADLESS_WHY)}: keys, custody, store, wrappers."
  ui_say "This shell predates the PATH line — until a new shell, call it by path:"
  ui_say "  $(agsec_bin_dir)/agent-secrets"
  ui_say "The commands you'll use (names-only; a value is never printed):"
  ui_say "  agent-secrets list                       — what is stored"
  ui_say "  agent-secrets run -- <cmd>               — run with secrets injected"
  ui_say "  printf '%s' \"\$NAME\" | agent-secrets add NAME   — from a variable, never a literal"
  ui_say "  agent-secrets doctor                     — health (exit 0 = good)"
  local cfg; cfg="$(agsec_config_dir)"
  if [ -s "$cfg/recovery.key" ]; then
    ui_say ""
    ui_say "Left for a human (optional, whenever convenient):"
    ui_say "  save the RECOVERY key off this Mac — in a terminal:  agent-secrets setup"
  fi
  ui_say ""
  ui_say "Docs: https://github.com/renchris/agent-secrets  (AGENTS.md for agents)"
}

# Shared Keychain-populate core (the end-of-ceremony populate AND `setup --keychain`). Delegates to
# kc_populate_stdin (lib/keychain.sh): the key goes file → pipe → `security -i`, with no argv, no
# clipboard and no tty, so it works identically for a human, an agent and a cron job. rc: 0 = custody
# is primary afterward · 1 = the write ran but the read-back still falls to the file · 2 = the write
# failed (or no key on disk). The former clipboard + "paste it twice at an invisible prompt" path is
# gone: it copied the WHOLE key file (whose first line is a comment) into a one-line prompt.
_kc_populate() { kc_populate_stdin; }

# End-of-ceremony Keychain populate — no prompt. It used to ask "Populate your login Keychain now?"
# because saying yes cost the user two invisible pastes; now it costs nothing, and prompt-free primary
# custody is what every answer wanted. Skipped in UNATTENDED (tests keep file custody, the
# `setup --keychain` drill depends on it) and when already primary. A failed write is a warn, never
# a stop: file custody is fully supported and `setup --keychain` retries.
_kc_auto() {
  [ -n "$UNATTENDED" ] && return 0
  [ "$(kc_status 2>/dev/null || echo missing)" = primary ] && return 0
  local rc=0; _kc_populate || rc=$?
  case "$rc" in
    0) ui_ok "Keychain custody — primary (prompt-free reads)" ;;
    *) ui_warn "the Keychain write didn't take on this macOS — file custody"
       ui_say  "  remains (fully supported). Retry anytime:"
       ui_say  "  agent-secrets setup --keychain" ;;
  esac
}

# Re-run ONLY the Keychain populate step (v2 feedback R2). Restores PRIMARY (prompt-free Keychain)
# custody without re-running the whole wizard, via the shared _kc_populate core — in a terminal, an
# agent session, or a cron job alike (nothing here needs a tty).
_keychain_screen() {
  ui_title "agent-secrets setup --keychain"
  local kf; kf="$(agsec_age_key_file)"
  [ -s "$kf" ] || agsec_die "no key on this machine yet — run: agent-secrets setup"
  if [ "$(kc_status)" = primary ]; then
    ui_ok "Keychain custody is already primary — prompt-free reads work; nothing to do"
    return 0
  fi
  # `|| rc=$?` is load-bearing: _kc_populate returns 1/2 on a non-primary outcome, and a bare
  # `_kc_populate; rc=$?` would let set -e abort setup on that non-zero return BEFORE rc is read.
  local rc=0; _kc_populate || rc=$?
  case "$rc" in
    0) ui_ok "Keychain custody restored — primary (prompt-free reads)"; return 0 ;;
    1) ui_warn "the Keychain write succeeded but the read-back still falls to the file — file custody remains (fully supported); re-run to retry"; return 0 ;;
    *) agsec_die "Keychain populate did not complete — file custody remains in effect (fully supported); retry with: agent-secrets setup --keychain" ;;
  esac
}

# Disaster recovery on a new machine: re-establish key custody from the saved age key + a restored
# store copy, verify decryption, then re-wire the tools. Runs BEFORE any key mint (restore_flow +
# _key_ceremony's strand guard never let a fresh key clobber the restored store).
_restore_screen() {
  ui_title "agent-secrets restore"
  ui_say "Restoring on a new machine. First copy your backed-up encrypted store to:"
  ui_say "  $(agsec_store_file)"
  ui_say "then paste your saved age private key to re-establish custody."
  restore_flow || agsec_die "restore did not complete — see the message above (copy your store copy into place, then re-run: agent-secrets setup --restore)"
  _wire_tools
  _done_screen restore
}

# Validate an --import-env list: comma/space-separated env-var NAMES (a value never appears here).
# At least one name. The character check runs first because the list is split by an unquoted `for`,
# where a `*` or `?` would glob against the working directory.
_import_env_valid() {
  local n count=0
  case "$1" in *[!A-Za-z0-9_,\ ]*) return 1 ;; esac
  for n in $(printf '%s' "$1" | tr ',' ' '); do
    case "$n" in [!A-Za-z_]*) return 1 ;; esac
    count=$((count + 1))
  done
  [ "$count" -gt 0 ]
}

# The one place setup decides whether a human can be prompted (tests/install parity reads it).
# HEADLESS whenever there is nobody to prompt: a coding-agent session (its pty is transcript-captured,
# so a hidden prompt there is not hidden — M2), no terminal that could be attached (ssh -T, cron), an
# explicit non-interactive request (AGENT_SECRETS_NONINTERACTIVE=1 or CI), or a stderr that is not a
# terminal (every prompt is written there, so the human would answer prompts they cannot see). A human
# running `curl … | bash` has a pipe on stdin AND a real terminal, and is attached to it in main — that
# is what keeps the one-liner ONE command. UNATTENDED and --headless/--import-env were decided first.
setup_resolve_mode() {
  [ -z "$UNATTENDED" ] && [ -z "$HEADLESS" ] || return 0
  if agsec_in_agent_session; then HEADLESS=1; HEADLESS_WHY="coding-agent session"
  elif ! agsec_have_tty; then HEADLESS=1; HEADLESS_WHY="no terminal attached"
  elif agsec_noninteractive_requested; then HEADLESS=1; HEADLESS_WHY="non-interactive (--non-interactive or CI)"
  elif [ ! -t 2 ]; then HEADLESS=1; HEADLESS_WHY="stderr is not a terminal"
  fi
  return 0
}

main() {
  local do_restore=0 do_keychain=0 do_discovery=0 nodisc=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --restore)      do_restore=1 ;;
      --keychain)     do_keychain=1 ;;
      --discovery)    do_discovery=1 ;;
      --headless)     HEADLESS=1; HEADLESS_WHY="--headless" ;;
      --no-discovery) DISCOVERY=0; nodisc=1 ;;
      --import-env)
        # Never echo the token back: a value pasted where a NAME belongs would land in a transcript.
        [ -n "${2:-}" ] || agsec_die "--import-env needs <NAME>[,<NAME>…] (env-var names — never a value)" 2
        _import_env_valid "$2" || agsec_die "--import-env: bad NAME list (letters, digits, underscore; comma-separated)" 2
        IMPORT_ENV="$2"; HEADLESS="${HEADLESS:-1}"; HEADLESS_WHY="${HEADLESS_WHY:---import-env}"; shift ;;
      --import-env=*)
        _import_env_valid "${1#--import-env=}" || agsec_die "--import-env: bad NAME list (letters, digits, underscore; comma-separated)" 2
        IMPORT_ENV="${1#--import-env=}"; HEADLESS="${HEADLESS:-1}"; HEADLESS_WHY="${HEADLESS_WHY:---import-env}" ;;
      *) agsec_unknown_option setup "$1" ;;
    esac
    shift
  done
  # Each of these runs a single screen and returns, so a second one would be silently ignored.
  local f one=""
  for f in "--restore:$do_restore" "--keychain:$do_keychain" "--discovery:$do_discovery"; do
    [ "${f##*:}" = 1 ] || continue
    [ -z "$one" ] || agsec_die "setup: can't use $one with ${f%%:*} (each runs one step; run them separately)" 2
    one="${f%%:*}"
  done
  [ "$do_discovery" -eq 0 ] || [ "$nodisc" -eq 0 ] \
    || agsec_die "setup: can't use --discovery with --no-discovery (one writes the agent rules, the other opts out)" 2
  agsec_parse_only_exit
  setup_resolve_mode
  [ -n "$DISCOVERY" ] || { [ -n "$HEADLESS" ] && DISCOVERY=1 || DISCOVERY=0; }
  agsec_secure_umask
  # --keychain / --restore / --discovery are single screens; --restore reads piped stdin (the key).
  if [ "$do_keychain" -eq 1 ]; then _keychain_screen; return 0; fi
  if [ "$do_restore" -eq 1 ]; then _restore_screen; _state 'done'; return 0; fi
  if [ "$do_discovery" -eq 1 ]; then ui_title "agent-secrets setup --discovery"; _discovery_screen; return 0; fi
  if _human && ! agsec_stdin_is_tty; then
    agsec_attach_tty || agsec_die "setup: a terminal was detected but could not be attached — re-run in Terminal.app, or add --headless for a prompt-free setup"
  fi
  ui_title "agent-secrets setup${HEADLESS:+ (headless)}"
  case "$(restore_returning_user_check)" in
    installed) ui_say "agent-secrets is already set up."
      # Re-wire before the health check: after an uninstall(keep)→reinstall the wrappers are re-symlinked
      # but settings.json is NOT (that edit is owned by _wire_tools), so the fast path must re-wire or
      # Claude Code is left unwired while doctor reads healthy. _wire_tools is idempotent. A headless
      # --import-env on an installed machine imports, then reports — the natural "add these" one-liner.
      if _confirm "Run a health check instead of re-onboarding?" y; then
        _wire_tools; _import_env
        [ "$DISCOVERY" = 1 ] && _discovery_screen
        exec bash "$AGENT_SECRETS_CMD/doctor.sh" --summary
      fi ;;
    partial) ui_say "A previous setup was interrupted — continuing (idempotent; your key is kept)." ;;
  esac
  ui_step 1 6 "Preflight";        _preflight;      _state preflight
  ui_step 2 6 "Your keys";        _key_ceremony;   _kc_auto;    _state key
  ui_step 3 6 "Your first secret"
  # Guarded (F3): the first-secret screen is OPTIONAL onboarding — no failure here may strand
  # screens 4–6 (wrappers, apiKeyHelper, settings.json), which are what make the install work.
  # The || also suppresses errexit inside, so an unforeseen refusal degrades to a warn + skip.
  # UNATTENDED seed failures still hard-die inside _first_secret (explicit agsec_die).
  _first_secret || ui_warn "first secret not stored — add one anytime:  agent-secrets add <NAME>"
  _state secret
  ui_step 4 6 "Wire your tools";  _wire_tools
  [ "$DISCOVERY" = 1 ] && _discovery_screen
  _state wired
  # --summary so the wizard ends on core custody/toolchain/store/injection status instead of ~7 aspirational
  # ⚠ (canary/backup/discovery/hygiene/…) that read as "broken" though exit is 0. Full report: `doctor`.
  ui_step 5 6 "Health check";     bash "$AGENT_SECRETS_CMD/doctor.sh" --summary || true
  ui_step 6 6 "Done";             _done_screen;    _state 'done'
}
# Execute-only guard: `bash cmd/setup.sh` (the dispatcher) runs the wizard; SOURCING this file
# (the bats regression tests) only loads the screen functions for direct, deterministic testing.
case "${BASH_SOURCE[0]}" in "$0") main "$@" ;; esac
