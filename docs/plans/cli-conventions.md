# Remediation plan: agent-secrets (CLI design guidelines, vendor-neutral)

Inputs: 30 verified findings kept and 2 dropped (the JSON handed to this run), `/tmp/cli-bp/checklist.md`, `/tmp/cli-bp/guidelines.md`.
This plan is based on static reading only. No CLI was run and nothing in the repo was changed.
Line numbers refer to `main` @ `5266599`.
Round 2, pass 2 (§8) integrated 31 further verified install.sh findings. Rows it corrected carry "Pass 2 fix"; its new rows are in the "Round 2, pass 2" subsections.

---

## Phase 0: Agent team orchestration

This section was added because the plan-file hook asks for it. It restates §6 as an execution schedule.

**Execution locus per wave.** All three waves are **S**, the default: each wave runs as a dispatched handoff session with its own worktree, so the lead's context does not pay for implementation.

| Wave | Locus | Fire |
|---|---|---|
| A | S | `handoff-fire.sh --prompt-file <A-brief> --worktree cli-bp/wave-a --notify-back <lead-uuid> --goal 'A1 helpers in lib/common.sh+lib/ui.sh with tests/common.bats green — proven by the session printing the tail of: shellcheck (CI find form) && scripts/telemetry-gate.sh && bats -r tests; do not edit any cmd/*.sh, bin/*, or tag/release'` |
| B | S | `--worktree cli-bp/wave-b` (branched off merged wave-a). `--goal 'units B1..B8 committed, one commit each, all gates green — proven by printing git log --oneline main..HEAD plus the bats -r tests summary line; do not change any JSON shape or exit code beyond §3, or tag/release'` |
| C | S | Only after the operator answers D1-D8. `--worktree cli-bp/wave-c`. `--goal 'approved C units committed with callers updated in the same commit, all gates green — proven by printing git log --oneline main..HEAD plus the bats -r tests summary; do not implement any unapproved decision, bump VERSION, or tag/release'` |

**Team roster inside each wave session.**
- The roster is the units in §6, one teammate per unit.
- Wave B runs B2-B7 as parallel teammates, because their files are disjoint.
- Inside a wave the session lead may use T (teammates) because each unit's output is short (one commit plus a gate summary), and only the session's own context pays.
- Background subagents do research only; they make no code changes.

**Dependency graph.**
```
A1 → B1 → {B2, B3, B6, B7}; B4 and B5 can start right after A1. All B units → B8.
Then operator decisions D1-D8 → C4 → {C1, C2, C3, C5} → C6.
```

**Worktrees.**
- Create one worktree per wave under `/Users/chrisren/Development/.worktrees/`.
- Teammates commit sequentially inside it, in the order of the graph above.
- Nothing ever touches the main checkout.

**Lead context budget.**
- The orchestrating lead only fires the three handoffs, reads each `--notify-back` summary, and relays D1-D8 to the operator. Estimate under 15% of its context.
- Succession point: after Wave B merges. Hand Wave C off with the decision answers pasted into the brief.

**Round 2 addendum (schedule).** The rows above stay as written; these lines extend them.
- Wave A now has two units in one session: A1 (lib/common.sh), then A2 (lib/ui.sh, the shared test helpers, two mocks). A2 lands after A1.
- Wave B adds B9 (install.sh, compatible fixes) and B10 (the install.sh PTY suite). B9 uses no A1/A2 code, because install.sh cannot source lib/common.sh before it unpacks, but it needs A2's mock knobs. B10 lands after B9. The Wave B `--goal` reads `units B1..B10`.
- Wave C adds C7 (install.sh contract and presentation), which takes over C3's install.sh rows. The operator now answers D1-D16 (D9-D16 are new; D5, D6 and D7 gain sub-questions). Replace "D1-D8" with "D1-D16" in the Wave C brief and goal.
- Updated graph:
  ```
  A1 → A2 → B1 → {B2, B3, B6, B7}; B4, B5 and B9 start right after A2; B9 → B10. All B units → B8.
  Operator decisions D1-D16 → C4 → {C1, C2, C3, C5} → C7 (after C1) → C6.
  ```

**Round 2, pass 2 addendum (schedule).** The lines above stay; these extend them.
- install.sh's work no longer fits one unit under 500 LOC, and it cannot be split into several files because it runs before lib/ is unpacked (install.sh:108, :265). So it becomes a **serial track** inside Wave B: B9 → B11 → B12 → B13 → B10. Only one of these units holds install.sh at a time. Each owns its own test file, and no two run in parallel.
- B11 starts after B6, because its plan-versus-setup parity test needs B6.2 and B6.13. B13 starts after B5, because its restore test needs B5.12.
- Wave B's `--goal` reads `units B1..B13`. Wave C adds C8 (install.sh `--json`). The operator now answers D1-D26.
- Updated graph:
  ```
  A1 → A2 → B1 → {B2, B3, B6, B7}; B4, B5 and B9 start right after A2.
  B9 → B11 (also after B6) → B12 → B13 (also after B5) → B10. All B units → B8.
  Operator decisions D1-D26 → C4 → {C1, C2, C3, C5} → C7 (after C1) → C8 → C6.
  ```

---

## 1. Header

**Repo:** `/Users/chrisren/Development/agent-secrets`

**State at plan time (measured):**
- Branch `main`, `git status --porcelain` empty.
- `git worktree list` shows only the main checkout.
- So no file is dirty in another session, and nothing is off-limits.

**Repo rules:**
- There is no `CLAUDE.md` and no `.claude/CLAUDE.md` (measured with `ls`).
- The only rule file is `.claude/rules/agent-operating-lessons.md`. It says publishing a release (moving or force-pushing a tag, `gh release`) is **user-gated**. So no unit bumps `VERSION`, tags, or runs `scripts/release.sh`.
- Wave C changes contracts. Recommend releasing it as 0.2.0 (operator decision D8).

**Hard constraint: bash 3.2.**
- Shipped scripts run under macOS `/bin/bash` 3.2.57 (measured: `/bin/bash --version`). lib/deps.sh:62 and tests/install.bats:99 depend on this.
- Not available: `BASHPID`, `${x,,}`, associative arrays, `wait -n`, `mapfile`.
- `"${arr[@]}"` on an empty array aborts under `set -u`. Use `${arr[@]+"${arr[@]}"}` instead.

**CLIs covered:**
- `bin/agent-secrets` dispatcher. Verbs: setup, add, list|ls, run, doctor, uninstall, share, receive, pubkey, backup, hidden `smoke`, reserved rotate/demo, `help [<cmd>|onboarding|--json]`, top-level `--json`, `-V/--version`, `--plain/--no-color`.
- Wrappers: `bin/apiKeyHelper`, `bin/claude-agent`, `bin/cursor-agent`. They reach the CLI through `egress_run`, so the lib/egress.sh and lib/store.sh fixes cover them.
- `install.sh`, only where a Wave C fix has to update it as a caller. **Round 2:** install.sh is now audited as a CLI in its own right (18 verified findings). Compatible fixes are in B9 and B10; contract and presentation changes are in C7. **Pass 2:** 31 more verified findings on the same unit. Compatible fixes are in B9, B11, B12, B13 and B10; contract changes are in C7 and C8.

**Gates.** Run from the repo root before every commit. Sources: `.github/workflows/ci.yml` and README.md:433-436.
```sh
cd /Users/chrisren/Development/agent-secrets
find bin cmd lib scripts install.sh -type f ! -name '*.mjs' ! -name '*.pl' -print0 | xargs -0 shellcheck
scripts/telemetry-gate.sh
bats -r tests
# extra, cheap, not in CI:
for f in bin/agent-secrets bin/apiKeyHelper bin/claude-agent bin/cursor-agent cmd/*.sh lib/*.sh install.sh; do /bin/bash -n "$f" || echo "BASH32-PARSE-FAIL $f"; done
perl -c lib/egress-proxy.pl        # only for unit B1 (CI skips *.pl)
```

**Harness facts implementers need:**
- `tests/test_helper.bash` exports `AGENT_SECRETS_PLAIN=1 NO_COLOR=1 AGSEC_TEST_CONFIRM=1` and puts `tests/mocks` first on PATH. Mocks exist for: security, launchctl, gh, curl, osascript, pbcopy, pgrep, brew, fdesetup, ssh-keygen.
- Color tests must `unset AGENT_SECRETS_PLAIN NO_COLOR` and use a pty: `script -q /dev/null …`.
- Any file that uses `run --separate-stderr` needs `bats_require_minimum_version 1.5.0` at the top. No file has it today. Local bats is 1.13.0 (measured: `bats --version`).
- The `pgrep` mock shadows the real one. Process-survival assertions must use `ps -axo pid=,command=`.

**Landing flow:**
1. Work in a worktree branched off `main`, one branch per wave, e.g. `git -C /Users/chrisren/Development/agent-secrets worktree add /Users/chrisren/Development/.worktrees/agent-secrets-cli-bp -b cli-bp/wave-a main`. Branch wave-b off merged wave-a, and wave-c off merged wave-b.
2. Make one commit per implementer unit, in the repo's style (`fix(common): …`, `feat(run): …`), with all gates green.
3. Order: **A1 → B1 → {B2, B3, B4, B5, B6, B7 in parallel} → B8 → operator decisions → C4 → {C1, C2, C3, C5} → C6**.
4. Merge each wave as one PR, so `main` never carries help text that disagrees with the code (R023).

**Observed harness trap:** in this session, Bash commands whose text contained `bin/agent-secrets` were refused by a deny rule (both `wc` and `grep` on it). Implementers should open that file with the Read/Edit tools and exercise it only through `bats`.

**Round 2 gate additions.** Sources (measured): `.github/workflows/ci.yml`, README.md:433-437, `package.json`, `.gitignore:23`. The repo has no CLAUDE.md, so CI and the README Development section are the only gate sources.
- **Two CI steps were missing from the list above.** Run them too, from the repo root:
  ```sh
  for a in assets/demo.gif assets/hero.svg assets/demo.tape assets/diagrams/injection.mmd assets/diagrams/custody.mmd assets/diagrams/reversible.mmd; do [ -f "$a" ] || echo "MISSING $a"; done
  ! grep -RInE 'sk-ant-[A-Za-z0-9]{20}|AGE-SECRET-KEY-1[A-Z0-9]{20}' assets/
  ```
- **Diagrams need node_modules.**
  - README.md:437 says to run `npm install && npm run diagrams` after editing `assets/diagrams/*.mmd`.
  - `scripts/render-diagrams.mjs --check` also compares the README `mermaid-fence` blocks (README.md:191, 236, 281) with the `.mmd` sources.
  - `node_modules/` is gitignored, so a fresh worktree has none.
  - Any unit whose diff touches `assets/diagrams/` or a README fence block must run `[ -d node_modules ] || npm ci`, then `npm run diagrams:check`. C1 and C6 might, if they update the reversible-install diagram (alt text at README.md:275).
  - CI does not run this check today: README.md:437 says "CI fails on stale ones", but ci.yml has no such step. So a stale fence would land silently.
- **PTY suites must not pass by skipping.**
  - tests/wizard_interactive.bats:116 and :149, and tests/one_command.bats:110, call `skip` when `expect` is absent, and bats reports a skip as `ok`.
  - Before a unit that adds or changes an expect test (A2, B6, B9, B10, C7) reports green, run `command -v expect` and `bats --formatter tap tests/<file>.bats | grep -c '# skip'`. Report the count; it must be 0 for the files the unit touched.
- **Run the `bash -n` loop over every new file too:** `tests/mode_matrix.bash`, `tests/install_helper.bash`, `lib/help_search.sh`.
- **Keep install.sh:1-35 POSIX-clean** (install.sh:10). Everything above `set -euo pipefail` runs under a true `sh`, so it uses printf only: no `local`, no `[[`, no arrays.

**Round 2, pass 2 gate additions.** These are source traps the verdicts found while tracing callers. Every install.sh unit checks its diff against them.
- **Dry-run output must not contain `line ` before a later `: `.** tests/one_command.bats:48 fails on the glob `*"line "*": "*`. So plan copy never says "command line", "online " or "pipeline ".
- **Never print "real terminal"** (tests/install.bats:121 and :156).
- **Never write a second literal `EXPECTED_SHA256="…"`.** scripts/release.sh:72 and tests/install.bats:87 rewrite every such line with sed. Read `$EXPECTED_SHA256` instead.
- **No `DISCOVERY_MARKER=` literal** in install.sh (tests/discovery.bats:21), and no `gum` call (tests/one_command.bats:37).
- **No backticks inside a double-quoted `_say` string.** They would run the command while the plan renders.
- **No `&` in the replacement of `${x//pat/rep}`.** bash 5.2 and later treat it as the matched text (`patsub_replacement`, from memory of the bash docs, not measured here), and `bash install.sh` can run under Homebrew bash. Use `LC_ALL=C sed`.
- **EXIT traps stay shellcheck-clean.** Keep the SC2064 disable next to any `%q`-baked trap string (ci.yml:23 lints install.sh).

---

## 2. Wave A: shared helper (one module, lib/common.sh, plus its thin consumer lib/ui.sh)

These causes are shared by three or more findings. Fixing them here is the guide's "enforce the rules in shared code":

| Cause | Findings |
|---|---|
| Stdout/stderr discipline | receipts (F1), share receipt (F3), pubkey (F2), faint previews (F19), restore prompt (F26) |
| Mode resolution | decline/no-tty exits (F6), global `--non-interactive` (F16), scattered TTY checks (F18), backup prompt (F24), uninstall consent (F4), consent env var (F7) |
| Error rendering | JSON errors for list (F11) and doctor (F12), decrypt errors (F13), declines (F6), error format (F20) |
| Atomic write and lock | F22 (store.sh, keychain.sh, wire.sh, manifest.sh) |

**Unit A1** owns `lib/common.sh`, `lib/ui.sh`, `tests/common.bats` (new), and line 85 of `tests/store.bats`. About 300 LOC (estimated).

### Constraint
`install.sh:265` sources common.sh under `set -euo pipefail`, and tests/one_command.bats:52-60 sources it with `AGENT_SECRETS_LIB` unset under `set -u`. So:
- Every new top-level statement must be safe under set -e and set -u.
- Use `${VAR:-}` throughout.
- No bare call at top level may return non-zero.

### API

**A.1 Presentation per stream** (R115, R206, R116). About 35 LOC.
- `agsec_color_on FD`. Color is off when `AGENT_SECRETS_PLAIN` is set or `NO_COLOR` is non-empty. Otherwise `FORCE_COLOR`: `0` means off; any other non-empty value means on, except inside `agsec_in_agent_session`, so agent captures never get ANSI. Otherwise color is on when `[ -t FD ]` and `${TERM:-}` is not `dumb`.
- `agsec_in_agent_session` is defined at common.sh:158, but the palette block is at :80. Move the palette block below it.
- At source time, set the `C_*` palette from `agsec_color_on 1` (stdout, unchanged names). Add an `E_RESET E_DIM E_BOLD E_GREEN E_YELLOW E_RED E_BLUE` palette from `agsec_color_on 2`.
- Keep `agsec_use_plain` as `! agsec_color_on 1` for back-compat.
- `agsec_stdout_is_tty` returns `[ -t 1 ]`.
- `agsec_json_out` takes a JSON document on stdin. If jq is present it prints `jq .` when stdout is a TTY and `jq -c .` otherwise. Without jq it passes the input through, because doctor must never require jq.

**A.2 Status helpers by stream** (R016, R173, R177, R203). About 10 LOC.
- `agsec_ok`, `agsec_attn` and `agsec_bad` **stay on stdout**: doctor and smoke rows are those commands' results, and tests/onboarding.bats:25-26 pipe doctor's stdout into `grep -c '⚠'`.
- New `agsec_receipt`, `agsec_receipt_attn` and `agsec_receipt_bad`: the same glyphs, written to stderr with the `E_` palette.
- New `agsec_plan MSG`: normal foreground on stderr, for previews, consequences and prompts. Faint is reserved for optional metadata.
- `agsec_note`, `agsec_warn` and `agsec_die` switch from `C_*` to `E_*`.

**A.3 Errors** (R253, R255, R256, R260, R276, R280). About 70 LOC.
- `AGSEC_OUTPUT`: `text` by default or `json`.
- `agsec_scan_json "$@"` sets `AGSEC_OUTPUT=json` when `--json` or the legacy `--format=json` appears before `--`. Commands call it before parsing, so even usage errors come out in the right format.
  - **Round 2 fix (R438):** the space form `--format json` is not recognised anywhere. It does not exist today: list.sh:13-16 and doctor.sh:20-21 accept only the `=` forms. Recognising it would add a new `--format` spelling.
- `agsec_js STRING`: a pure-bash JSON string encoder. Escape `\` first, then `"`, `\n`, `\r`, `\t`, `\b`, `\f`; every other byte below 0x20, and 0x7f, becomes `\u00XX`. Doctor uses it, and so does the JSON error document, so neither needs jq.
- **One reason registry** `_agsec_reason REASON` maps each reason to an exit code and a status:

  | Reason | Exit | Status |
  |---|---|---|
  | `usage` | 2 | `error` |
  | `missing_input` | 2 | `action_required` |
  | `confirmation_required` | 2 | `action_required` |
  | `missing_command` | 2 | `error` |
  | `canceled` | 130 | `error` |
  | `undecryptable` | 1 | `error` |
  | `not_found` | 1 | `error` |
  | `conflict` | 1 | `error` |
  | `network` | 1 | `error` |
  | `partial` | 1 | `error` |
  | `error` | 1 | `error` |

- `agsec_fail REASON MSG [RECOVERY_CMD] [INSTRUCTION]` exits with the registry's code.
- The signature `agsec_die MSG [CODE] [RECOVERY_CMD] [INSTRUCTION]` keeps all ~110 existing calls working. The reason comes from `AGSEC_REASON` if the caller set it; otherwise code 2 means `usage`, 130 means `canceled`, and anything else means `error`.
- In JSON mode, write exactly one line to stderr and nothing to stdout: `{"status":…,"reason":…,"message":…[,"next":[{"command":…}]]}`. This is the guide's flat error-document shape at guidelines.md:799-822. It is **not** the `{"error":{…}}` wrapper some verdicts sketched.
- In text mode the first line is unchanged (`ERROR <msg>`; the format change waits for Wave C, F20). If a recovery command is given, follow it with a blank line, `<INSTRUCTION or "Run">:`, and the command indented 4 spaces.
- `agsec_canceled MSG` is `agsec_fail canceled …` (exit 130, R338).
- `agsec_need_confirmation WHAT FLAG CMD` is `agsec_fail confirmation_required "Can't WHAT without FLAG in non-interactive mode." CMD "Re-run with FLAG"` (exit 2; R014, R120, R124).

**A.4 Mode** (R113, R116, R408, R062). About 20 LOC.
- `agsec_stdin_is_tty` returns `[ -t 0 ]`. Use it only where stdin decides where a **payload** comes from.
- `agsec_noninteractive_requested` is true when `AGENT_SECRETS_NONINTERACTIVE=1` (exported by the dispatcher's `--non-interactive`, unit B7) or `CI` is non-empty.
- `agsec_noninteractive` is true when `agsec_noninteractive_requested`, `AGENT_SECRETS_UNATTENDED`, `AGSEC_OUTPUT=json`, or `agsec_in_agent_session` holds, or when `! { [ -t 0 ] && [ -t 2 ]; }`.
- `agsec_interactive` is `! agsec_noninteractive`.
- Non-interactive mode never grants consent.

**A.5 Atomic write and lock** (R351, R368, R319). About 50 LOC.
- `agsec_tmp_sibling TARGET` prints a fresh `mktemp "$(dirname T)/.$(basename T).XXXXXX"`.
- `agsec_commit TMP TARGET [MODE]` chmods the temp to MODE, or to the existing target's mode (`stat -f %Lp`). If TARGET is a symlink it writes through (`cat TMP >TARGET; rm TMP`, as `_manifest_replace` does); otherwise it runs `mv -f`. On any failure it removes TMP and returns 1.
- `agsec_atomic_write TARGET [MODE]` reads stdin into a sibling temp, then commits. **Use it only with producers that cannot fail** (printf). A fallible producer piped into it would commit truncated output. Fallible producers (jq, sops) write to `agsec_tmp_sibling` first and then call `agsec_commit`.
- `agsec_lock DIR [TIMEOUT_S=10]` / `agsec_unlock DIR`. The lock is a `mkdir` plus `DIR/pid`. Record the pid as `$(exec sh -c 'echo "$PPID"')`, which is correct inside subshells; bash 3.2 has no BASHPID. If the recorded pid is dead (`kill -0` fails), the lock is stale: remove it and retry. Poll every 0.1 s and return 1 at the timeout (R019, bounded). The caller picks the error message.

**A.6 Remote text** (R359, R298). About 8 LOC.
- `agsec_sanitize` is a stdin filter: `LC_ALL=C tr -d '\000-\010\013-\037\177'`, then `/usr/bin/perl -CS -pe 's/[\x{80}-\x{9f}\x{200b}-\x{200f}\x{202a}-\x{202e}\x{2066}-\x{2069}\x{feff}]//g'`.
- If perl is absent, apply the `tr` step only.

**A.7 One version source** (supports R086). About 6 LOC.
- `AGENT_SECRETS_VERSION` is read from `$AGSEC_SELF_ROOT/VERSION` with a guarded read: `{ IFS= read -r v || [ -n "$v" ]; } <file` and a literal fallback, so it is never empty and never trips set -e.
- `agsec_version()` prints `$AGENT_SECRETS_VERSION`, replacing the separate `cat VERSION` at common.sh:214. The help header, `help --json` and the rule-block integrity marker (common.sh:256, discovery.sh:227) can then no longer drift apart.

**A.8 lib/ui.sh.** About 8 LOC.
- `ui_title`, `ui_say` and `ui_step` (ui.sh:27-30) get `>&2` and the `E_` palette.
- `ui_ok`, `ui_warn` and `ui_bad` (:31-33) call `agsec_receipt`, `agsec_receipt_attn` and `agsec_receipt_bad`.
- The `ui_read_secret` hint (:70) goes from `C_DIM` to normal foreground.
- Do **not** touch `ui_menu` or `ui_read_secret`'s stdout: setup.sh:196, 235, 240 and 309 capture it.
- This single change fixes R016 for the whole setup wizard (139 ui_* calls), lib/wire.sh (12) and the lib/restore.sh prompt (:25, R136). Every in-repo test uses plain `run`, which merges both streams, and the PTY suites see both streams. So no assertion changes.

**A.9 Lint upkeep.**
- Add `agsec_receipt|agsec_receipt_attn|agsec_receipt_bad|agsec_plan|agsec_fail|agsec_canceled` to the redaction-lint regex at tests/store.bats:85.

**Out of scope:** a spec-driven argv parser (R063). It was not among the verified findings, so it is not planned.

### Tests (new file `tests/common.bats`, which declares `bats_require_minimum_version 1.5.0`)
- `@test "receipts go to stderr; ok/attn/bad stay on stdout"`: source common.sh, `run --separate-stderr agsec_receipt x`. Assert `[ -z "$output" ]`. Assert `agsec_ok x` puts `✓ x` in `$output`.
- `@test "stderr color follows stderr's TTY, not stdout's"`: unset PLAIN/NO_COLOR; `script -q /dev/null bash -c '. lib/common.sh; agsec_note hi 2>&1 >/dev/null'` contains `$'\e['`. With `2>file` and stdout on the pty, the file has no ESC.
- `@test "FORCE_COLOR colors a pipe; FORCE_COLOR=0, NO_COLOR, --plain and TERM=dumb turn it off"`.
- `@test "agsec_js escapes every control byte"`: `[ "$(agsec_js $'a\nb\tc\x01"\\')" = 'a\nb\tc\u0001\"\\' ]`.
- `@test "agsec_die in JSON mode: one line on stderr, empty stdout, reason from code"`. Status 2. `jq -e '.status=="error" and .reason=="usage" and .message=="bad thing"' <<<"$stderr"`, and the line count is 1.
- `@test "agsec_die with a recovery prints a blank line, the instruction and the 4-space command"`.
- `@test "agsec_canceled exits 130; agsec_need_confirmation exits 2 with status action_required"`.
- `@test "agsec_noninteractive: CI, AGENT_SECRETS_NONINTERACTIVE, agent session and no-tty each imply it; none grants consent"`.
- `@test "agsec_commit preserves mode and writes through a symlink"`. Assert that `[ -L link ]` still holds and that the target content changed.
- `@test "agsec_lock is exclusive, bounded, and steals a dead owner's lock"`. Assert that a second lock with timeout 1 returns 1 within ~1-2 s, and that a lock dir whose `pid` holds a dead pid is acquired.
- `@test "agsec_sanitize strips ESC, C1 and bidi controls"`.
- `@test "AGENT_SECRETS_VERSION, agsec_version and the VERSION file agree (set -u, AGENT_SECRETS_LIB unset)"`.
- `@test "ui_say/ui_title/ui_step write to stderr; ui_menu prints only the pick on stdout"`.
- `@test "lint: TTY and CI checks live only in lib/common.sh"`: `grep -nE '\[ !? ?-t [012] \]|\$\{?CI\b' cmd lib bin/apiKeyHelper bin/claude-agent bin/cursor-agent | grep -v '^lib/common.sh'` must be empty. **Ship it with `skip "enabled by B8"`**, because Wave B converts the last sites.

### Round 2 additions to Wave A

These rows come from the round-2 critic pass (`/tmp/cli-bp/critic2.json`). Each was checked against the code at `5266599`. To keep A1 under 500 LOC (§6), A.8 and the new A.10 (both `lib/ui.sh`) move to a new unit, A2.

**Unit A1, new rows** (`lib/common.sh`, `tests/common.bats`):

- **A.11 Error-document details round 1 left out** (R249, R257, R259, R261, R262). About 20 LOC.
  - **`next` entries.** Each becomes `{"command":…,"argv":[…]}`. `argv` is the recovery command split on spaces, so recovery commands passed to `agsec_fail` must be plain words with no quoting. Every recovery planned in §3 meets that.
  - **Warnings.** `agsec_warn_json REASON MSG` queues `{"reason","message"}` in `AGSEC_WARNINGS` instead of writing to stderr when `AGSEC_OUTPUT=json`.
    - JSON results that are objects merge a `warnings` array into the document: doctor, `--version --json`, `help search --json`.
    - The error document carries the warnings too (R261).
  - **Canceled document.** `agsec_json_signal_traps`: when `AGSEC_OUTPUT=json`, trap INT and TERM to write one `{"status":"error","reason":"canceled","message":…}` line to stderr, then exit 130 or 143 (R262). B2 (list) and B7 (doctor) call it after parsing.
  - **`retryable` (R259) is never emitted.** No JSON-mode failure in this plan is safely retryable: list and doctor fail on usage or on an undecryptable store. R250 says optional keys appear only when they apply, so leaving the key out is compliant.
  - **R263 is N/A here.** It covers `userActionRequired` and `data.effects`, and no destructive command has `--json`.
- **A.12 One wording for usage errors** (R060). About 10 LOC.
  - Verified (`grep -rn -i 'unknown flag\|unknown argument'`):
    - "unknown flag" appears at cmd/doctor.sh:27, cmd/receive.sh:27, cmd/share.sh:25 and lib/help.sh:52, 74, 101.
    - "unknown argument" appears at cmd/backup.sh:19, cmd/setup.sh:539, cmd/uninstall.sh:20 and install.sh:103.
    - R060 calls a named input an "option".
  - New helpers:
    - `agsec_unknown_option CMD TOKEN` runs `agsec_fail usage "Unknown option '$TOKEN' for $CMD." "agent-secrets $CMD --help" "See the options"` (exit 2).
    - `agsec_unexpected_argument CMD TOKEN` does the same for a surplus positional: "Unexpected argument '$TOKEN' for $CMD.".
    - **Pass 2 fix (R355, R018; recorded against R304 as E8).** Neither helper may echo a value.
      - `agsec_unknown_option` prints only `${TOKEN%%=*}`. A typo such as `--import-envv=sk-ant-…` must not put the value into a transcript.
      - `agsec_unexpected_argument` prints no token at all: "Unexpected argument for $CMD.". `add NAME sk-ant-…` is a plausible agent mistake.
      - Repo rule: names only in every output (SECURITY.md:186; tests/headless.bats:86 names a value on argv as the leak it guards).
  - Each Wave B owner switches its own sites (rows in "Round 2 additions to Wave B").
  - Two tests match the old word and change with their owners: tests/doctor.bats:42 (B7) and tests/receive.bats:88 (B3).
  - tests/dispatcher.bats:81 and :84 assert that "unknown flag" is absent. After the change they would pass vacuously, so B7 switches them to `unknown option`.
- **A.13 Parse-only seam** (R100). About 3 LOC.
  - `agsec_parse_only_exit` is `[ -z "${AGSEC_PARSE_ONLY:-}" ] || exit 0`.
  - Every cmd script calls it right after its parse loop and any flag-conflict check, and before it reads the store, attaches a TTY, prompts or writes. Each Wave B owner adds the call to its own files. B8.9 adds the test that feeds every help example through it.
  - The name follows the repo's existing internal prefix `AGSEC_` (about 19 such variables, e.g. AGSEC_TEST_CONFIRM). Whether internal variables move to `__AGENT_SECRETS_` (R079) is D15.
- **A.14 Deprecation warnings** (R308, R385). About 12 LOC.
  - `agsec_deprecated OLD NEW` prints `WARN OLD is deprecated; use NEW.` once per process, enforced by a guard variable.
  - It writes to stderr in text mode. In JSON mode it calls `agsec_warn_json deprecated …` instead, so stderr stays empty (R244).
  - Callers:
    - `--format=json` and `--format=text` (B2.4, B7.2);
    - `-V` (B7.11);
    - in Wave C, `--yes-i-reviewed` and the env-var consent (C2).
  - This replaces round 1's choice to keep `--format=json` silent (see the §5 round-2 notes).

Tests added to `tests/common.bats`:
- `@test "a JSON error document carries next[].command and next[].argv and no retryable key"`.
- `@test "agsec_unknown_option exits 2 and prints 'Unknown option' with the help command on its own line"`.
- `@test "agsec_parse_only_exit exits 0 only when AGSEC_PARSE_ONLY is set"`.
- `@test "agsec_deprecated prints once per run; in JSON mode stderr stays empty and the warning is queued"`.
- `@test "JSON mode: SIGTERM writes one canceled error document and exits 143"`.
- The round-1 test "ui_say/ui_title/ui_step write to stderr; ui_menu prints only the pick on stdout" moves to A2's `tests/ui.bats`.

**Unit A2 (new): lib/ui.sh, shared test helpers and mocks.**

Owns:
- `lib/ui.sh`;
- `tests/ui.bats` (new);
- `tests/mode_matrix.bash` (new);
- `tests/test_helper.bash`;
- `tests/mocks/curl`;
- `tests/mocks/launchctl`, for the bootstrap knob only.

Lands after A1. About 180 LOC (estimated).

- **A.8 moves here unchanged**: ui_* output goes to stderr with the E_ palette. It consumes A1's `agsec_receipt*` and `E_*`.
- **A.10 ui_menu and ui_confirm** (R013, R122, R131, R134, R228). About 30 LOC.
  - **Verified:** lib/ui.sh:60-62 maps any non-numeric or out-of-range answer, and EOF, to option 1. At cmd/setup.sh:309, option 1 is ANTHROPIC_API_KEY.
  - **The critic overstates it.** The fallback is not silent: the next prompt reads "Value for ANTHROPIC_API_KEY" (setup.sh:331 via `_read_secret_store`), and two empty entries skip. The real problem is that a mistyped `2x` still picks a secret the user did not choose. A value pasted next is then stored under that name and wired into apiKeyHelper. R013 forbids that fallback.
  - **New ui_menu contract:**
    - Enter still picks option 1, which stays marked `(default)`. one_command.bats:26-31 pins this.
    - Any other answer that is not a listed number prints `Enter a number from 1 to N.` on stderr and asks again, up to 3 times.
    - EOF, or a 4th bad answer, returns 1 with nothing on stdout. That is a cancel: R134 says EOF cancels.
    - Print `(Ctrl-D cancels)` on its own line above the existing `choose [1-N, Enter = 1]:` line, and keep that line's text exactly. The expect drives at wizard_interactive.bats:130 and :163 and one_command.bats:100 match `choose [1-4, Enter = 1]:` literally.
    - stdout still carries only the chosen option, which setup.sh:309 captures. B6.9 handles the return of 1.
  - **ui_confirm (ui.sh:38).** Every caller passes both a prompt and a default: setup.sh:171 and :568, and backup.sh:63 (measured with `grep -rn ui_confirm cmd lib`).
    - Make PROMPT required (`${1:?ui_confirm: PROMPT required}`) and make the default `n`.
    - This removes the vague `Continue?` (R228) and the default-yes fallback, and no caller changes.
- **A.15 Mode-matrix test helper** (R403, R404). About 60 LOC.
  - **Interface.** `tests/mode_matrix.bash` provides `mm_run MODE -- CMD…`. It sets `$mm_status`, `$mm_stdout` and `$mm_stderr`, plus `$mm_pty`, the pty transcript, in modes that have one.
  - **The 7 modes:**
    - `tty`: stdin, stdout and stderr are all a pty (`script -q`). Only the merged transcript exists.
    - `stdout-redirected`: stdin and stderr on the pty, stdout to a file.
    - `stdin-piped`: stdin from `MM_INPUT`, streams to files, no controlling terminal.
    - `json-tty`: `tty` plus the caller's `--json`.
    - `noninteractive-tty`: `tty` plus `AGENT_SECRETS_NONINTERACTIVE=1`. This is the variable B7.9's flag exports, so B3-B6 do not wait on B7.
    - `ci-tty`: `tty` plus `CI=1`.
    - `agent`: `CLAUDECODE=1`, stdin from `/dev/null`, no controlling terminal.
  - **Detach from the terminal.** Run the three no-terminal modes under `perl -MPOSIX -e 'POSIX::setsid() or die; exec @ARGV'` (perl ships with macOS) so there is no controlling terminal. Otherwise a local run would attach the developer's real terminal through `agsec_attach_tty` or install.sh:125-132 and hang.
  - **Environment.** Every mode unsets CLAUDECODE, CLAUDE_CODE, CURSOR_AGENT, CURSOR_TRACE_ID, TERM_PROGRAM and CI unless the mode sets them. The tty modes also unset the test seams AGSEC_TEST_CONFIRM and AGSEC_CONFIRM_SRC, so prompts read the pty.
  - **Styling check (R404).** `mm_styles CMD…` runs CMD with `FORCE_COLOR=1`, then with `NO_COLOR=1`, `TERM=dumb` and `--no-color`. It asserts that stripping ANSI from the first gives the others byte for byte, and that `--json` stdout has no ESC under `FORCE_COLOR=1`.
- **A.16 Keep GitHub Actions' CI=true from changing the suite** (new conflict found in round 2).
  - GitHub-hosted runners set `CI=true` for every step, and ci.yml runs `bats -r tests` there.
  - A.4 and B6.2 make a non-empty `CI` imply non-interactive. Nothing in the repo reads `CI` today (measured: `grep -rn 'CI:-\|\$CI' cmd lib bin install.sh tests` finds nothing).
  - After Wave B, the PTY wizard drives that spawn `agent-secrets setup` would therefore go headless in CI and desync: one_command.bats:96 and wizard_interactive.bats:119 and :152. Local gate runs would stay green.
  - Change: `unset CI` in `setup()` of tests/test_helper.bash. Tests that need CI set it explicitly, for example B6's "CI=1 setup on a terminal goes headless".
- **Mocks** (shared by B3, B4 and B9, so they land before Wave B):
  - `tests/mocks/curl` gains two knobs:
    - `AGSEC_MOCK_CURL_LOG=<file>` appends one line per call with every argument;
    - `AGSEC_MOCK_CURL_EXIT=<n>` exits n before doing anything (28 is a timeout, 6 a DNS failure).
  - `AGSEC_MOCK_CURL_SLEEP=<s>` sleeps first, for B9's signal test.
  - Round-1 B3 already assumes "the curl mock logs its calls", but no unit owned the mock. This closes that gap.
  - `tests/mocks/launchctl`: `AGSEC_MOCK_LAUNCHCTL_BOOTSTRAP_FAIL=1` makes `bootstrap` exit 5 without writing `loaded` (B9.10 needs it). B5 keeps its own round-1 change to `bootout` and must keep this knob.

Tests (`tests/ui.bats`, new, `bats_require_minimum_version 1.5.0`):
- `@test "ui_menu: '9' then '2' picks option 2 and says 'Enter a number from 1 to 2'"`.
- `@test "ui_menu: EOF returns 1 with empty stdout"` and `@test "ui_menu: four bad answers return 1"`.
- `@test "ui_menu: Enter still picks option 1 and the choose line is unchanged"`. The one_command.bats:26 case also stays.
- `@test "ui_confirm without a prompt is a programming error; omitted default is n"`.
- The A.8 stream test moved from A1.
- `@test "mode_matrix: each mode reports the TTY state it promises"`: in every mode, run `sh -c 'for f in 0 1 2; do [ -t $f ] && echo T || echo F; done; [ -e /dev/tty ] && (exec 3</dev/tty) 2>/dev/null && echo CTTY || echo NOCTTY'`.
- `@test "curl mock logs calls and honours AGSEC_MOCK_CURL_EXIT"`.
- `@test "test_helper unsets CI"`.

### Round 2, pass 2 additions to Wave A

**Unit A1** (`lib/common.sh`, `tests/common.bats`). About 10 LOC more.
- **A.12 fix** above: the two usage helpers never echo a value.
- **Test:** `@test "usage helpers never echo a value"`: `agsec_unknown_option list --foo=SEKRET` and `agsec_unexpected_argument add SEKRET` each exit 2 with no `SEKRET` in either stream.

**Unit A2** (`tests/mode_matrix.bash`, `tests/mocks/curl`, `tests/mocks/launchctl`). About 15 LOC more. These are shared by B9-B13, so they land before Wave B.
- **`mm_no_ctty CMD…`** in tests/mode_matrix.bash exposes A.15's setsid detach as its own helper. It runs CMD with no controlling terminal. B10.5 wraps the non-TTY install tests in it.
- **`AGSEC_MOCK_CURL_RETRY_NOTE=1`** makes the curl mock print `Warning: Problem : timeout. Will retry...` to stderr before serving the file. B12.1's retry-notice test needs it. The real curl prints that line only without `-s` (verifier measured with curl 8.7.1).
- **`launchctl list` under the failure knob.**
  - With `AGSEC_MOCK_LAUNCHCTL_BOOTSTRAP_FAIL=1`, `list` exits 113. B12.4 falls back to `launchctl list`, and the mock's catch-all `exit 0` would hide the failure.
  - Only the knob changes `list`. Doctor's maintenance row (cmd/doctor.sh:346) still sees exit 0 in every other test. So tests/onboarding.bats:25-26, which counts ⚠ rows, does not shift.
- **Tests** (tests/ui.bats): `mm_no_ctty` reports `NOCTTY`, and both new knobs behave as described.

---

## 3. Wave B: compatible fixes, grouped by file (one owner per file)

All verdicts here are `compatible`: no caller parses the changed output or branches on the changed exit code. The caller censuses are in the input JSON.
**B1 lands first.** It defines the `store_has`/`store_names` 0/1/2 contract and `agsec_die_undecryptable`, which B2, B3, B6 and B7 consume. **B8 lands last.** It owns every help row and document, and un-skips the lint.
**Round 2:** every unit also has rows under "Round 2 additions to Wave B" at the end of this section, so implementers must read both. B9 and B10 (install.sh) are new units there. **Pass 2:** the "Round 2, pass 2" subsection after B10 adds rows to B4-B8, splits install.sh into B9, B11, B12, B13 and B10, and says which unit owns each B9.x row.

### B1: store core and the run child contract
Files: `lib/store.sh`, `lib/egress.sh`, `lib/egress-proxy.pl`, `lib/keychain.sh`, `cmd/run.sh`, `tests/egress.bats`, `tests/foundation.bats`.

- **B1.1 Decrypt failure is not "empty"** (R017, R194, R275, R197). lib/store.sh:190-191.
  - `store_names`:
    - Return 1 when `[ ! -f "$(agsec_store_file)" ]`. A missing store still counts as absent; share and receive call this before any secret exists.
    - Otherwise run `_store_decrypt 2>/dev/null | sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\)=.*/\1/p'` and capture `s=("${PIPESTATUS[@]}")` right away. If `s[0]` is non-zero, return 2.
    - sed reads all its input, so there is no SIGPIPE ambiguity.
    - Values never land in a shell variable. Show sops's stderr only when `AGENT_SECRETS_DEBUG=1`.
  - `store_has NAME`: `hit="$(store_names)" || return $?; printf '%s\n' "$hit" | grep -qx -- "$1"`.
  - New `agsec_die_undecryptable` in store.sh: `agsec_fail undecryptable "Couldn't decrypt the store at $(agsec_store_file)." "agent-secrets doctor" "Check key custody"`.
  - store.sh:224 `store_canary_insert`: rc 0 returns 0; rc 2 returns 2 instead of falling through to `store_add`.
- **B1.2 Locked, atomic store writes** (R351, R368, R319). lib/store.sh:97-110.
  - Replace the fixed `"$store.new"` with `new="$(agsec_tmp_sibling "$store")"`.
  - Wrap decrypt → encrypt → `agsec_commit "$new" "$store" 600` → `_store_manifest_upsert` in `agsec_lock "$(agsec_config_dir)/.store.lock" 10`. On timeout: `agsec_fail conflict "Couldn't lock the store: another agent-secrets process is writing it." "agent-secrets add $name" "Retry"`.
  - Take the same lock in `store_manifest_set_sharing` (:139-178) and `store_manifest_purge_sharing` (:183-188).
  - store_init's `.sops.yaml` write (:56) becomes `agsec_atomic_write … 600`.
- **B1.3 Signal-correct exits in store_add** (R335, R337). lib/store.sh:100.
  - Split the trap into three, each shredding `"$plain" "$plain.f" "$new"` and unlocking: `exit 130` on INT, `exit 143` on TERM, and `exit 129` on HUP (new; HUP between decrypt and shred currently strands plaintext).
  - Reset with `trap - INT TERM HUP` (:109).
- **B1.4 argv stays an array** (R360). lib/store.sh:207 and :218.
  - Replace `printf -v cmd '%q '` with `_store_shquote`, a POSIX single-quote quoter built from **parameter expansion** (`a=${a//\'/\'\\\'\'}`). Do not use `$(sed)`: command substitution strips an argument's trailing newlines.
  - The command string becomes `cmd="exec $quoted"`.
- **B1.5 No sops process left in between** (R362, R364).
  - `store_exec` becomes `exec sops exec-env --same-process "$(agsec_store_file)" "$cmd"`. The pinned sops is ≥ 3.10.0 (deps.sh:34), and `--same-process` needs ≥ 3.8.0.
  - `store_exec_managed` starts the same command in the background **with `<&0`**. bash points a background job's stdin at /dev/null unless stdin is redirected explicitly, and claude-agent needs the TTY. It stores `AGSEC_CHILD_PID=$!`, which is the child itself after the two execs.
- **B1.6 missing_command before launch** (R361). lib/egress.sh:83-84, right after the `--` shift.
  - Add `command -v "$1" >/dev/null 2>&1 || agsec_fail missing_command "Can't run $1: command not found."` (exit 2).
  - This one place covers `run` and both wrappers. doctor.sh:378 `store_exec -- true` is unaffected.
- **B1.7 Forward signals in managed mode** (R362, R364). lib/egress.sh:103-107.
  - TERM and HUP: `kill -s SIG "$AGSEC_CHILD_PID"`.
  - INT: do **not** forward. The terminal already delivered it to the shared foreground process group, and a second INT makes TUIs like claude quit.
  - Loop `wait "$pid"` while `kill -0` succeeds. Once a signal has been forwarded, bound the wait to 10 s, then `kill -KILL`.
  - Run a final `wait "$pid"` to collect the child's real status; a signal death already reads as 128+n. Then `_egress_reap` and `exit "$rc"`. Keep the EXIT reap trap as a backstop.
- **B1.8 Proxy timeouts** (R313, R019). lib/egress-proxy.pl.
  - Add `Timeout => 10` to both `IO::Socket::INET->new` calls (:131, :142).
  - In `read_head` (:112-121), wrap the loop in `eval { local $SIG{ALRM}=sub{die "head timeout\n"}; alarm 30; …; alarm 0 }` and return `()` on timeout, which leads to the existing refuse path.
  - Do **not** add an idle timeout to `relay()`: CONNECT tunnels are legitimately long-lived (SSE).
- **B1.9 age.key and the selector written atomically** (R351). lib/keychain.sh.
  - :48 becomes `printf '%s' "$key" | agsec_atomic_write "$f" 600`.
  - :67 (the selector) becomes `{ …; } | agsec_atomic_write "$path" 700`. Both producers are printf, so they cannot fail.
- **B1.10 `--no-egress` in any position** (R064, R066), optional. cmd/run.sh:14-16.
  - Loop until `--`: accept `--no-egress`; any other token exits 2 with the **unchanged** usage text, which tests/store.bats:74-76 and flows.bats:65 match.

Tests:
- tests/egress.bats:
  - `@test "run passes a child's exit 42 through"`: `run agsec run -- sh -c 'exit 42'`; `[ "$status" -eq 42 ]`.
  - `@test "run keeps argv intact (space, newline, single quote)"`: `run agsec run -- sh -c 'printf "[%s]" "$@"' sh 'a b' $'x\ny' "it's"`; `[ "$output" = "[a b][x"$'\n'"y][it's]" ]`.
  - `@test "run with a missing command exits 2 before launch"`: status 2 and "command not found".
  - `@test "egress-bound run: SIGTERM to the wrapper exits 143 and leaves no child or proxy"`: allowlist with one host; `agsec run -- sleep 30 &`; `kill -TERM` the wrapper; `wait` gives 143; `ps -axo command=` contains no `sleep 30` and no `egress-proxy.pl`.
  - `@test "store_exec -- true still succeeds (doctor gate d)"`.
- tests/foundation.bats:
  - `@test "two concurrent store_add calls keep both names"`: two background `printf v | store_add A` / `store_add B` and `wait`; `store_names` lists both.
  - `@test "store_names returns 2 with empty output when the store can't be decrypted"`: replace age.key with a fresh `age-keygen` key; status 2.
- `perl -c lib/egress-proxy.pl`; the existing audit_regressions.bats:117-126 relay checks stay green.

### B2: add, list, pubkey
Files: `cmd/add.sh`, `cmd/list.sh`, `cmd/pubkey.sh`, `tests/store.bats` (from line 85 onward it belongs to this unit after A1), `tests/pubkey.bats`.

- **B2.1** (R064, R066). cmd/add.sh:14-15.
  - Use an argument loop: exactly one positional NAME.
  - **Round 2 fix (R060):** a `-*` token gives `agsec_unknown_option add "$arg"`, and a second positional gives `agsec_unexpected_argument add "$arg"`. Both exit 2 (A.12).
  - Keep the existing missing-NAME usage text.
- **B2.2** (R016, R173, R021). cmd/add.sh:34.
  - `agsec_receipt "stored $name (value never shown or logged)"`.
  - As the **last** line of the script (after the ANTHROPIC_API_KEY wiring block), `printf '%s\n' "$name"`.
- **B2.3** (R116, R408). cmd/add.sh:29.
  - `[ -t 0 ]` becomes `agsec_stdin_is_tty`.
  - **Not** `agsec_interactive`: with CI=1 or stderr redirected on a terminal, the secret would be read from the terminal with echo on.
- **B2.4** (R438, R066, R009, R064, R253). cmd/list.sh:12-17.
  - Call `agsec_scan_json "$@"` first.
  - Loop over all arguments. `--json` selects JSON. `--` ends parsing. Anything else exits 2 via `agsec_unknown_option list`.
  - **Round 2 fix (R438, R385, R308):**
    - Only the two spellings that exist today stay, as hidden deprecated aliases: `--format=json` and `--format=text` (list.sh:14-15).
    - The space forms `--format json` and `--format text` are **not** added. They keep exiting 2, as they do today.
    - Each alias calls `agsec_deprecated --format=json --json` (A.14). In text mode that is one stderr line. In JSON mode stderr stays empty, because list's bare array has no `warnings` slot until C5.
    - Help does not list either alias.
- **B2.5** (R251). cmd/list.sh:40: `} | jq -s '.'` becomes `} | jq -cs '.' | agsec_json_out`. The output is pretty on a TTY and compact when piped. The shape is unchanged until Wave C (C5).
- **B2.6** (R017, R275). cmd/list.sh:29: `names="$(store_names)" || agsec_die_undecryptable`.
  - The failure path exits 1 with empty stdout; in JSON mode it writes the single-line error document.
  - The missing-store `[]` / "no secrets yet" branch at :24-27 is unchanged.
  - Caller check: claude-infrastructure/hooks/lib/jev.sh:111 (`list | grep -q`, no pipefail) and AGENTS.md:121 (`jq -e`) both still read empty stdout as "absent".
- **B2.7** (R274, R016). cmd/pubkey.sh:24-26.
  - :25 becomes `printf '%s\n' "$recip"`: no indent, and the only thing on stdout.
  - The :24 heading goes to `>&2` with `E_BOLD`.
  - :26 becomes `agsec_plan "fingerprint: $fp"`. Normal foreground: a fingerprint is an ID, and R203 says IDs are never faint.
- **B2.8** (R064). cmd/pubkey.sh:10-15.
  - Loop: accept only `--copy`. Keep the undocumented `-` arm for one release with `agsec_warn "pubkey: '-' is ignored and will be rejected in a future release"`. Anything else exits 2.

Tests:
- tests/store.bats (add `bats_require_minimum_version 1.5.0`):
  - `@test "add prints only NAME on stdout; the receipt goes to stderr"`: `run --separate-stderr bash -c "printf v | bash '$REPO_ROOT/bin/agent-secrets' add MY_KEY"`; `[ "$output" = MY_KEY ]`; `[[ "$stderr" == *"stored MY_KEY"* ]]`.
  - `@test "add NAME junk exits 2 and stores nothing"`.
  - `@test "list --json is compact when piped and leaves stderr empty"`: one line, `jq -e 'type=="array"'`, `[ -z "$stderr" ]`.
  - `@test "list --format json (space form) still exits 2"`. Round 2 fix: R438 forbids a new `--format` spelling, and this test pins today's behaviour.
  - `@test "list --format=json still works, leaves stderr empty, and matches list --json"`.
  - `@test "list --format=json --bogus: exit 2, empty stdout, one JSON error line with reason usage"`.
  - `@test "list on an undecryptable store exits 1 with nothing on stdout (text and --json)"`.
- tests/pubkey.bats:
  - `@test "pubkey prints exactly the recipient on stdout"`: `[ "$output" = "$(tr -d '[:space:]' <age.pub)" ]`; `[[ "$stderr" == *"fingerprint: sha256:"* ]]`.
  - `@test "pubkey --copy junk exits 2"`.
  - The existing :11-36 assertions stay, because `run` merges the streams.

### B3: share and receive
Files: `cmd/share.sh`, `cmd/receive.sh`, `tests/share.bats`, `tests/receive.bats`.

**cmd/share.sh**
- **B3.1** (R016, R177). share.sh:181 becomes `agsec_receipt "encrypted $name → \"$label\" ($fingerprint) — envelope printed above (no auto-rotate)"`. Stdout then holds only the fenced envelope and, with `--sign`, the signature block.
- **B3.2** (R338, R337). Declines exit 130 via `agsec_canceled`:
  - share.sh:119: `"aborted — nothing shared (canceled; nothing was changed)"`.
  - share.sh:135: `"aborted — digest not confirmed (canceled; nothing was shared)"`.
  - Keep the word "aborted": share.bats:69 greps for it.
- **B3.3** (R260, R014). share.sh:52 becomes `agsec_fail missing_input "share needs an interactive terminal — run it in Terminal.app (no flag skips this gate, by design)"` (exit 2).
  - **No** bypass flag is named: this gate is the exfiltration boundary (comment at :46-51).
  - share.sh:45 (refused inside an agent session) stays at exit 1, because it is a policy refusal.
- **B3.4** (R017, R275). share.sh:76 becomes `rc=0; store_has "$name" || rc=$?`. rc 2 calls `agsec_die_undecryptable`. rc 1 keeps `no such secret: $name`.
- **B3.5** (R071). share.sh:92, after the empty check: `[[ "$ghuser" =~ ^[A-Za-z0-9](-?[A-Za-z0-9]){0,38}$ ]] || agsec_die "share --to github:<user>: '$ghuser' is not a valid GitHub login" 2`. This rejects `/`, `?`, `#` and `.` before curl runs.

**cmd/receive.sh**
- **B3.6** (R019, R348). receive.sh:54-59: both `blob="$(cat)"` reads become `blob="$(head -c "$((AGSEC_RECEIVE_MAX_ENVELOPE*2+1))")"`.
  - Refuse when the byte count is above `MAX*2`. Keep the "too large" and "before decode" wording and exit 1.
  - Keep the existing cap-1 check after the CR strip (:62-67). The read limit is deliberately 2×: a CRLF chat paste can exceed 64 KiB raw but fit under the cap once normalized.
- **B3.7** (R359, R298). receive.sh:92: when `rename` is empty (the name came from the envelope), print `agsec_die "the envelope's name isn't a valid secret name — re-run with --rename NEW (letters, digits, underscore; start with a letter/_)"` and do **not** echo the name. Keep the current text for the local `--rename` value.
  - receive.sh:116-123: match `embedded_digest` against `sha256:` followed by exactly 12 hex characters before printing it. A malformed value gets `agsec_warn "envelope 'digest:' line is malformed — possible corruption (local value $local_digest)"` without the echo.
- **B3.8** (R338, R260).
  - receive.sh:143 becomes `agsec_canceled "aborted — $name left unchanged (use --rename NEW to keep both)"`.
  - receive.sh:48 becomes `agsec_fail missing_input "receive needs a controlling terminal (or pass --yes-i-reviewed for CI)"` (exit 2). Wave C, C2, renames the flag.
- **B3.9** (R017). receive.sh:138 becomes `rc=0; store_has "$name" || rc=$?`. rc 2 calls `agsec_die_undecryptable` before the age decrypt; rc 0 runs the collision branch as today.
- **B3.10** (R016, R021). receive.sh:179 becomes `agsec_receipt "received $name (value never shown)"`, followed by `printf '%s\n' "$name"`.
- **B3.11** (R116, R203).
  - :54 `[ -t 0 ]` becomes `agsec_stdin_is_tty`.
  - :55 loses `C_DIM`/`C_RESET`: the prompt is a choice, not metadata.
  - :118 and :120 become `agsec_plan`: the digest is verification context.

Tests:
- tests/share.bats:
  - `@test "share stdout is only the fenced envelope"`: `run --separate-stderr …` with `--to self` and a confirm file holding `y`. Assert `[[ "$output" != *"✓"* ]]`, that the last line of `$output` is a closing fence, and `[[ "$stderr" == *"encrypted "* ]]`.
  - Tighten :68 to `[ "$status" -eq 130 ]`, and :206, :230 and :244 to `-eq 2`.
  - `@test "share --to github:a/b exits 2 and never fetches"`: the curl mock logs its calls, and the log stays empty.
  - `@test "share on an undecryptable store says so, not 'no such secret'"`.
- tests/receive.bats:
  - Tighten :106 to 130 and :50 to 2.
  - `@test "receive prints only NAME on stdout"`.
  - `@test "receive never echoes an ESC from the envelope name or digest"`: assert `[[ "$output" != *$'\e'* ]]` for both crafted envelopes.
  - `@test "receive refuses an endless stream without buffering it"`: `head -c 200000 /dev/zero | tr '\0' A | … receive --yes-i-reviewed` gives status 1 and "too large".
  - `@test "receive on an undecryptable store stops before age decrypt"`.

### B4: backup and deps
Files: `cmd/backup.sh`, `lib/deps.sh`, `tests/backup.bats`, `tests/mocks/gh`.

- **B4.1** (R017, R275). backup.sh:55-67.
  - Make one query: `out="$(gh repo view "$REPO" --json isPrivate -q .isPrivate 2>"$errf")"; rc=$?`, with `errf` from mktemp and removed by the existing EXIT trap.
  - Branch on the result:
    - rc=0 and `true`: proceed.
    - rc=0 and `false`: keep the "is PUBLIC — refusing…" text (backup.bats:116).
    - rc=0 with any other value: `agsec_fail error "Couldn't confirm $REPO is private (gh returned '$out')." "gh repo view $REPO" "Check"`.
    - rc≠0 and stderr matches `Could not resolve to a Repository`: the existing confirm-then-create path.
    - rc≠0 otherwise: `agsec_fail network "Couldn't look up $REPO: <first stderr line>." "gh auth status" "Check your network and auth, then re-run"`. Nothing is created.
- **B4.2** (R014, R120, R124). backup.sh:62, before `ui_confirm`: `if [ -z "$ASSUME_YES" ] && agsec_noninteractive; then agsec_need_confirmation "create $REPO" --yes "agent-secrets backup --repo $REPO --yes"; fi` (exit 2).
  - The check covers stdin **and** stderr (R113). With stderr redirected, `ui_confirm`'s prompt would be invisible anyway.
- **B4.3** (R338). backup.sh:63, on decline: `agsec_canceled "backup cancelled — nothing was created (pass --yes to skip this prompt)"`.
- **B4.4** (R016, R173, R021). backup.sh:66, :115 and :120 become `agsec_receipt`. After the marker write (:123), `printf '%s\n' "$REPO"` on stdout.
- **B4.5** (R313, R019).
  - Export `GIT_HTTP_LOW_SPEED_LIMIT=1000 GIT_HTTP_LOW_SPEED_TIME=60` before the clone (:72) and the push (:119).
  - After the proxy-unset block (:34-36), define `gh() { /usr/bin/perl -e 'alarm shift; exec @ARGV' 60 command gh "$@"; }`, or equivalently resolve the gh path once. A timeout exits 142, which the failure branches map to the network message.
  - This keeps the literal `gh auth status >/dev/null 2>&1 || agsec_die …` line at :38 that the source pin at tests/backup.bats:103 greps for.
  - Stock macOS has no `timeout(1)`.
- **B4.6** (R351), optional. backup.sh:123 becomes `printf '%s\n' "$REPO" | agsec_atomic_write "$marker"`.
- **B4.7** (R313). deps.sh:95 adds `--connect-timeout 10 --max-time 300`. The vendored binaries are several MB; a timeout falls into the existing `rm -f "$tmp"; return 1`.
  - **Pass 2 fix:** use `--connect-timeout 15 --max-time 600`. The verifier measured a local sops binary at 50,122,210 bytes (`wc -c`; possibly not the pinned version). A 300 s cap would then fail below about 167 KB/s and 600 s below about 84 KB/s (arithmetic, estimated). B4.13 adds the retry budget.
- **B4.8** (R016). deps.sh:177 becomes `agsec_receipt`.
- **Mock.** tests/mocks/gh:23:
  - A missing remote prints `GraphQL: Could not resolve to a Repository with the name '$1'. (repository)` to stderr, then exits 1.
  - New knob `AGSEC_MOCK_GH_VIEW_FAIL=network`: stderr `error connecting to api.github.com`, exit 1.
  - New knob `AGSEC_MOCK_GH_PRIVATE=none`: print nothing (`${…:-true}` cannot express an empty value).
  - **Without the not-found stderr, every create-path test (backup.bats:13, 36, 48, 83, 125) would hit the fail-closed branch.**

Tests (tests/backup.bats):
- `@test "backup fails closed when gh repo view fails for another reason"`: VIEW_FAIL=network, `--yes`. Status 1, the remote dir is not created, output contains "Couldn't look up".
- `@test "backup refuses when isPrivate is unknown"`: PRIVATE=none. Status 1, "Couldn't confirm".
- `@test "backup without --yes and no terminal exits 2 naming --yes"`: `</dev/null`, no UNATTENDED. Status 2, `*"--yes"*`, the remote is absent.
- `@test "backup prints only owner/name on stdout"` (`--separate-stderr`).
- The :102-105 pin and every existing `--yes` test stay unchanged.

### B5: uninstall and rollback
Files: `lib/manifest.sh`, `cmd/uninstall.sh`, `tests/uninstall.bats`, `tests/mocks/launchctl`.

**lib/manifest.sh**
- **B5.1** (R003, R318, R017, R339). Rollback helpers return `0` (gone), `1` (failed) or `3` (skipped).
  - In `manifest_rollback` (:186-200), call each as `rc=0; _manifest_rb_x "$rec" "$dry" || rc=$?`, so `set -e` cannot abort the loop. Count ok, failed and skipped, and append each failed record's JSON to `failed=()`.
  - Expand that array with `${failed[@]+"${failed[@]}"}` (bash 3.2 plus set -u).
  - Per helper:
    - :274: a missing edit backup warns, names the path, and returns 1.
    - :287-288 (launchd): keep tolerating bootout's "not loaded" exit. Then, if `launchctl print "gui/$(id -u)/$label" >/dev/null 2>&1` succeeds, return 1. Claim "booted out" only when the job is not loaded **and** `rm -f "$plist"` succeeded.
    - :162-165, :216, :280 (keychain): after the delete loop, if `security find-generic-password -s "$svc" >/dev/null 2>&1` succeeds, print `agsec_receipt_bad "keychain item still present: $svc"` and return 1.
    - :206-207: a failed deferred `rm -rf` counts as failed.
  - :222: with no failures, `printf '[]\n' | agsec_atomic_write "$mf"`. Otherwise write `jq -n '$ARGS.positional' --jsonargs …failed…` (jq 1.8.2 is pinned, deps.sh:39) to a sibling temp, `agsec_commit` it, print `Removed N of M artifacts. K failed, S skipped. Re-run agent-secrets uninstall to retry the rest.`, and return 1.
- **B5.2** (R016). The agsec_ok receipts at :207, 216, 222, 231-232, 256, 262, 264, 272-273, 280, 288, 300 and 304 become `agsec_receipt`.
- **B5.3** (R203, R148). The dry-run `agsec_note` lines at :206, 215, 220, 228, 240-242, 279, 286 and 294 become `agsec_plan`.
- **B5.4** (R351). :110 and :303 stop writing a fixed `${file}.new`, which would clobber a user's own `~/.zshenv.new`.
  - Callers write to `tmp="$(agsec_tmp_sibling "$file")"`. `_manifest_replace FILE TMP` delegates to `agsec_commit`, keeping symlink write-through and the preserved mode.
  - Keep the function name: install.sh:312 refers to the pathblock helpers.

**cmd/uninstall.sh**
- **B5.5** (R003, R339). :58 becomes `rb=0; manifest_rollback || rb=$?` (and the same for `--dry-run`). When rb≠0:
  - Skip `rm -rf "$state_dir"` (:79). It would delete the kept manifest and the edit backups the retry needs.
  - Skip the :88 headline.
  - Still honour keep/purge and the roster purge.
  - Exit 1.
- **B5.6** (R016). :88 becomes `agsec_receipt` with the same text. uninstall.bats:53 matches "uninstall complete".
- **B5.7** (R203, R148). :31, :38, :39, :45, :67, :76 and :77 become `agsec_plan`. After :39 add `agsec_plan "This cannot be undone."` (the purge line).
- **B5.8** (R064). :20 becomes a loop: accept `--dry-run`, which may repeat; anything else exits 2 with the existing message. C1 extends this loop later.
- **B5.9** (R113, R116). :40 `[ ! -t 0 ]` becomes `agsec_noninteractive`. It still fails closed to KEEP, but now also when CI is set, inside an agent session, or when stderr is not a TTY.

**Mock trap.** tests/mocks/launchctl:7-8: `bootout` appends `booted` but never removes `loaded`, so `print` would report every booted-out job as still running. That would turn every launchd test into a partial failure. Make `bootout|remove` delete the `loaded` lines.

Tests (tests/uninstall.bats; add `bats_require_minimum_version 1.5.0`):
- `@test "a partial rollback says so, keeps the failed records, and exits 1"`:
  - Setup: record a non-marker edit whose backup is missing, then `run bash cmd/uninstall.sh </dev/null`.
  - Assert status 1, `*"1 failed"*`, `jq length` of the manifest equal to 1, and that the state dir still exists.
- `@test "the full-success path is unchanged"`: the existing :52-55 asserts status 0 and "uninstall complete".
- `@test "uninstall --dry-run --bogus exits 2 and changes nothing"`.
- `@test "rollback receipts go to stderr"`: `run --separate-stderr manifest_rollback`; `[ -z "$output" ]`.
- `@test "a launchd job that stays loaded counts as failed"`: a mock knob keeps `loaded`.

### B6: setup, wiring, restore
Files: `cmd/setup.sh`, `lib/wire.sh`, `lib/restore.sh`, `tests/flows.bats`, `tests/wizard_interactive.bats`.

- **B6.1** (R070). cmd/setup.sh, right after the parse loop (:538) and before mode resolution and `agsec_secure_umask`:
  - If more than one of `do_restore`, `do_keychain` and `do_discovery` is 1, `agsec_die "setup: can't use --X with --Y (each runs one step; run them separately)" 2`, naming the actual flags.
  - Have the `--no-discovery` arm (:531) also set `nodisc=1`. Then `--discovery` together with `--no-discovery` exits 2. Today that combination silently writes the rule blocks the user opted out of (:557).
- **B6.2** (R113, R062). Mode resolution at :547-551 gains `elif agsec_noninteractive_requested; then HEADLESS=1; HEADLESS_WHY="non-interactive (--non-interactive or CI)"`.
- **B6.3** (R116, R408). :297 and :558 `[ ! -t 0 ]` become `! agsec_stdin_is_tty`. Behaviour is identical, and the curl|bash `/dev/tty` attach is kept.
- **R016 for the wizard** is already handled by Wave A (ui_* to stderr). setup.sh needs no further edits for it.
- **B6.4** (R351, R368). lib/wire.sh:67-72.
  - `tmp="$(agsec_tmp_sibling "$sj")"`, then `jq --arg h "$helper" "$jqprog" "$sj" >"$tmp"`, then `agsec_commit "$tmp" "$sj"`. A symlinked settings.json, as with dotfiles, stays a symlink.
  - Hold `agsec_lock "$(agsec_state_dir)/.settings.lock" 10` around the read-modify-write. On lock timeout, `ui_warn` and return 2.
  - Keep the 0/1/2 return contract.
- **B6.5** (R017). wire.sh:25 becomes `rc=0; ( store_has ANTHROPIC_API_KEY ) >/dev/null 2>&1 || rc=$?`. rc 2 gives `ui_warn "can't read the store (decrypt failed) — run: agent-secrets doctor"` and returns 2. rc 1 keeps the current text.
- **B6.6** (R335, R337). lib/restore.sh:26-29.
  - After saving `_stty`, set `trap '[ -n "$_stty" ] && stty "$_stty" 2>/dev/null; printf "\n" >&2; exit 130' INT`, and the same handler with `exit 143` on TERM and `exit 129` on HUP.
  - After the read, restore stty and run `trap - INT TERM HUP`.
  - **Do not trap EXIT**: setup.sh:107 owns it. Set the traps inside the function so the handler can see the local `_stty`.
- **B6.7** (R016). restore.sh:43 becomes `agsec_receipt`. The :25 prompt already went to stderr in Wave A (R136).
- **B6.8** (R116). restore.sh:21 `[ -t 0 ]` becomes `agsec_stdin_is_tty`.

Tests:
- tests/flows.bats:
  - `@test "setup --restore --keychain exits 2 and writes nothing"`: assert that `$(agsec_config_dir)` is absent.
  - `@test "setup --discovery --no-discovery exits 2 and writes no CLAUDE.md"`.
  - `@test "CI=1 setup on a terminal goes headless"`: run under `script -q /dev/null env CI=1 …`; the output contains `non-interactive (--non-interactive or CI)`.
  - `@test "wiring keeps a symlinked settings.json a symlink"`: assert `[ -L "$sj" ]` and that the target holds `.apiKeyHelper`.
- tests/wizard_interactive.bats (expect, PTY):
  - `@test "Ctrl-C during the hidden key paste restores terminal echo"`.
  - Steps: spawn `bash --norc --noediting -i`; run `( . lib/common.sh; . lib/ui.sh; . lib/keychain.sh; . lib/store.sh; . lib/restore.sh; restore_flow )`; send a partial line, then `\003`; then send `stty -a`.
  - Expect ` echo ` and not `-echo`.

### B7: doctor, smoke, dispatcher
Files: `cmd/doctor.sh`, `cmd/smoke.sh`, `bin/agent-secrets`, `tests/doctor.bats`, `tests/dispatcher.bats`, `tests/mocks/osascript`.

**cmd/doctor.sh**
- **B7.1** (R071, R244). :37 `_js` becomes a call to `agsec_js`: full escaping in pure bash, so doctor still runs without jq.
  - :271 reads the marker as `head -n1 "$marker" | tr -d '[:cntrl:]'`, which also stops raw control bytes reaching text mode.
- **B7.2** (R438, R009, R253). :17-28.
  - Call `agsec_scan_json "$@"` before the loop.
  - `--json` sets FORMAT=json.
  - **Round 2 fix (R438, R385):**
    - Only the existing `--format=json` and `--format=text` (doctor.sh:20-21) stay, as hidden deprecated aliases that go through `agsec_deprecated`.
    - In JSON mode the deprecation goes into the document's `warnings` array. doctor's result is an object, and tests/doctor.bats:26-31 checks only `checks` and `exit`, so the extra key is compatible.
    - The space form `--format json` is not added.
  - With JSON selected, an unknown option (:27) gives one JSON error line on stderr, empty stdout, and exit 2, via `agsec_unknown_option doctor` (R060).
- **B7.3** (R251). Pipe the :417-423 document through `agsec_json_out` (pretty on a TTY when jq is present).
- **B7.4** (R017). :235: `rc=0; _guard store_has ANTHROPIC_API_KEY || rc=$?`. rc 2 gives `_row store bad "store readable" "decrypt failed — check key custody" core "agent-secrets doctor --gates"`, not the "optional — not stored" ⚠ row.

**cmd/smoke.sh**
- **B7.5** (R064). After `set -euo pipefail` (:9) and before sourcing: `[ "$#" -eq 0 ] || { printf 'agent-secrets smoke: takes no arguments (got: %s)\n' "$1" >&2; exit 2; }`. The launchd plist (install.sh:404-408) passes no arguments.
- **B7.6** (R071). :17 becomes `osascript -e 'on run argv' -e 'display notification (item 2 of argv) with title (item 1 of argv)' -e 'end run' "$1" "$2" >/dev/null 2>&1 || true`.
  - Pass no `--`: osascript does not document it as an option terminator, so it could arrive as argv item 1.
  - At :56, a line the regex does not match sets `name=""` and is skipped, instead of using the raw line.

**bin/agent-secrets**
- **B7.7** (R012, R083). In the interception `case` (:81-87), add a separate `smoke)` arm: `if _wants_help "$@"; then printf '%s\n' 'Usage: agent-secrets smoke' '' 'Hidden maintenance check (launchd job com.agent-secrets.smoke). Exits 0 if all pass, 1 on failure, 2 on usage error. Names only.'; exit 0; fi`.
  - Do **not** route it through `agsec_help_render`: help.sh:254 dies with "no such command".
  - Do **not** add smoke to `AGSEC_VERBS`, so it stays hidden.
- **B7.8** (R086, R061, R062).
  - `-v|-V|--version` sets `_want_version=1` in both the leading loop (:26-28) and the post-verb strip loop (:42-46). The strip loop only does this before `--`, so `run -- cmd --version` still reaches the child.
  - Handle it **after** sourcing common.sh (:52) and **after** the help interception, so help wins: print `agent-secrets $AGENT_SECRETS_VERSION`, or `{"version":"…"}` when `--json` appears before `--`, then exit 0.
  - Delete the sed and the `'0.1.0'` literal.
  - Keep `agent-secrets version` (no dashes) as exit 2 (dispatcher.bats:70).
- **B7.9** (R062, R113). Both loops accept `--non-interactive`, export `AGENT_SECRETS_NONINTERACTIVE=1`, and never forward it.
- **B7.10** (R106). In the interception arm, when `_wants_help` and `--json` both appear before `--`, run `agsec_help_json | jq -c --arg v "$hv" '.commands[]|select(.name==$v)' | agsec_json_out`.

Tests:
- tests/doctor.bats:
  - `@test "doctor --json stays valid JSON when the backup marker holds a newline and a tab"`.
  - `@test "doctor --json equals doctor --format=json"`.
  - `@test "doctor --json --bogus: exit 2, empty stdout, one JSON error line"`.
  - `@test "doctor shows a ✗ store row when the store can't be decrypted"`.
  - The existing :22, :31 and :67 tests and onboarding.bats:42-43 cover the alias, unchanged.
- tests/dispatcher.bats:
  - `@test "smoke --help prints usage and does no work"`: status 0, `Usage: agent-secrets smoke`, no `keychain read`.
  - `@test "smoke bogus exits 2"`.
  - `@test "help --json still omits smoke"`.
  - `@test "list --version and -v print the version"`.
  - `@test "run -- sh -c 'echo \$1' sh --version hands --version to the child"`.
  - `@test "--version --json prints {version}"`.
  - `@test "--non-interactive after the verb is accepted and not forwarded"`.
  - `@test "uninstall --help --json prints one command object"`: `jq -e '.name=="uninstall"'`.
  - `@test "smoke notifications pass text as osascript argv"`: the osascript mock logs `"$@"`, and a name containing `"` arrives as a single item.
  - The existing :7, :45 and :69-75 stay.

### B8: help and docs (lands last in Wave B)
Files: `lib/help.sh`, `tests/help.bats`, `AGENTS.md`, `llms.txt`, `README.md`, and the skip line in `tests/common.bats`.

- **B8.1** (R023). help.sh:110-111, uninstall exit rows:
  - `0` = "uninstall completed, dry-run printed, or nothing to roll back". manifest.sh:171 returns 0, and uninstall.bats:52-53 pins it.
  - `1` = "partial rollback (failed records kept in the install manifest for retry) or error (corrupt manifest, missing jq)".
- **B8.2** (R087, R094, R098, R203). The per-verb renderer (:255-266) prints, in order: Usage, summary, desc, Arguments, `Options:` (sorted by long name), `Global Options:` (`--plain`, `--no-color`, `--non-interactive`, `-h, --help`, `-v, --version`), Environment, Examples, then `Notes:`.
  - **Round 2 fix (R466):** round 1 listed `-v, -V, --version`. `-V` is outside the short-option table (checklist Reference G), so help stops listing it. B7.11 keeps `-V` working as a deprecated alias.
  - Examples: the command indented 4 spaces in normal or bold, **not** `$C_DIM`, with the description on the next line.
  - `Notes:` holds exit codes, Names-only (bold, not green), Reads and Writes.
- **B8.3** (R095).
  - When `key + 2` exceeds the column, put the description on the next line, indented 6 and folded with `fold -s -w 74`. Apply this to flag, env, arg and example rows.
  - Top level: `Global flags:` becomes `Global Options:` with the same wrapping.
  - Either keep the `0=success` token (help.bats:101) or update that assertion in this commit.
- **B8.4** (R436). Value hints become `--import-env <NAME>[,<NAME>…]`, `--rename <NAME>` and `--repo <REPO>` at help.sh:33, 37, 114, 122, 131, 134, 155 and 158. Make the same change in README.md:158 and AGENTS.md:98.
- **B8.5** (R106). Add an optional spec column so `flags[]` entries gain `type`, `value_hint`, `default` and `choices`.
  - Keep `flag` and `description` (help.bats:89; the AGENTS.md:89-91 schema).
  - Keep `help --json` and the 11-command count (help.bats:54, onboarding.bats:91).
  - Note the new keys in AGENTS.md:89-91.
- **B8.6** Rows that must change because Wave B changed behaviour (R023):
  - **Top level:** `-v, --version` (Round 2: `-V` removed from help, R466), `--non-interactive`, env `FORCE_COLOR`, env `CI` ("non-empty: non-interactive").
  - **share:** exit 130 "canceled at the y/N confirm (nothing shared)"; exit 2 adds "or no interactive terminal".
  - **receive:** move "no tty" from exit 1 to exit 2; add exit 130; exit 1 adds "store can't be decrypted"; stdout: "the stored NAME".
  - **backup:** exit 130; exit 2 adds "creating the repo non-interactively without --yes"; exit 1 adds "couldn't confirm the repo is private / look it up"; stdout: "owner/name".
  - **list:** synopsis `agent-secrets list [--json]`; a `--json` flag row ("`--format=json` still accepted, deprecated"); exit 1 "store can't be decrypted"; the :71 example shown compact.
  - **doctor:** `--json` in the synopsis (:88), the flag row (:91) and the example (:97).
  - **pubkey:** desc (:146) "stdout: the recipient string only; heading and fingerprint on stderr".
  - **run:** exit 2 adds "command not found"; exit 0 row "the child's exit code (128+n if it died of a signal)".
  - **add:** stdout "the stored NAME"; add `~/.claude/settings.json (apiKeyHelper, only for ANTHROPIC_API_KEY)` to `writes` (:61), the residual gap from a dropped finding.
  - **Docs:** use `--json` in AGENTS.md:25, 100, 102, 121, 143, llms.txt:16, 18 and README.md:319, and say that `--format=json` still works.
- Un-skip the R408 lint in tests/common.bats.

Tests (tests/help.bats):
- `@test "no rendered help line exceeds 80 columns"`: for top-level and every verb, `LC_ALL=en_US.UTF-8 awk 'length>80'` prints nothing. Use a UTF-8 locale so `…` and `✓` count as one column.
- `@test "uninstall --help lists exit 0 for nothing to roll back"`.
- `@test "help --json flags carry type, value_hint and default"`.

### Round 2 additions to Wave B

Rows B1.11 onward extend the round-1 units. Each unit keeps its round-1 file list unless a row adds a file.

B9 and B10 are new units. Round 1 covered install.sh only as a caller of setup, and the critic listed it as an uncovered CLI.

Every row was checked against the code at `5266599`.

Three things apply to every unit:
- **Usage-error wording (R060).** Switch the unit's own unknown-option and surplus-argument sites to `agsec_unknown_option` and `agsec_unexpected_argument` (A.12). The sites are listed per unit.
- **Parse-only seam (R100).** Add one `agsec_parse_only_exit` call right after the parse loop of every cmd script the unit owns (A.13). It goes before any store read, TTY attach, prompt or write.
- **Mode matrix (R403).**
  - A unit that changes a prompt, a stream, the format or consent adds an `mm_run` test (A.15) covering all 7 modes.
  - Each test asserts whether the prompt appeared, what each stream holds, and the exit code.
  - A mode the command does not support, such as `json-tty` for a command without `--json`, is asserted as exit 2, never skipped.

**B1**
- **B1.11 Drop one trailing CR from a piped value** (R349). lib/store.sh:71.
  - **Verified:** `IFS= read -r value || true` keeps the `\r` of a CRLF line. So `printf 'v\r\n' | agent-secrets add K` stores `v\r`, and `run` injects it with the CR.
  - **Change:** `local value; if IFS= read -r value; then value="${value%$'\r'}"; fi`.
    - Only a line that ended in a newline loses one `\r`.
    - A value read at EOF with no newline is untouched. The rule drops exactly one trailing `\n` or `\r\n`.
  - **Test** (tests/foundation.bats):
    - `printf 'v1\r\n' | store_add K`, then `agsec run -- sh -c 'printf %s "$K" | wc -c'` prints 2.
    - Piping `v1\r` with no newline gives 3.
  - **Callers:**
    - add.sh:30 and :32.
    - setup.sh:246, :264 and :306 use `printf '%s'` with no newline, so they are unaffected.
    - receive.sh:171 reads a file.
    - A stored trailing CR breaks any HTTP header it lands in, so nothing depends on it. Compatible.
- **B1.12** R060 in B1.10's run.sh loop (`agsec_unknown_option run`). Seam in cmd/run.sh after the loop.

**B2**
- **B2.9** R060: B2.1 and B2.4 were corrected in place above, and B2.8's "anything else" also uses `agsec_unknown_option pubkey`. Seams go in cmd/add.sh, cmd/list.sh and cmd/pubkey.sh. list calls `agsec_json_signal_traps` after parsing (R262).
- **B2.10 Identifier only on success** (R176). Tests in tests/store.bats with `--separate-stderr`:
  - `add` with a two-line value exits 2 with empty stdout.
  - `add` with an empty value exits 2 with empty stdout.
  - B2.2 prints the name as the last statement, so this already holds; the tests pin it.
- **B2.11** pubkey's `-` warning (B2.8) prints once even when `-` repeats (R308).

**B3**
- **B3.12 A concrete digest question** (R228, R220). cmd/share.sh:133.
  - **Verified:** the `--verify` readback ends with `  Proceed? [y/N] `.
  - **Change:** keep the digest line. Then ask, on its own line, `Did the recipient confirm this digest matches? [y/N] `. A decline keeps B3.2's text and exit 130.
  - **Test** (tests/share.bats): in the `--verify` case, stderr contains `Did the recipient confirm` and not `Proceed?`.
  - **Callers:** no test or doc matches "Proceed". Measured with `grep -rn Proceed tests docs README.md AGENTS.md llms.txt SECURITY.md`; the only hit is a table row in a feedback log. Compatible.
- **B3.13** R060:
  - share.sh:25 (`-*`) becomes `agsec_unknown_option share`.
  - share.sh:26 becomes `agsec_unexpected_argument share`.
  - receive.sh:27 becomes `agsec_unknown_option receive`.
  - In the same commit, tests/receive.bats:88 changes from `*"unknown flag"*` to `*"Unknown option"*`.
  - Seams go in cmd/share.sh and cmd/receive.sh.
- **B3.14** R176: `receive` on a malformed envelope exits non-zero with empty stdout (`--separate-stderr`).
- **B3.15 Mode matrix for share's confirm and receive's overwrite prompt** (R403, R113).
  - share, per mode:
    - `tty` answered `y`: exit 0, prompt on the pty.
    - `stdout-redirected`: prompt on the pty, envelope in the file.
    - `stdin-piped`, `ci-tty`, `noninteractive-tty`: exit 2, no prompt, B3.3's message.
    - `agent`: exit 1. This is the share.sh:45 policy refusal (exception E5).
    - `json-tty`: exit 2, because share has no `--json`.
  - For `ci-tty` and `noninteractive-tty` to refuse, the share.sh:52 gate must also check `agsec_noninteractive_requested` (A.4). Today it checks only the confirm source.
  - receive: the same rows, around the overwrite prompt at receive.sh:140-143.

**B4** (B4 now also owns `tests/deps.bats`)
- **B4.9 Retry on the dependency fetch** (R313, R314, R019). lib/deps.sh:95.
  - Next to B4.7's timeouts, add `--retry 3 --retry-connrefused`. curl's `--retry` retries only transient errors and backs off, which keeps it bounded. `--proto '=https'` is already there.
  - **Pass 2 fix:** also add `--retry-max-time 900`, so total waiting has a limit. Never add `--retry-all-errors`: it would retry a 404 (R314).
  - Test (tests/deps.bats): `@test "_deps_curl passes connect, max-time and retry options"`, using A2's `AGSEC_MOCK_CURL_LOG`.
- **B4.10** R060: backup.sh:19 becomes `agsec_unknown_option backup`. Seam in cmd/backup.sh.
- **B4.11** R176: the B4.1 fail-closed paths exit 1 with empty stdout (`--separate-stderr`).
- **B4.12 Mode matrix for backup's create prompt** (R403):
  - `tty`: the prompt appears; `y` creates the repo; `n` exits 130.
  - `stdin-piped`, `ci-tty`, `noninteractive-tty`, `agent`, each without `--yes`: exit 2 naming `--yes`, no prompt, no repo.
  - Any mode with `--yes`: proceeds.

**B5**
- **B5.10** R060: uninstall.sh:20, in B5.8's loop, becomes `agsec_unknown_option uninstall`. Seam in cmd/uninstall.sh.
  - B5's change to tests/mocks/launchctl must keep A2's `AGSEC_MOCK_LAUNCHCTL_BOOTSTRAP_FAIL` knob.
- **B5.11 Mode matrix for the keep/purge prompt** (R403):
  - `tty`: the prompt appears.
  - Every other mode: no prompt, the store is kept, exit 0 (B5.9).

**B6**
- **B6.9 Menu cancel** (R013, R134). cmd/setup.sh:309.
  - Change: `name="$(ui_menu …)" || { ui_say "Skipped. Store one anytime:  agent-secrets add <NAME>"; return 0; }`. A.10 makes ui_menu return 1 on EOF or on a 4th bad answer.
  - Tests (tests/wizard_interactive.bats, using `_wiz`):
    - `_wiz '9\n9\n9\n9\n' _first_secret`: status 0, prints "Enter a number from 1 to 4" and "Skipped", and nothing is stored.
    - `_wiz '' _first_secret` (EOF): the same.
    - `_wiz '7\n4\n' _first_secret`: asks again, then skips.
  - The expect drives at :130, :163 and one_command.bats:100 stay valid, because A.10 keeps their prompt text.
- **B6.10 A no-prompt replay** (R135). cmd/setup.sh `_done_screen` (:396).
  - **Verified:** the interactive wizard asks 3 or more questions and never prints a replay. The questions are at setup.sh:171, :196 (paste-back), :309 (menu), :317 (custom name), and the value prompt (:331). `grep -rn 'without prompts' cmd lib` finds nothing.
  - **Change:**
    - On the interactive done screen, print `Run this again without prompts:` and one indented line: `agent-secrets setup --headless --no-discovery`.
    - Append ` --import-env <NAME>` when `_first_secret` stored a secret; record the name in a global.
    - The value never appears in the command: `--import-env` reads it from the variable of that name (setup.sh:254-257).
    - `--no-discovery` matches what the interactive wizard did (DISCOVERY=0, setup.sh:552), and stays accepted under C3/D5.
  - Expose the line builder as `_replay_cmd`, so B8.9's parser test can feed it through the seam (R100).
  - The "summarize answers before the first mutation" half of R135 is recorded as exception E6.
  - **Test:** the E2E expect drive at wizard_interactive.bats:148 (menu answer `1` at :163) asserts `Run this again without prompts:` and `--import-env ANTHROPIC_API_KEY`, and that the pasted value is absent. The change only adds lines, so other healthy-path asserts are untouched.
- **B6.11** R060: setup.sh:539 becomes `agsec_unknown_option setup`. The seam goes after the parse loop and after B6.1's conflict check.
- **B6.12 Mode matrix for setup's mode resolution** (R403), in tests/flows.bats:
  - `tty`: the wizard runs; the first prompt is "Save it off this Mac now?".
  - `ci-tty`, `noninteractive-tty`, `agent`: headless, no prompt.
  - `stdin-piped` with no controlling terminal: headless, "no terminal attached".

**B7** (B7 now also owns `lib/help_search.sh`, new)
- **B7.11 Stop advertising `-V`** (R466, R385, R308). bin/agent-secrets:26.
  - Reference G (checklist.md:695-711) lists `-v` for version and has no `-V`. Round 1 kept `-V` in help (B8.2 and B8.6, both corrected above) and dropped the point under R464 (§5).
  - **Change:** `-V` keeps working as a hidden deprecated alias. It prints the version on stdout first, then calls `agsec_deprecated -V --version`: one stderr line in text mode, the `warnings` key of `{"version":…}` with `--json`.
  - **Callers:**
    - tests/dispatcher.bats:69-75 runs `agsec -V` with the streams merged and prefix-matches `agent-secrets `, so the version line must come first. Retitle that test, which calls -V "the documented route".
    - No doc mentions `-V` except help.sh:22 (B8.8).
- **B7.12 `help --all`** (R107). bin/agent-secrets:104-109.
  - **Verified:** `help --all --json` reaches `agsec_help_render --all` and dies with "no such command: '--all'", exit 2 (help.sh:254).
  - **Change:** in the `help` arm, `--all` with `--json`, in either order, runs `agsec_help_json`. `--all` alone prints top-level help: the CLI is flat, so "all" is the top level.
  - **Tests** (tests/dispatcher.bats): `help --all --json` and `help --json --all` print the same document as `help --json`.
- **B7.13 `help search`** (R108). A `search)` case in bin/agent-secrets's help arm, plus the new `lib/help_search.sh`.
  - `agent-secrets help search <TEXT> [--json]` works offline.
  - It does a case-insensitive substring match over each verb's name, summary, synopsis and example rows from `agsec_help_spec`.
  - It prints at most 10 results as `  agent-secrets <verb>  <summary>`.
  - `--json` prints `{"commands":[{"path":"agent-secrets list","summary":"…"}]}`, built with `agsec_js`, so jq is not needed.
  - No match prints `No commands match "<TEXT>"` and exits 0. A missing query is a usage error (exit 2).
  - The query is never written to disk or logged. `smoke` stays hidden because it is not in AGSEC_VERBS.
  - **Tests:**
    - `help search json` lists list and doctor.
    - `help search zzz` exits 0 with the no-match line.
    - `help search --json key` is valid JSON with `.commands[].path`.
    - `help search` with no query exits 2.
- **B7.14** R060: doctor.sh:27 becomes `agsec_unknown_option doctor`.
  - In the same commit, tests/doctor.bats:42 matches `Unknown option`, and tests/dispatcher.bats:81 and :84 assert that `unknown option` is absent.
  - Seams go in cmd/doctor.sh and cmd/smoke.sh.
- **B7.15** R262: doctor calls `agsec_json_signal_traps` after parsing.
  - Test: `doctor --json`, held mid-run by a sleeping `security` shim and then sent TERM, writes one `canceled` error line and exits 143.
- **B7.16** R403 for the `--non-interactive` flag: tests/dispatcher.bats asserts that it exports `AGENT_SECRETS_NONINTERACTIVE=1` to the cmd and is not forwarded.

**B8**
- **B8.7** R060 rows:
  - help.sh:52, :74 and :101, "usage error (unknown flag…)", become "usage error (unknown option…)".
  - :112 becomes "usage error (unknown option)".
- **B8.8** R466: help.sh:22 `-V, --version` becomes `-v, --version`.
- **B8.9 Every help example goes through the parser** (R100). tests/help.bats.
  - `@test "every help example parses"`:
    - Loop over every `example` row of `agsec_help_spec`. There are 21 today (measured with awk over lib/help.sh).
    - Take the `agent-secrets …` segment: drop any leading `VAR=value` words, and anything before the segment or after a following `|`.
    - Replace each `<UPPER>` placeholder with a synthetic word.
    - Run `AGSEC_PARSE_ONLY=1 bash bin/agent-secrets <args>` in a fresh `AGENT_SECRETS_HOME` with no store. Each run must exit 0; on failure, print the example.
  - The test iterates the spec, so it also covers B8.6's new `--json` examples and every example C6 adds (uninstall `--yes`, share `--yes`, run `--allow-env`).
  - It also feeds B6.10's `_replay_cmd` output and the top-level synopsis through the same seam.
  - Negative control: `AGSEC_PARSE_ONLY=1 … list --bogus` exits 2. That proves the seam sits after validation.
- **B8.10 Root help content** (R088, R096, R101, R092).
  - Mark the default action. Bare `agent-secrets` prints help (bin/agent-secrets:78), so the help row reads `help (default)`.
  - Group the Commands list by task, each verb once:
    - Get started: setup, doctor, uninstall.
    - Secrets: add, list, run.
    - Share: share, receive, pubkey.
    - Back up: backup.
  - Show `ls` beside `list` as its shortcut.
  - Drop the generic "show help; 'help <cmd>' or '<cmd> --help'…" text from the help row. R096 allows no hint to run help.
  - R101: one example per distinct job, never `[options]`. The 21 current rows already comply on a static read.
  - This is copy and layout only (R383). Update any help.bats assertion that pins the old order.
- **B8.11** Rows for B7.11-B7.13: top-level `help search <TEXT>` and `help --all --json`. The Global Options row reads `-v, --version`.
- **B8.12 Presentation transcripts** (R401, R404). tests/help.bats.
  - Render top-level help and each verb's help with `FORCE_COLOR=1` (agent variables unset) and with `NO_COLOR=1`, at `COLUMNS` 40, 80 and 120.
  - Assert that:
    - stripping ANSI from the rich render gives the plain render byte for byte;
    - `--no-color` and `TERM=dumb` give the plain render;
    - `help --json` contains no ESC under `FORCE_COLOR=1`.
  - The PR body carries the before and after transcripts at the three widths.
- **B8.13 install.sh in the docs.** B8 lands after B9.
  - Add B9's new options (`--version`, `--no-color`, `--debug`, the `=true|false` forms) to the flags list at README.md:154-159 and to AGENTS.md:44-58. **Pass 2 fix:** also list `--discovery` and the `--no-dry-run` and `--no-headless` negations (B9.3).
  - Add `AGENT_SECRETS_INSTALL_URL` beside the mirror note at README.md:169-172.

### B9 (new): install.sh, compatible fixes

**Files:** `install.sh`, `tests/install.bats`, and `tests/install_helper.bash` (new). The helper takes `_tree_files` and `_build_mirror` out of tests/install.bats:7-41 so B10 can load them.

**Size:** about 450 LOC (estimated), the largest unit. **Pass 2 fix:** this list no longer fits one unit. "Round 2, pass 2" below (after B10) assigns B9.1-B9.4 to B9 and the other rows to B11, B12 and B13, each with its own test file. The row text below still applies, including its "Pass 2 fix" notes.

**Starts after A2**, because it uses A2's curl and launchctl mock knobs. It needs no A1 code: install.sh sources lib/common.sh only after unpack (install.sh:265).

All rows are compatible per their verdicts. The callers that matter, measured with `grep -rnI install.sh`:
- tests/install.bats @tests at :50, :63, :73, :83, :95, :110, :138, :152, :159, :172;
- tests/one_command.bats:37 and :45;
- tests/discovery.bats:21;
- tests/audit_regressions.bats:106;
- AGENTS.md:44-45, README.md:58 and :129, docs/FAQ.md:67.

Failure-path tests assert only `-ne 0` (install.bats:68, :78, :167, :182). The substrings they pin must survive:
- "no baked release digest", "SHA-256 mismatch", "not a directory";
- "agent-secrets installer";
- "agent-secrets, claude-agent, cursor-agent, apiKeyHelper";
- "back up an existing ~/.claude/settings.json";
- "weekly launchd smoke job";
- "setup --headless";
- "SHA-256 verified";
- "You're set up";
- and "real terminal" must never appear.

- **B9.1 Help** (R081, R083, R087, R089, R091, R093, R094, R095, R436, R012, R079). install.sh:96-102 and :22-32.
  - **Verified:**
    - The -h/--help arm prints through `_say`, which writes to stderr (:78).
    - It starts with a lowercase `usage:` and has no summary, sections or defaults.
    - The bare word `help` hits the `*)` arm (:103) and exits 1.
    - The rendered widths are 87, 96, 93 and 93 columns at :97 and :99-101. The verifier measured this with python `len`.
    - The POSIX guard (:22-32) re-fetches install.sh with curl before arguments are parsed. With `sh -c "$(curl …)" --help`, `--help` binds to `$0`, so the re-fetched script runs a full install.
  - **Change:**
    - Add a POSIX-clean `_agsec_usage()` above the guard. It uses printf only and writes to stdout, wrapped at 80 columns:
      - `Usage: install.sh [options]`
      - `Install agent-secrets and run setup.`
      - Options, in alphabetical order: `--debug`, `--dry-run`, `-h, --help`, `--headless`, `--import-env <NAME>[,<NAME>...]`, `--no-color`, `--no-discovery`, `-v, --version`. Defaults are shown, and the description moves to the next line when a key is long.
      - Environment: `AGENT_SECRETS_HOME` (default `$HOME`), `AGENT_SECRETS_BASE_URL`, `AGENT_SECRETS_INSTALL_URL`, `AGENT_SECRETS_DEPS_BASE_URL`, `AGENT_SECRETS_DEPS_NO_BREW` (the last two are read through lib/deps.sh:44 and :170). An empty value counts as unset. The variables themselves are not saved, but paths derived from `AGENT_SECRETS_HOME` are written into the rc PATH block (:310, :314) and the plist (:319). `AGSEC_REEXECED` stays out of help.
      - Examples: the AGENTS.md:44-45 download-then-`bash /tmp/agent-secrets-install.sh` command, and `bash install.sh --dry-run`.
      - **Pass 2 fix (R091, R105, R092).**
        - AGENTS.md:44-45 is hard-wrapped, and B8.15 moves that path to mktemp, so it is not the example. Use `bash install.sh --headless --import-env OPENROUTER_API_KEY --no-discovery` (the flag shape at tests/install.bats:143) and `bash install.sh --dry-run`.
        - Add `Notes:`: progress and prompts go to stderr; an agent session, CI or no terminal means headless setup.
        - Add `Learn more:` with `https://github.com/renchris/agent-secrets/blob/${AGSEC_PINNED_TAG}/README.md`, interpolated so there is no new version literal to bump.
        - The `--headless` row must say that setup runs prompt-free but install's own consent keypress still applies on a terminal (:174 ignores HEADLESS today; D10 decides any flag for it).
    - Use ASCII `...`, not `…`. install.sh has no plain-mode switch before unpack (R205).
    - Add a pre-guard loop: `for _a in "$@"; do case "$_a" in --) break;; -h|--help) _agsec_usage; exit 0;; esac; done`, plus `[ "${1:-}" = help ]`. Help then never re-fetches or re-execs.
    - In main, the arm becomes `-h|--help|help) _agsec_usage; return 0 ;;`.
    - `--import-env` parsing is unchanged; only its hint text changes.
  - **Tests** (tests/install.bats, `bats_require_minimum_version 1.5.0`):
    - `--help`, `-h` and `help` each give status 0, stdout that starts with `Usage: install.sh`, empty stderr, and no line over 80 columns (awk length).
    - `/bin/sh install.sh --help` with `AGSEC_MOCK_CURL_LOG` set leaves the log empty.
    - **Pass 2 fix (R012, R379):** that test is vacuous. `$0` is a real file there, so line 24 re-execs without any fetch, with or without the fix. Also run `sh -s -- --help < install.sh` with `AGSEC_MOCK_KEYS_FAIL=1` and `AGSEC_MOCK_CURL_LOG` set. Assert status 0, `Usage: install.sh`, no `could not re-fetch`, and an empty log. By reading, it fails today with exit 1 at line 31.
    - **Pass 2 (R083, R086):** `--bogus --help` and `--import-env --help` print help, exit 0, and create nothing. `--import-env help` is still a value, because `help` counts only as `$1`.
  - **Callers:** nothing runs install.sh's help. tests/help.bats:80 is cmd/uninstall.sh.
  - **Pass 2: three verdicts disagree on this row; it stays as written.**
    - One verdict keeps help on stderr. R083 is a MUST, no caller reads either stream (grep in its verdict), and a `2>&1` capture is unaffected, so stdout stands.
    - One proposes a parser-order walker, and one proposes no pre-scan. R083 says "once help is recognized, other validation is skipped". `--import-env --help` today installs with `--help` as the NAME, and `--bogus --help` exits 1 instead of showing help. So the pre-guard scan stays. R063's ban on hand-scanning is recorded as E9, because install.sh has no metadata parser before unpack.
- **B9.2 Usage errors exit 2** (R337, R055, R060, R231, R304). install.sh:80, :94, :103.
  - **Change:**
    - Add `_usage_die() { printf 'ERROR: %s\n\nSee the options:\n    bash install.sh --help\n' "$*" >&2; exit 2; }`. The prefix stays `ERROR:` until D6.
    - :103 becomes `_usage_die "Unknown option '$1' for install.sh."`.
    - :94 becomes `_usage_die "Can't use --import-env without <NAME>."`.
    - Every other `_die` stays at exit 1.
    - **Pass 2 fix (R355, R060, R304, R004).** This row as written echoes a value, and its hint is not runnable under `curl | bash`.
      - The help line in `_usage_die` prints `$(_self_cmd) --help` (B9.14), not a literal path.
      - Split :103 into two arms. `-*)` reports `Unknown option '${1%%=*}' for install.sh.`, plus at most one close name from a bash 3.2 `case` over the known long options (nothing when none is close; print it, never run it). `*)` reports `install.sh takes no positional arguments.` and does not echo the token.
      - The parse runs before any EXIT trap is armed (first trap at :260), so exit 2 cannot be overwritten.
  - **Tests:** `--bogus` and a bare `--import-env` each give status 2, stderr names the token and `install.sh --help`, and there is no `~/.agent-secrets`. **Pass 2:** also `--import-envv=SEKRET` and a positional `SEKRET`: status 2 and no `SEKRET` in the output; `--dry-rn` suggests `--dry-run`.
  - This matches the repo's own convention: cmd/setup.sh:539, cmd/doctor.sh:27 and lib/help.sh:52 use exit 2 for usage errors.
- **B9.3 Parsing** (R063, R064, R066, R068, R069). install.sh:89-106.
  - (a) Add a `--)` arm. install.sh takes no positionals, so anything after `--` gets `_usage_die "Unexpected argument '$1' for install.sh."`.
  - (b) Validate `--import-env` values at parse time, in both forms, with the cmd/setup.sh:515-521 rule: each comma-separated name matches `[A-Za-z_][A-Za-z0-9_]*`, and an empty list is an error. This fixes two bugs:
    - `--import-env --dry-run` today loses the dry run: a real install runs, and setup rejects the list only at the end (setup.sh:534).
    - `--import-env=` with an empty value is silently dropped today (:95, :382).
    - **Pass 2 fix (R069, R015, R355).** "At parse time" means after the loop, on the final value, not inside the option arm.
      - `--import-env 1BAD --import-env GOOD` succeeds today as last-wins, because only the final value reaches setup. `--help` must also still win.
      - Inline a copy of `_import_env_valid` (common.sh is not available yet; `_agent_session` at :108-118 is the precedent).
      - Require at least one name: setup's `''` arm (setup.sh:518) is dead because word-splitting yields no iterations, so `,` and a space both pass today.
      - Keep space separation valid, because setup's word-split accepts it.
      - Reject glob characters before the unquoted `for`, so the verdict cannot depend on the cwd: `case "$IMPORT_ENV" in *[!A-Za-z0-9_,[:space:]]*) …`.
      - IMPORT_ENV="" cannot tell empty from unset after the loop, so the `--import-env=*` arm gets its own empty check.
      - Fail through `_usage_die` (exit 2) with fixed wording. Never echo the value (E8). Validating before the plan also stops :155 from printing it.
      - **Narrowing to note in the release:** `--import-env=` goes from exit 0 to 2, and `--import-env ''` from 1 to 2. Neither is documented, and no repo caller uses them. An external `--import-env="$X"` with an empty `X` would now fail before installing (its verdict searched this repo and the current workspace only).
  - (c) Accept `--dry-run=`, `--headless=` and `--no-discovery=`, each with `true` or `false`. Any other value is a usage error.
    - **Pass 2 fix (R068, R455, R070).** Add the missing negations: `--no-dry-run`, `--no-headless` (this only un-forces; auto-detection stays), and `--discovery[=true|false]`. A contradictory pair such as `--dry-run --no-dry-run` is a usage error, never last-wins, so an appended flag cannot turn a preview into a mutation.
  - (d) No install-level `--discovery` here. It would collide with `setup --discovery`, a standalone screen (setup.sh:529, :557). See D5 (round-2 sub-question) and C7.3.
    - **Pass 2 fix (R068, R125).** R068 requires the positive form. The collision comes only from forwarding, so accept `--discovery` and **never forward it** here.
      - On an interactive run it pre-answers install's own offer with yes, and the offer is skipped.
      - Without a terminal it is a no-op, because headless setup already writes the rules (setup.sh:552).
      - Correct the "passed straight through" comment at :83.
      - C7.3 adds forwarding only under D5.
      - **Test:** on a no-TTY run, a setup argv log shim shows no `--discovery`.
  - (e) Help states the repeat behaviour: for `--import-env` the last one wins, and the Boolean flags are idempotent. **Pass 2:** help also says an empty `--import-env` value is an error.
  - (f) Parse-only seam (R100): after the loop and before `_attach_tty` (:132), `[ -z "${AGSEC_PARSE_ONLY:-}" ] || return 0`.
  - **Tests:**
    - `--import-env --dry-run` exits 2, creates nothing, and leaves the curl log empty.
    - `--import-env=` exits 2.
    - `--dry-run=true` matches `--dry-run`.
    - `--dry-run=maybe` exits 2.
    - `-- extra` exits 2.
    - Both help examples, and B9.8's printed command, exit 0 under `AGSEC_PARSE_ONLY=1` with no curl call (R100).
    - **Pass 2:**
      - `--import-env 1BAD --import-env GOOD` passes the seam.
      - `--import-env 1BAD` and `--import-env ,` each exit 2 with no `~/.agent-secrets`.
      - `--import-env='*'` exits 2 whatever the cwd holds.
      - `--no-dry-run` and `--no-headless` parse.
      - `--dry-run --no-dry-run` exits 2.
      - A table test pins that the inline validator and `_import_env_valid` agree on the same inputs, by sourcing cmd/setup.sh, which guards `main` (setup.sh:594).
  - **Callers:** install.bats:143 passes `--headless --import-env SEEDED_TOKEN --no-discovery`, which is still valid.
- **B9.4 Global options** (R062, R086). install.sh:28, :42, :89-103.
  - **One tag variable.** Add a POSIX-clean top-level `AGSEC_PINNED_TAG="v0.1.3"` above the guard. The tag is written twice today, at :28 and :42; both read the variable instead.
    - Add a test that the tag equals `v$(cat VERSION)` (0.1.3, measured).
    - scripts/release.sh:72 seds only the `EXPECTED_SHA256` line, which keeps its form.
  - **`-v, --version`.** A pre-scan runs after the help pre-scan, so help wins (R086). It prints the bare `0.1.3` on stdout and exits 0, before any work. With `--json` it prints `{"version":"0.1.3"}`.
  - **`--no-color`.** Accepted as a no-op; there is no color today. C7.2's glyph table honours it.
    - **Pass 2 fix:** not a no-op. It runs `NO_COLOR=1; export NO_COLOR`, because the chained setup honours NO_COLOR (lib/common.sh:76). install.sh itself still emits no ANSI.
  - **`--debug`.** Prints extra step diagnostics on stderr. It never uses `set -x`, because of the no-value promise at :8.
  - **`--non-interactive`, `-y/--yes` and an optional `--json` receipt** are D10.
  - **Tests:**
    - `--version` gives `0.1.3`, exit 0, and no curl call.
    - `--help --version` prints help.
    - `--version --json` is valid JSON.
    - `--no-color --dry-run` exits 0.
- **B9.5 Consent prompt** (R338, R220, R228, R131). install.sh:174-180.
  - **Verified:**
    - :176 reads a reply, and :177 checks only for d/D, so `n`, `no` and `q` all install.
    - `[d]` sets DRY_RUN, but `_render_plan` (:135-158) never reads DRY_RUN, so it reprints the same plan.
    - The second read (:179) is ignored.
  - **Change** (only in the interactive branch; after B9.7 that branch is `INTERACTIVE=1`):
    - The prompt becomes `Install agent-secrets to $INSTALL_DIR and edit $RC_FILE? [Y/n] `. The capitalised default follows lib/ui.sh:39.
    - Loop on the reply:
      - empty, `y`, `Y` or `yes`: continue;
      - `n`, `N`, `no` or `q`: print `Canceled. Nothing was changed.` on stderr and exit 130;
      - EOF: the same as `n`;
      - anything else: print `Please answer y or n.` and ask again.
    - Remove `[d]` (:177-178) and the ignored second read (:179).
    - B9.10's INT trap prints the same receipt on Ctrl-C.
    - **Pass 2 fix (R019, R134).** Bound the loop as A.10 does: a 4th bad answer counts as a decline. Keep the logic inline and do not call `ui_confirm`, because lib/ui.sh is not unpacked until after the gate. `exit 130` is safe here: nothing is written before the gate, and the `exec` at lines 24 and 32 preserves the code. B8.14 adds 130 to AGENTS.md:160.
  - Enter still installs, so the change is compatible. A default-No variant (R147) is D9. **Pass 2:** local bats from a terminal needs this too. tests/install.bats:67, :77 and :88 wait for a real Enter there today (B10.5).
  - **Tests:** in B10, on a pty.
  - **Callers:**
    - No caller parses this prompt. A grep for "Enter] continue", "show the full dry-run" and "Ctrl-C stop" finds none.
    - install.bats:67 and :77 pipe stdin, so they take the non-TTY branch, as before.
    - README.md:94 ("Press Enter") is about the setup wizard.
- **B9.6 Discovery and import in the plan and the prompt** (R125, R001, R123). install.sh:144-156 and :346.
  - **Verified:**
    - :346 never checks NO_DISCOVERY, so a terminal user who passed `--no-discovery` is still asked.
    - The plan's TTY branch (:144) wins over the `--no-discovery` branch (:146).
    - On a TTY the plan says "interactive wizard" (:153) even with `--import-env`, although setup goes headless on `--import-env` (setup.sh:535, :538) and then defaults discovery on (:552).
  - **Change:**
    - The :346 guard also requires `[ "$NO_DISCOVERY" -eq 0 ] && [ -z "$IMPORT_ENV" ]`, and reads INTERACTIVE.
    - In `_render_plan`, test NO_DISCOVERY first.
    - The OFFER line (:145) and the wizard line (:153) need INTERACTIVE, HEADLESS=0 and an empty IMPORT_ENV. Otherwise the plan shows the headless line, which already names the import (:155).
    - Drop R013 from this finding's rule list, per its verdict.
    - **Pass 2 fix:** an Enter at the offer is still overridden on one path, and the offer still comes before the result. B11.4 moves the offer after setup (R123, R240) and adds a parity test against setup's own mode rules.
  - **Tests:** in B10.
  - **Callers:** only install.bats:143 uses `--no-discovery`. It runs without a TTY and asserts that CLAUDE.md is absent, so it is unchanged.
- **B9.7 One mode resolver** (R113, R116, R408, R112). install.sh:111-132 plus the inline checks.
  - **Measured** with `grep -n '\[ -t [012] \]' install.sh`: there are six inline code sites, not the seven the finding gives. :126 and :130 are inside `_attach_tty`; :144, :152, :174 and :346 are elsewhere.
  - **Change:**
    - Add `_resolve_mode`. It runs once after parsing and `_attach_tty`, and sets `INTERACTIVE=1` only when `[ -t 0 ] && [ -t 2 ]`, `${CI:-}` is empty, and `_agent_session` is false.
    - :144, :152, :174 and :346 read INTERACTIVE.
    - `_attach_tty` never re-attaches when `CI` is non-empty.
    - **Pass 2 fix (R113, R119, R116).** B11.6 has the details:
      - INTERACTIVE also requires an empty `AGENT_SECRETS_UNATTENDED`, and `_attach_tty` returns 1 when that variable is set.
      - The agent check resolves before the attach, and the TTY value after it, because line 129 rebinds stdin.
      - This row removes the keypress for agent sessions, for CI and for `2>log`. That conflicts with the "no env bypass" comments at :5 and :168, and D18 records it.
  - **Parity test:** the body of `_agent_session` (install.sh:111-118) must equal `agsec_in_agent_session` (lib/common.sh:158-165) once the names are normalised. This is a documented bootstrap duplicate (install.sh:108-110). **Pass 2 fix:** do not diff `_attach_tty` against `agsec_attach_tty`. They differ on purpose (:127-128 against lib/common.sh:187), so that diff would fail on arrival. Assert instead that the agent check comes before `exec 0</dev/tty` inside `_attach_tty`.
  - **Lint test:** `[ -t ` and `CI` appear in install.sh only inside `_attach_tty` and `_resolve_mode`. **Pass 2 fix:** the lint skips comment lines (the `[ -t 0 ]` in the comment at :120 would trip it). The allowlist is recorded as E11.
  - **Behaviour change:** on a terminal, `bash install.sh 2>log` becomes non-interactive and takes the no-terminal branch. Today it prompts on the redirected stderr and waits for Enter. This is covered by exception E2; the alternative is D11.
  - **Callers:** install.bats:110, :152, :159 and :172 run without a TTY and are unchanged.
- **B9.8 Dry run** (R325, R004, R105). install.sh:161-166, :195-200, :216-227.
  - **Preflight first.** Move the directory-conflict check (:195-200) above the dry-run branch. It only reads and already exits 1 naming the path. **Pass 2 fix:** do not move it. :4 makes consent the first screen. Per B11.2, the check stays where it is in the real run and also runs in the dry-run branch after `_render_plan`, so the plan still shows.
  - **Digest status as a plan line.** This is D12 option B, the compatible one. Dry run works out the same three-way outcome as :216-227 without downloading:
    - baked digest: `• verify the download against the baked SHA-256 digest`;
    - mirror: `• verify against the mirror's .sha256 (transport integrity only)`;
    - neither: `• REFUSE: this install.sh has no baked release digest; install from a published release tag`. The exit code stays 0; strict exit 1 is D12.
  - **Runnable next step.** Replace :164 with `Install with this plan:` followed by one indented command carrying the same flags, rebuilt from the parsed state and `%q`-quoted:
    - `bash <path> <flags>` when `$0` is a readable file;
    - otherwise `bash -c "$(curl -fsSL https://raw.githubusercontent.com/renchris/agent-secrets/v0.1.3/install.sh)" bash <flags>`.
    - **Pass 2 fix (R004, R103, R017).**
      - That fallback is the exact form README.md:64-75 warns about: a failed download runs an empty program and exits 0. Build both forms with `_self_cmd` (B9.14) and append the flags, as names only.
      - Reword the line so it does not overclaim. :164's "apply exactly this plan", and the header's "the rendered plan is exactly what executes" (:4), cannot be proven without network and mutation. Print `Local checks passed. To install with this plan (download and dependency steps were not checked):`, then the command. Correct the header at :4 to match.
      - On a would-refuse run (the REFUSE line above), print no install command. Print `Install from a published release tag, or set AGENT_SECRETS_BASE_URL.`.
  - **Dead code.** Remove the unreachable DRY_RUN branches at :81, :178, :243, :320, :346 and :397. The repo's own audit also notes them (docs/plans/v0.1-audit-findings.md:173).
  - **Tests:**
    - With a regular file at `~/bin`, `--dry-run` exits 1 with "not a directory" and creates nothing.
    - main's install.sh shows the REFUSE line and exits 0, so install.bats:51, :153 and one_command.bats:45 stay green.
    - The printed command passes the parse-only seam (B9.3f).
    - **Pass 2:**
      - `--dry-run --import-env 1BAD` exits 2.
      - On an unbaked copy, the output has `REFUSE` and no `Local checks passed`.
      - With `AGENT_SECRETS_BASE_URL` set, it has `Local checks passed`.
  - **Callers:** no caller parses the "Re-run without --dry-run" line; grep matches only install.sh:164.
- **B9.9 Download timeouts** (R313, R314, R019). install.sh:30, :213, :223.
  - **Change:**
    - :30, in the POSIX section: `curl -fsSL --connect-timeout 10 --max-time 120 --retry 3 --retry-connrefused`.
    - :213 and :223: the same flags with `--max-time 300`.
    - **Pass 2 fix (R313, R316). Do not add `--retry` to :30 as written.**
      - :30 captures curl's stdout in `$(…)`, and :32 then runs it. The verifier measured, with system curl 8.7.1 against a loopback server: a stall after a partial body gave rc=0 and captured `PARTIAL-FIRST-ATTEMPT-FULL-BODY-…`, which :32 would pass to `exec bash -c`.
      - :30 must download to a temp file with `-o` and read it only on success. The same fault with `-o` gave a clean 211-byte file. The exact code is in B12.1.
      - :213 and :223 go through one `_fetch` helper (B12.1), with `--connect-timeout 15 --max-time 120 --retry 3 --retry-connrefused --retry-max-time 300`. The payloads are small: the tarball is 88,105 bytes (the verifier's `ls -la`).
    - No `--proto '=https'` here; that is D13.
    - lib/deps.sh gets the same retry flags in B4.9, because B4 owns that file.
    - A failure at :213 or :223 names the host and a rerun command on its own line. Exit stays 1, and C7.1 restyles the message.
  - **Test:** with `AGSEC_MOCK_CURL_EXIT=28`, the run exits 1 and stderr names the host and the rerun command. The mock log shows `--connect-timeout`, `--max-time` and `--retry`.
  - **Callers:** tests/mocks/curl reads only `-o` and the URL, so it ignores the new flags. No test asserts the literal `curl -fsSL`.
- **B9.10 Real outcomes, signals and the temp work dir** (R003, R017, R187, R337, R339, R275; R335, R416, R294, R019, R336). install.sh:35, :209-236, :256-260, :285-286, :295, :301, :306, :321-323, :384-385.
  - **Verified:**
    - curl, shasum and tar failures exit with the tool's own code under `set -e`, with no installer message.
    - :285 swallows a manifest failure and then disarms the rollback trap at :286. The repo's own comment at :240-242 concedes the resulting half-wired state.
    - :322 swallows a launchctl bootstrap failure.
    - :384 says "Installed." before setup runs.
    - `$work` (:209) is never removed.
    - No INT, TERM or HUP trap exists.
  - **Change.** Keep the `%q`-baked trap strings, because main()'s locals are gone when EXIT fires (install.sh:253-255).
    - Track a global `_AGSEC_PHASE`, set before each step: download, verify, unpack, toolchain, wire PATH, launchd, setup.
    - Right after `mktemp -d` (:209), bake `printf -v _work_rm 'rm -rf -- %q' "$work"` and arm:
      - EXIT: run `$_work_rm`. On a non-zero `$?` it also prints `✗ Failed to install agent-secrets: <phase> failed.` and a recovery line, and maps any raw code (curl 22 or 56, tar 2) to exit 1.
      - INT, TERM and HUP: run `$_work_rm`, print `Canceled. Nothing was changed.`, and exit 130, 143 or 129. Nothing is written before the mkdir at :235, so the message is true.
    - At :260 (fresh install), the strings also run the existing `$_cleanup_cmd`.
    - At :286, replace `trap - EXIT` with a re-arm that drops the rm/rmdir part and keeps `$_work_rm` and the reporter. INT, TERM and HUP then print `Stopped. Partially installed (recorded in <manifest>). Undo: <bin>/agent-secrets uninstall --dry-run` and exit 130.
    - Before setup (:385), INT prints `Installed; setup was interrupted. Re-run: agent-secrets setup`.
    - **Pass 2 fix (R294, R337, R341).** B12.5 has the details.
      - "Canceled. Nothing was changed." holds only up to :235. A signal in the unpack window has its own message.
      - After :286, the exit is 130, 143 or 129 by signal, not always 130.
      - The handler reads globals, not main()'s locals (the comment at :253-255 records why).
      - :385 stays a child, not `exec`. See D19.
    - Do not use a bare `trap ERR`: `_die`'s explicit `exit 1` never fires ERR.
    - :285 becomes `manifest_record_file "$INSTALL_DIR" >/dev/null || _die "Couldn't record $INSTALL_DIR in the install manifest."`, placed before the re-arm so the cleanup still runs and install.bats:159-185 stay green. :295, :301 and :306 get the same guard, with the uninstall recovery command.
    - :322: check `launchctl bootstrap`. On failure, warn `! Couldn't load the weekly smoke job ($SMOKE_LABEL). Run agent-secrets doctor later.` and continue; it fails legitimately over SSH or with no GUI session. Still record the plist so uninstall removes it.
    - :384 becomes `Tool installed. Running setup…`. After setup:
      - on success, print `Installed agent-secrets v0.1.3.`;
      - on failure, print `✗ Setup failed (exit N). The tool is installed but not configured.`, then `Finish setup:` with `    <bin>/agent-secrets setup`, then `Or remove it:` with `    <bin>/agent-secrets uninstall`, and exit N. Passing N through is D14.
  - **Tests:**
    - With `AGSEC_MOCK_LAUNCHCTL_BOOTSTRAP_FAIL=1`, the run exits 0 and stderr warns "Couldn't load the weekly smoke job".
    - With `AGENT_SECRETS_UNATTENDED=1 AGENT_SECRETS_SEED_NAME=bad-name`, setup dies at setup.sh:306. The installer exits 1, prints "Setup failed (exit 1)", and does not print "Installed agent-secrets".
    - A jq shim that fails only when its argv contains the INSTALL_DIR path makes the run exit 1, and the fresh tool dir is removed.
    - With `AGSEC_MOCK_CURL_SLEEP=5`, TERM during the download gives status 143, "Canceled. Nothing was changed.", no `~/.agent-secrets`, and an empty per-test `TMPDIR`.
    - After a successful install, the per-test `TMPDIR` is empty: the work dir is gone.
  - **Callers:**
    - No caller depends on raw curl or tar codes, or on the "Installed. Running setup…" text (grep).
    - The new trap code must stay shellcheck-clean (ci.yml:23).
    - cmd/doctor.sh:31 keeps matching `SMOKE_LABEL`.
- **B9.11 A fuller plan preview** (R001, R002, R148, R179, R326). `_render_plan` (:135-158). This change adds lines only.
  - **Reinstall or upgrade.** If `$INSTALL_DIR/VERSION` exists, print `agent-secrets 0.1.3 is already installed at <dir>. Reinstalling v0.1.3 over it.` or `Upgrading 0.1.2 to v0.1.3.`. These are plain reads, so dry run still mutates nothing. **Pass 2:** B11.3 adds the same-version repair wording and the downgrade warning.
  - **Files in `~/bin` that will be replaced.** Check each of agent-secrets, claude-agent, cursor-agent and apiKeyHelper with `[ -f ] && [ ! -L ]`, the same test `_bak_user_target` uses (:292). For each hit, print `• replace your existing <path> (backed up to <state>/<f>.preinstall.bak; uninstall restores it)`. **Pass 2 fix (R350):** `[ -f ] && [ ! -L ]` misses a foreign symlink, which B13.1 now backs up. Use `_target_is_foreign`, defined in B13.1, and keep :140 byte-identical (tests/install.bats:55).
  - **Discovery targets** on the no-TTY path (:149): name the static candidate set, `~/.claude/CLAUDE.md, plus whichever of the Codex, Gemini, Zed and Cline rule files exist`. **Pass 2 fix (R001, R002):** name the exact paths; B11.3 lists them.
    - Do not call `agsec_discovery_plan` here. lib/discovery.sh arrives inside the tarball and is sourced only at :278, after the plan.
    - Headless setup names each file before writing it (setup.sh:371).
  - **Homebrew.** The bullet at :138 says `brew install` of any of age, sops and jq not already on PATH. deps.sh:170-172 installs only those three.
  - **Tests:**
    - With an existing regular `~/bin/claude-agent`, the dry run names its backup path.
    - With an unpacked VERSION file present, it says "already installed" or "Upgrading".
    - The :55-57 substrings still match.
- **B9.12 File writes** (R350, R351, R071). install.sh:290-297, :310/:314, :395-419.
  - **Backups that are never refreshed (`_bak_user_target`).**
    - Today a write-once backup (:294) means a newer user file at a `~/bin` target is lost on reinstall: `ln -sf` overwrites it and uninstall restores the old backup.
    - Change: when `$b` exists and `cmp -s "$t" "$b"` fails, rename the old backup to `$b.<YYYYmmddHHMMSS>` and say so on stderr. Then write a fresh backup through a sibling `mktemp` plus `mv`, keeping the same path and the single `manifest_record_edit "$t" "$b"`.
    - Do not add a second edit record: LIFO rollback would restore the stale backup last.
  - **Plist.** Write it to `mktemp "$plist.XXXXXX"`, `chmod 0644`, then `mv -f`. Today `cat >"$plist"` writes in place (:398).
    - **Pass 2 fix (R351).**
      - Use `mktemp "$(dirname "$plist")/.smoke.XXXXXX"`.
      - If `$plist` is a symlink, write through it and remove the temp file, following lib/manifest.sh `_manifest_replace` (:27), so dotfile-managed links survive.
      - Remove the temp file on failure, or uninstall's `rmdir` of LaunchAgents (cmd/uninstall.sh:84) finds the directory non-empty.
  - **XML escaping.** Escape `&`, `<` and `>` in `install_dir` for :406 and :412, using bash 3.2 `${x//&/&amp;}`.
    - **Pass 2 fix (R071):** use `install_dir_xml=$(printf '%s' "$install_dir" | LC_ALL=C sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g')`, once at the top of `_install_smoke_plist`. `&` in a `${x//…}` replacement is unsafe under newer bash (§1, pass 2 gates). `${label}` is the constant at :75 and stays as it is. The `$plist` target path stays raw. The verifier measured with plistlib that a raw `&` or `<` is rejected and the escaped forms decode to the original path.
  - **rc line** (:310, :314).
    - Do not put `%q` output inside the existing double quotes; that changes the meaning.
    - Instead, before any write, `_die` if BIN_DIR contains `"`, `$`, a backtick or a backslash.
    - This is compatible: nothing parses the line text, because pathblock removal keys on the marker (lib/manifest.sh:97-114).
    - **Pass 2 fix (R071).** Escape instead of refusing. tests/install.bats:172 already treats an exotic `AGENT_SECRETS_HOME` as supported, and refusing would turn a working install into exit 1.
      ```sh
      _dq_escape() { local s=$1; s=${s//\\/\\\\}; s=${s//\"/\\\"}; s=${s//\$/\\\$}; s=${s//\`/\\\`}; printf '%s' "$s"; }
      "export PATH=\"$(_dq_escape "$BIN_DIR"):\$PATH\""
      ```
      - Ordinary paths stay byte-identical.
      - The verifier measured under bash 3.2.57, bash 5.3.15 and `zsh -f`: today's line form ran `$(x)` and `` `y` ``, while this form round-tripped the path literally and ran nothing.
  - Drop R015 from this finding's rule list, per its verdict.
  - **Tests:**
    - Reinstalling over a user file F2 while an older `.preinstall.bak` exists: uninstall restores F2, and the old backup survives under its timestamped name.
    - An `AGENT_SECRETS_HOME` containing `&` yields a plist that `plutil -lint` accepts.
    - An `AGENT_SECRETS_HOME` containing `"` exits 1 before any write. **Pass 2 fix:** replaced. An `AGENT_SECRETS_HOME` containing `"`, `$(x)` and `&` installs. Sourcing the rc block yields the literal path and runs nothing, and the plist holds `&amp;`. Where `plutil` is absent, assert the `&amp;` text alone.
- **B9.13 Name the opt-outs on the no-terminal path** (supports E1). install.sh:182 and :184.
  - The message becomes `(no terminal: proceeding with the plan above; --dry-run previews, --no-discovery skips the machine-wide rules)`. The agent-session line gets the same tail. **Pass 2 fix (R046):** say "agent rules", not "machine-wide rules" (C7.2 settles that noun).
  - This is compatible: no test matches these lines, and the wording never contains "real terminal" (install.bats:155).

### B10 (new): install.sh PTY suite
**Files:** `tests/install_tty.bats` (new). It loads `tests/install_helper.bash` and `tests/mode_matrix.bash`.

**Size:** about 170 LOC (estimated). Lands after B9.

**Harness:** modelled on tests/one_command.bats:89-110.
- Agent variables and CI are unset.
- rc 99 means `expect` is missing, which is a skip and must be reported per the §1 gate.
- Any other non-zero rc is a failure.
- **Consent prompt (B9.5).** The prompt comes before any download, so a decline needs no mirror.
  - `n\r`: exit 130, `Canceled. Nothing was changed.`, no `$AGENT_SECRETS_HOME/.agent-secrets`, and an empty curl log.
  - `xyz\r` then `n\r`: `Please answer y or n.`, then exit 130.
  - Ctrl-C (`\003`) at the prompt: exit 130 with the same receipt.
  - With the baked mirror fixture and `--headless`, Enter installs (exit 0).
- **`--no-discovery` on a TTY (B9.6).** Enter at consent, then drive the wizard as one_command.bats:99-100 does (`n`, then `4`).
  - Assert "Make every coding agent" never appears.
  - Assert the plan says "skip the machine-wide agent rules".
  - Assert exit 0 and no `~/.claude/CLAUDE.md`.
- **`--import-env X` on a TTY (B9.6).** The plan says headless and names X. Then send `n`, which exits 130.
- **Mode matrix for the consent prompt (R403),** using `mm_run`. It uses the default URL with no mirror, so after consent the run fails at the download and nothing is mutated. Exit 1 therefore means "got past consent".
  - `tty`, `stdout-redirected`: the prompt appears.
  - `stdin-piped` (no controlling terminal), `ci-tty`, `agent`: no prompt, the no-terminal message, exit 1.
  - `json-tty`: install has no `--json`, so it exits 2.
  - `noninteractive-tty`: depends on D10. Until D10 is decided, `--non-interactive` is an unknown option and exits 2; assert that.
- **R401/R404 transcripts.** Capture the plan at `COLUMNS` 40, 80 and 120 in plain mode and attach them to the PR. Assert that C7.2's wrap rule holds once C7 lands (C7 extends the test).

### Round 2, pass 2: install.sh serial track, and rows for B4-B8

Source: 31 verified findings on unit `agent-secrets-install`. §8 maps each finding to its rows. Every row was re-read against the code at `5266599`. "The verifier measured" means the verdict in the input JSON measured it; this pass read files only.

**Unit split.** install.sh cannot be split into files, because it runs before lib/ is unpacked (install.sh:108, :265). So its units run serially on one branch, and only one holds the file at a time. Each owns its own test file. Where an older row says `tests/install.bats`, its test goes in the test file of the unit that now owns the row. Each new test file loads `test_helper` and `tests/install_helper.bash`, which also carries install.bats's `teardown` (it removes `$MIRROR`).

| Unit | Starts after | Rows | Test file it owns | Est. LOC |
|---|---|---|---|---|
| B9 parse and help | A2 | B9.1-B9.4, B9.14-B9.16 | tests/install.bats, tests/install_helper.bash (new) | ~340 |
| B11 mode, consent, plan | B9, B6 | B9.5-B9.8, B9.11, B9.13, B11.1-B11.6 | tests/install_plan.bats (new) | ~440 |
| B12 download, outcomes, signals | B11 | B9.9, B9.10, B12.1-B12.5 | tests/install_failure.bats (new) | ~430 |
| B13 writes and concurrency | B12, B5 | B9.12, B13.1-B13.3 | tests/install_writes.bats (new) | ~330 |
| B10 PTY suite | B13 | B10 rows above, B10.1-B10.5 | tests/install_tty.bats (new); one wrap line each in tests/one_command.bats:45 and tests/audit_regressions.bats:106 | ~300 |

**Shared design for B12 and B13.** Findings 14, 15, 16 and 26 all touch the EXIT trap, so there is one design:
- One global, `_AGSEC_CLEANUP_CMD`, holds the `%q`-baked commands. Each step re-arms by rebuilding the string.
- One handler, `_agsec_on_exit`, saves `$?`, evals the string, prints the failure report, and exits with the saved code (mapped as in B9.10).
- The comment at :253-255 rules out a named handler only for one that reads main()'s locals. This handler reads globals only.
- C8 hooks the same handler for its error document.

#### B9: parse and help

- **B9.14 Runnable next steps** (R004, R235, R103, R105). install.sh:103, :164, :198, :367; new helper after :81.
  - **Verified:**
    - :103 prints `install.sh --help`. That file does not exist under `curl | bash` or in the documented form, which saves it as /tmp/agent-secrets-install.sh (README.md:58, AGENTS.md:44-45).
    - :164 and :198 are prose with no command.
    - :367 says to re-run the installer, while cmd/setup.sh:369 records `setup --discovery` as the replacement for that advice.
  - **Change:** add `_self_cmd`.
    - If `$0` is a real file by B9.15's test, print `bash <%q of $0>`.
    - Otherwise print one unwrapped line: `f="$(mktemp "${TMPDIR:-/tmp}/agent-secrets-install.XXXXXX")" && curl -fsSL <URL> -o "$f" && bash "$f"`, where `<URL>` is `_agsec_show_url` of the install URL.
    - If `AGENT_SECRETS_BASE_URL` is set, prefix the bash step with the placeholder `AGENT_SECRETS_BASE_URL=<URL>`. Never echo the value, because a mirror URL can hold credentials (R355).
    - Add no new version literal.
    - Consumers: `_usage_die` (B9.2), the dry-run line (B9.8), :198 (C7.1 prints `mv <path> <path>.bak` first, because required recovery goes first per R236).
    - :367 becomes `  → skipped the agent rules. Add them later:` and then `      <%q $BIN_DIR>/agent-secrets setup --discovery`. Use `$BIN_DIR`, not a literal `~/bin`: BIN_DIR derives from `AGENT_SECRETS_HOME` (:55). B11.4 moves this line after setup, so the symlink exists by then.
  - **Tests:**
    - `--bogus` prints the helper's command line.
    - A dry run with `--headless --no-discovery` prints a command with those flags (R103).
    - `AGENT_SECRETS_BASE_URL='https://u:SEKRET@mirror.example' … --bogus` prints no `SEKRET`.
    - In the pipe form (`sh -s -- --bogus < install.sh`, with a mock mirror), the printed line starts with `f=` and has no hard wrap.
  - **Callers:** no test or script pins these strings (`grep -rn 're-run the installer' tests` found none; the verdict's whole-repo grep agrees). The substring `not a directory` at audit_regressions.bats:109 survives. R099 is dropped from this finding, because every printed command uses long options.
- **B9.15 The `sh` re-exec guard** (R470, R011). install.sh:6, :19-20, :24, :30. Decisions D13 and D23.
  - **Verified:**
    - :24 tests `[ -f "$0" ]`, and under `curl … | sh`, `$0` is `sh`. The verifier measured with a synthetic copy of the guard: with a `./sh` present, `cat probe | sh` and `sh -c "$(cat probe)"` both ran the planted file.
    - With `| /bin/sh`, `$0` is `/bin/sh`, `bash /bin/sh` fails with rc 126, and the piped install dies. The finding missed this.
    - :6 says to verify "any artifact", but :32 runs re-fetched text with no digest. install.sh is the trust root (:46-47), so the defect is line 6's wording, not a missing check.
  - **Change:** replace :24 with a POSIX-clean basename check.
    ```sh
    case "${0##*/}" in
      sh|-sh|ash|-ash|dash|-dash|bash|-bash|ksh|-ksh|mksh|zsh|-zsh|busybox) ;;   # $0 names the shell, not a script
      *) if [ -f "$0" ]; then exec bash "$0" "$@"; fi ;;
    esac
    ```
    - Do not use the finding's slash rule. `sh install.sh` has no slash (the verifier's probe printed `dollar0=inst.sh`), and `| /bin/sh` has one.
    - An installer saved literally as `sh` now re-fetches. That is the only behaviour change.
    - Under D23(A): narrow :6 to the tarball and dependency binaries, and state in :19-20 and docs/FAQ.md:71 (B8.18) that `AGENT_SECRETS_INSTALL_URL` replaces the trust root unverified.
  - **Tests** (curl mock serving a baked `install.sh` from `$MIRROR`):
    - A planted `./sh` that writes a marker file does not run under `sh -s`.
    - `/bin/sh -s` reaches the re-fetch.
    - `/bin/sh "$baked"` stays the file case (tests/install.bats:103).
  - **Callers:** tests/install.bats:103 runs a path ending in `install.sh`, so it is unaffected. README.md:58, AGENTS.md:44-45 and README.md:129 use `bash` with a file and never enter the guard. R043 and R371 are dropped from this finding (§5).
- **B9.16 Do not leak the sentinel** (R079). install.sh:22-33.
  - **Verified:** `AGSEC_REEXECED` appears only at install.sh:18, :22 and :23 (grep). It is exported, so setup and everything below inherit it. An inherited value also skips the guard; the failure is loud, at the process substitution in lib/manifest.sh:200.
  - **Change:** `unset AGSEC_REEXECED` right after the closing `fi` at :33, plus a comment. A rename alone does not cure the inherited-value case, and renaming is D15.
  - **Test:** a setup argv and environment log shim shows no `AGSEC_REEXECED` in setup's environment.
  - **Callers:** nothing else reads it. `AGENT_SECRETS_VENDOR_BIN` (:273, tests/deps.bats:64) and `AGENT_SECRETS_BIN` (:342, tests/discovery.bats:45) keep their names and stay out of help.
  - The help parity test belongs here too: every option in the parser appears in `_agsec_usage`, and the reverse (R087, recorded as E9).

#### B11: mode, consent, plan

- **B11.1 Correct the consent claims** (R010, R014, R006). install.sh:3-5, :168-173, :338; SECURITY.md:65 through B8.16.
  - **Verified:**
    - :5 and :168 say consent has no `--force`/env bypass. But :182-186 proceed with no terminal, and `_agent_session` reads environment variables. So `CLAUDECODE=1 … </dev/null` at a real terminal skips the gate. "No TTY" is narrower than the finding says, because `_attach_tty` rebinds to `/dev/tty` otherwise (:125-132).
    - :338 says "a piped/CI install NEVER silently edits a global file". Headless setup writes the rules by default (setup.sh:552).
  - **Change:** comments only.
    - State the tier and the no-TTY rule, and state that a detected agent or CI session counts as no human present (D18).
    - Remove "NO --force/env bypass" and the :338 sentence.
    - Keep "STOP-ASK" for the uninstall purge gate (cmd/uninstall.sh:34), which is the repo's own usage for data loss.
    - If the operator picks D18 option 2, or D10(c), C7.4 re-words these.
  - **Tests:** none for the comments. B10's matrix pins the behaviour they describe.
- **B11.2 Preflight reports everything, in the dry run too** (R302, R325, R015). install.sh:195-200.
  - **Verified:**
    - The loop dies at the first conflict and omits Library/LaunchAgents (:318) and the rc files.
    - `[ -e ]` is false beneath a regular-file parent, so a regular file at `~/.local` is not caught today.
  - **Change:** extract `_preflight_dirs`, keeping the load-bearing `if` form.
    - Directory targets: INSTALL_DIR, BIN_DIR, STATE_DIR, `$HOME_DIR/Library/LaunchAgents`, and their ancestors `$HOME_DIR/Library`, `$HOME_DIR/.local` and `$HOME_DIR/.local/state`.
    - rc paths use the **inverse** test: a conflict only if `[ -d "$rc" ]`. Adding them to the existing `! -d` loop would refuse every healthy ~/.zshenv, including the symlinked one pinned at tests/audit_regressions.bats:17-22.
    - Collect every problem and print at most 5 (R302), keeping the text `not a directory`. Then exit 1.
    - Call it at its current position in the real run, and in the dry-run branch after `_render_plan` (B9.8's "preflight first").
  - **Tests:**
    - A regular file at `~/bin` and another at `~/Library` are both named, with exit 1, and nothing is created.
    - A regular file at `~/.local` is caught.
    - A symlinked `~/.zshenv` passes.
    - A directory at `~/.zshenv` is named.
  - **Callers:** audit_regressions.bats:106 still sees `not a directory` and no residue. Each dry-run test gets a fresh HOME (tests/test_helper.bash:7), so preflight cannot trip it.
- **B11.3 The plan shows exact targets, the replaced install and the real trust** (R001, R002, R148, R140, R017). `_render_plan` (:135-158), :229.
  - **Verified:**
    - :143, :145 and :149 hardcode `~/.claude`, while the discovery writes follow lib/discovery.sh:26-27 and :153-156.
    - `_run` echoes the curl URL at :213, but only after consent and never in a dry run, so no Source row exists (R140).
    - :139 and :229 claim "SHA-256 verified" on the unbaked mirror path, which :221-222 call transport integrity only.
  - **Change** (text only, all on stderr; no prompt, exit code or refusal):
    - **:143:** keep the pinned text `back up an existing ~/.claude/settings.json`, and append ` (at $HOME_DIR/.claude/settings.json)` only when HOME_DIR differs from HOME. Do **not** use the `CLAUDE_CONFIG_DIR` directory here: lib/wire.sh:20 writes `$(agsec_home)/.claude/settings.json` and ignores that variable. The finding's fix would make this line false and break tests/install.bats:56.
    - **:145 and :149:** compute the directory as lib/discovery.sh:26-27 does (inlined, because the lib is not unpacked yet). Name `$CLAUDE_DIR/CLAUDE.md`, and also `$HOME_DIR/.claude/CLAUDE.md` when they differ (lib/discovery.sh:153-156).
    - **:149:** list the conditional files by path, one row each, marked "if that tool's config dir exists":
      - `${CODEX_HOME:-$HOME_DIR/.codex}/AGENTS.md` (with `AGENT_SECRETS_HOME` set, always `$AGENT_SECRETS_HOME/.codex`, lib/discovery.sh:31-34);
      - `$HOME_DIR/.gemini/GEMINI.md`;
      - `$HOME_DIR/.config/zed/AGENTS.md`;
      - `$HOME_DIR/.agents/AGENTS.md`.
      - Also say that org/MDM-managed machines are deferred.
    - **Source rows,** in `_render_plan` so dry run shows them: `Source: $BASE_URL (AGENT_SECRETS_BASE_URL)` through `_agsec_show_url`, and `Source: $HOME_DIR (AGENT_SECRETS_HOME)`, each only when that variable is set.
    - **Trust wording** keys on `EXPECTED_SHA256`, not on BASE_URL. A baked digest keeps `pinned $PINNED_TAG, SHA-256 verified` and the exact line `SHA-256 verified.`, even on a mirror. With no digest and a mirror, :139 and :229 say the artifact was checked only against the mirror's own .sha256, which is transport integrity and not tamper evidence. `SHA-256 mismatch` stays.
    - **Reinstall rows (R326), extending B9.11.** Same version: `agent-secrets vX is already installed. Re-applying it to repair dependencies, wiring and agent rules.` Older installed version: `Upgrading agent-secrets vOLD to vNEW.` Newer installed version: `Warning: this downgrades agent-secrets vNEW to vOLD.` Compare numerically by splitting on dots (bash 3.2). The downgrade only warns, with no prompt and no new exit code, because a downgrade may be deliberate. No rule covers downgrades; this is an addition.
    - **End of plan.** Print `Some effects cannot be undone.` (R148) only when an existing install will be replaced, because the old tree has no backup.
  - **Tests:**
    - A test compares the :149 path list with `AGSEC_DISCOVERY_KEYS` (lib/discovery.sh:50), so a new harness cannot drift out of the plan.
    - `AGENT_SECRETS_BASE_URL` set: a Source row appears.
    - A baked digest on a mirror keeps `SHA-256 verified`.
    - An unbaked copy on a mirror says `.sha256` and not `SHA-256 verified`, and tests/install.bats:79 still sees `SHA-256 mismatch`.
    - With VERSION present: `already installed` and `Upgrading`, plus a higher VERSION gives `downgrades`.
  - **Callers:** the pins are tests/install.bats:55-57, :89, :105, :155-156 and tests/one_command.bats:49. `SHA-256 verified` at :89 and :105 runs on baked paths only, so it stays.
- **B11.4 The offer comes after the result, and a decline holds** (R123, R240, R125, R154, R340, R001). install.sh:144-156, :346-370, :380-385; cmd/setup.sh:423 through B6.16. Extends B9.6.
  - **Verified (all three paths, by reading):**
    - **Decline overridden.** `--import-env X` on a terminal: :153 promises the wizard, :345-356 offer discovery, Enter prints "skipped", :382-383 forward only `--import-env`, and setup goes headless (setup.sh:535) and defaults DISCOVERY=1 (:552). B9.6's `[ -z "$IMPORT_ENV" ]` closes this one.
    - **Agent on a terminal.** `_attach_tty` returns at :126 before the agent check, the offer runs, and setup goes headless at :548 and writes. B9.7's INTERACTIVE closes this one.
    - **Timing.** The offer runs before setup, so it is not "after the result".
  - **Change:**
    - Move the block at :346-370 to after setup (:385). Keep the `AGENT_SECRETS_BIN` export at :342 before setup. Move the OFFER plan bullet after the run-setup bullet.
    - `_run` is not an `exec`, so control returns; `set -e` means a failed setup shows no offer. This depends on D19(a).
    - The offer runs only on the wizard path, where setup defaults DISCOVERY=0 (setup.sh:552), so an Enter there cannot be overridden.
    - A decline keeps exit 0 and prints no `Canceled.` (R340).
    - `--discovery` (B9.3) writes the rules without asking, and `--no-discovery` skips the offer.
  - **Tests:** B10.2 on a pty; dry-run wording here.
  - **Callers:** `git grep` finds `skipped machine-wide` and `re-running the installer` nowhere outside install.sh. No caller feeds a fixed keystroke sequence to install.sh on a pty. tests/one_command.bats:96 and tests/wizard_interactive.bats:119 and :152 spawn `agent-secrets setup` directly. tests/install.bats:131 pins that discovery is written in an agent session, and it stays.
  - **If D19(b) is chosen:** keep the offer before setup, record a decline, and append `--no-discovery` to setup_args at :383. Setup reads DISCOVERY only at setup.sh:531, :552, :570 and :585, so forwarding is safe.
- **B11.5 Copy never promises reversibility** (R157). install.sh:149, :151, :352. Decision D22.
  - **Verified:** :149 says "advisory, reversible", :352 says "short, reversible, advisory block … (uninstall removes them)", and :151 says "record every change … (one-command uninstall)". The critic's note that no such copy exists was wrong for install.sh (§8).
    - :151 is false on a Homebrew machine: lib/deps.sh:172 runs `brew install`, and no code uninstalls it (the verifier's grep).
    - `_manifest_strip_block` keeps everything when an end marker is missing (lib/manifest.sh:128-130, :147), so "uninstall removes them" has an exception.
  - **Change** (copy only, using single quotes inside the double-quoted `_say` strings, see §1 pass 2 gates):
    - :149: `… so agents in every repo know to use it: advisory; recorded in the manifest; --no-discovery skips`.
    - :151: `record each file, PATH block, launchd job and settings.json edit in $STATE_DIR/install-manifest.json ('agent-secrets uninstall' rolls back recorded entries; Homebrew-installed tools are not recorded)`.
    - :352: `This writes a short, advisory block into each of these files (recorded in the manifest; agent-secrets uninstall removes recorded blocks):`.
    - B6.16 and B8.17 make the same change in setup.sh:385, wire.sh:69 and help.sh:38.
  - **Test:** `--dry-run` output has no `reversible` and no `one-command uninstall`.
  - **Callers:** no test pins these strings. The `reversible` hits at tests/headless.bats:123 and :157 are a test title and a comment.
- **B11.6 The mode resolver's details** (R113, R117, R119, R014, R116). install.sh:120-132; `_resolve_mode` from B9.7.
  - **Verified:**
    - No code reads `CI` or tests stderr (the verifier's grep over bin, cmd, lib and install.sh).
    - The prompts go to stderr, so `2>log` hides them while `read` blocks.
    - On a machine with a usable /dev/tty, the rebind at :129 fires even with `AGENT_SECRETS_UNATTENDED`. tests/install.bats:88 and :103 pipe a seed line (AGENTS.md:152, setup.sh:297), and the rebind discards it.
  - **Change:**
    - Resolve in two steps. Set `AGENT` before `_attach_tty`, and have `_attach_tty` read it. Set the TTY state after `_attach_tty`, because :129 rebinds stdin.
    - `_attach_tty` returns 1 when `AGENT_SECRETS_UNATTENDED` or `CI` is set, or when `AGENT` is 1.
    - Keep HEADLESS as the flag variable. :381 forwards it to setup. Assigning an effective mode to it would pass `--headless` on every no-TTY install, change `HEADLESS_WHY` (setup.sh:530 against :548-549) and change the UNATTENDED discovery default (:552), which tests/install.bats:88 runs through.
    - setup.sh must match, or the plan lies: B6.13 adds the `! -t 2` branch, and B6.2 already covers CI.
    - Do not add CI to `agsec_in_agent_session`. It also drives `share`'s refusal and lib/store.sh:88.
    - The rebind itself is D17. Until it is answered, the rebind stays (E2).
  - **Tests** (no pty):
    - `AGENT_SECRETS_UNATTENDED=1` with a piped seed under `mm_no_ctty` stores the seed.
    - `CI=1 … --dry-run </dev/null` renders the headless plan.
    - B10.3 has the pty cases.
  - **Callers:** tests/install.bats:119 and :153-155, tests/headless.bats:18 (`coding-agent session`) and tests/one_command.bats:77 (`no terminal attached`) keep their strings. A.16 already unsets CI for the PTY wizard drives, so the verdict's `-u CI` edits are not needed.

#### B12: download, outcomes, signals

- **B12.1 One `_fetch`, with redaction, retry notice and classified failure** (R313, R314, R316, R019, R296, R275, R355, R018). install.sh:30, :31, :81, :213, :223. Decision D25.
  - **Verified:** none of the three curl calls has a timeout or a retry. `_run` prints its whole argv, so a credentialed mirror URL lands in a transcript (:7 names private-repo mirrors, and :109-110 treat transcripts as secret-bearing). :31 prints the install URL the same way.
  - **One wrapper across the whole repo is not possible:** :30 is above `set -e` (POSIX only), :213 runs before lib/ exists, install.sh is export-ignored from the tarball (.gitattributes:10), and tests/deps.bats:10 sources lib/deps.sh alone. Two definitions stay: `_fetch` here and `_deps_curl` in lib/deps.sh. B4.13 pins the second.
  - **Change, POSIX part** (above the guard, so no `local`):
    ```sh
    _agsec_show_url() { _u="$1"; case "$_u" in *://*@*) _u="${_u%%://*}://***@${_u##*@}" ;; esac; printf '%s\n' "${_u%%[?#]*}"; }
    ```
    - It masks through the last `@` before stripping the query and fragment. The verifier ran it on 9 URLs under `bash` and `sh` with 0 secret lines, and the 3 credential-free URLs came through unchanged.
    - :30:
      ```sh
      _agsec_tmp="$(mktemp)" || exit 1
      if curl -fsSL --connect-timeout 15 --max-time 120 --retry 3 --retry-connrefused --retry-max-time 300 "$_agsec_self_url" -o "$_agsec_tmp"; then _agsec_src="$(cat "$_agsec_tmp")"; else _agsec_src=""; fi
      rm -f "$_agsec_tmp"
      ```
    - :31 prints `_agsec_show_url` of the URL, and the default URL stays byte-identical. C7.1 corrects its stale recovery text.
  - **Change, bash part** (inside main):
    - `_fetch URL OUT` prints `_step "curl $(_agsec_show_url "$1") -o $2"`, then runs curl with `-fL`, the same budget, and `2> >(_retry_notice)`.
    - Use `--no-progress-meter` and not `-sS`. Under `-sS`, curl's retry prints nothing, and with `--no-progress-meter` it prints `Will retry` (the verifier measured both). The option needs curl 7.67.0 or later, so probe with `curl --no-progress-meter --version` and fall back to `-sS`. The fallback was not tested on an old curl.
    - `_retry_notice` rewrites `*Will retry*` lines to `Retrying automatically…`, passes other lines through, and adds `Retries: N` at EOF when the last line starts with `curl: (`. The verifier measured it under /bin/bash 3.2: success after one retry gave rc 0, an exhausted budget gave rc 7 with `Retries: 2`, and a 404 gave rc 22 with one server hit.
    - :213 and :223 become `_fetch "$url" "$pkg" || _fetch_die "$url" "$?"`.
    - `_fetch_die` keeps curl's own stderr line above the headline and exits 1 (AGENTS.md:160). Exit 6, 7 or 28 gives `Couldn't reach <host>.`. Any other code gives `Couldn't download <file> from <host>.` with a `curl exit: N` row and the redacted URL. Do not map every failure to "reach": README.md:70 records exit 56 for a 404 on the real host, while the mock and loopback give 22, so codes other than those three do not say why it failed (R275).
    - Recovery is `_self_cmd` on its own line. C7.1 restyles the layout.
    - Do not use `--retry-all-errors` (it retries a 404) or a hand-rolled loop keyed on exit codes.
  - **Tests** (A2's knobs):
    - `AGSEC_MOCK_CURL_EXIT=28`: exit 1, `Couldn't reach`, the host, a rerun command.
    - `AGSEC_MOCK_CURL_EXIT=22`: exit 1, `Couldn't download`, `curl exit: 22`.
    - The mock log shows `--connect-timeout`, `--max-time`, `--retry` and `--retry-max-time` on every call.
    - `AGSEC_MOCK_CURL_RETRY_NOTE=1`: stderr has `Retrying automatically…` and no `Will retry`.
    - `AGENT_SECRETS_BASE_URL='https://u:SEKRET@mirror.example'` with a mock mirror: no `SEKRET` in the output, and the install succeeds.
    - `AGENT_SECRETS_INSTALL_URL` with a credential and a failed re-fetch through `sh -s`: :31 prints no credential.
  - **Callers:**
    - tests/mocks/curl:19 finds the URL by scanning argv for `http*://*`, so the URL must stay in argv. This row redacts the display only (D25).
    - The mock ignores unknown flags and has no `-w` output, so a loop keyed on `%{http_code}` would see nothing.
    - No test asserts curl flags, the `_run` trace or the `Downloading` line (the verdicts' grep).
    - The pins `no baked release digest` (tests/install.bats:69) and `SHA-256 mismatch` (:79) are untouched.
    - scripts/telemetry-gate.sh:24 matches only env or base64 piped into curl (read, not run).
  - **Residual limits:** E14.
- **B12.2 The digest refusal comes before the download** (R302, R015). install.sh:209, :213, :225-226.
  - **Verified:** on an unbaked copy with no mirror, :213 downloads and only then does :226 refuse.
  - **Change:** after the consent gate, in the preflight block before `mktemp` at :209: `if [ -z "$EXPECTED_SHA256" ] && [ -z "${AGENT_SECRETS_BASE_URL:-}" ]; then _die "…no baked release digest…"; fi`. Remove the now-dead `else` arm at :225-226. Keep the text `no baked release digest`. Do not write a second `EXPECTED_SHA256="…"` literal. It must stay after the dry-run return (:161-166), because three tests run `--dry-run` on the unbaked copy and need exit 0 (D12), and after consent, because :4 and :160 define consent as the first screen.
  - **Test:** with `AGSEC_MOCK_CURL_LOG` set, an unbaked run has status ≠ 0, the pinned phrase, and an empty log.
  - **Callers:** tests/install.bats:67-70 does not depend on the download happening first. tests/install.bats:77-80 (mirror) still downloads.
- **B12.3 Fresh-install failures leave nothing, and cleanup removes only what this run made** (R015, R318, R007). install.sh:209, :234-236, :243-244, :256-261, :286.
  - **Verified:**
    - The trap arms at :260, after :235-244. So a partial mkdir, a tar failure or the layout `_die` leaves an unrecorded `~/.agent-secrets`.
    - The next run sees that directory at :234 and never arms the trap.
    - :258's `rmdir` removes a pre-existing empty `~/bin`, against the comment at :249.
    - The `~/.local` and `~/.local/state` parents this run made stay behind.
    - `$work` from :209 is never removed.
    - No test covers these paths: tests/install.bats:159-183 fail only after :256, and `unexpected tarball` is in no test (grep).
  - **Change:**
    - Right after :209, set `printf -v _AGSEC_CLEANUP_CMD 'rm -rf -- %q' "$work"` and arm `_agsec_on_exit`. This also covers the curl failure and the SHA `_die`.
    - Before :235, keep the test at :234 and record what this run will create, deepest first, stopping at `$HOME_DIR`:
      ```sh
      _created=""; _note_new() { local p="$1" q; while [ "$p" != "$HOME_DIR" ] && [ ! -e "$p" ] && [ ! -L "$p" ]; do printf -v q '%q' "$p"; _created="$_created $q"; p="$(dirname "$p")"; done; }
      _note_new "$STATE_DIR"; _note_new "$BIN_DIR"
      ```
      Use a string, not an array: an empty array under `set -u` aborts on bash 3.2.
    - Still before :235, extend `_AGSEC_CLEANUP_CMD`: if FRESH_INSTALL is 1, add `rm -rf -- %q` of INSTALL_DIR; if `_created` is non-empty, add `rmdir --$_created 2>/dev/null || true`. Write both in `if` form because of `set -e`.
    - At :286, rebuild the string to keep only the work-dir removal (and B13.3's unlock), instead of `trap - EXIT`.
    - Update the comment at :246-255.
  - **Tests:**
    - A mis-cut tarball, using a mirror with a wrong prefix, leaves no `.agent-secrets`.
    - A pre-existing empty `~/bin` survives a required-dependency failure.
    - With `TMPDIR` pointed at a test dir, that dir is empty after both a success and a failure.
  - **Callers:** tests/install.bats:159-168 and :172-183 still pass, and the second one's single-quote home still works through `%q`. Exit codes are unchanged, because the handler exits with the saved code.
  - **Not here:** cmd/uninstall.sh:84-86 also rmdirs an empty `~/bin` it may not have created. It needs a manifest record, so it is a separate fix.
- **B12.4 Real outcome and a receipt** (R003, R017, R187, R021, R275). install.sh:236, :285-286, :295, :321-323, :384. Extends B9.10.
  - **Verified:**
    - :322 discards the bootstrap result, and doctor's optional row is hidden by `--summary` (cmd/doctor.sh:59-60, :73, :346; setup.sh:589).
    - tar at :236 has no `||`, so it aborts with tar's own code and no message.
  - **Change:**
    - :236: `tar … || _die "Couldn't unpack <file> into <dir>."`
    - **:285 keeps its `||` context. Do not call it bare.** The record is on a directory. `shasum -a 256 <dir>` exits 1 (the verifier measured it), and under `pipefail` and `set -e`, `sha="$(shasum … | awk …)"` at lib/manifest.sh:61 would abort every install. The `||` is what suppresses errexit there. The return status still reflects the append.
    - :322: `launchctl bootstrap … || launchctl list "$SMOKE_LABEL" >/dev/null 2>&1 || { smoke_loaded=0; warn; }`. This is the same check doctor uses. It avoids a false alarm if bootstrap fails while the job is already loaded (estimated from general launchd behaviour). The warning names the command: `launchctl bootstrap gui/$(id -u) <plist>`.
    - Keep :321 silent (a failed bootout is the normal first-install case) and :323 unconditional (the plist is on disk either way, and uninstall needs the record, lib/manifest.sh:283-288). The finding's "records the job regardless" is not a defect.
    - Stay exit 0 on the launchd warning. Doctor classes that row as optional.
    - :384 becomes `Tool installed at $INSTALL_DIR. Changes recorded in $(agsec_install_manifest). Running setup…`, with ` (weekly smoke job not loaded)` when it applies. B9.10's post-setup `Installed agent-secrets v0.1.3.` stays last.
  - **Tests:**
    - `AGSEC_MOCK_LAUNCHCTL_BOOTSTRAP_FAIL=1`: status 0, `Couldn't load the weekly smoke job`, the manifest still has the launchd row, and the receipt says `not loaded`.
    - A tar shim that fails: status 1, `Couldn't unpack`, no residue.
  - **Callers:** the only `Installed.` hits are the old feedback docs under docs/feedback/, and no test pins it (`grep -rn 'Installed\.' tests` found none). AGENTS.md:61 gates on doctor, not on this text. Line :151's promise becomes true once :285 and :295 abort on failure.
- **B12.5 Signals and closed streams** (R335, R294, R416, R341, R336). install.sh:78-80, :175, :260, :286, :351-356, :385.
  - **Verified by the verifier's model scripts** under /bin/bash 3.2.57 and Homebrew bash 5.3.15 (install.sh itself was not run):
    - The exit codes are already right: an EXIT-trap-only model gave 130 on INT and 143 on TERM (HUP was not probed). What is missing is the message.
    - **SIGPIPE skips the EXIT trap** (rc 141). In the :260-286 window that strands the unpacked tool with no manifest, which is the residue that trap exists to prevent.
    - The finding's `| head -5` example dies before any mutation; about 16 or more lines are needed to reach one (estimated by counting `_say` and `_step` lines).
    - **`trap '' PIPE` is wrong in three ways:** printf gets EPIPE, so `set -e` still exits (rc 1); children inherit it, so `yes | head -1` changes from 141 to an error with status 1, which would reach curl, tar, sops and setup; and on bash 3.2 the failed text spills into the next builtin file write, which would corrupt install-manifest.json.
    - `trap 'exit 141' PIPE` fired the EXIT trap on 3.2 but not on 5.3.
    - A subshell around each write reached the end with rc 0 and the EXIT trap intact on both.
  - **Change:**
    - `_say(){ ( printf '%s\n' "$*" >&2 ) 2>/dev/null || true; }`, and the same for `_step`. Keep the default SIGPIPE disposition, so children are unaffected.
    - Wrap the direct printfs at :175 and :351-356 the same way.
    - After :265, redefine `agsec_log`, `agsec_note`, `agsec_warn`, `agsec_ok` and A.2's `agsec_receipt*` for this process the same way. `agsec_ok` stays on stdout. deps_ensure uses these in the pre-manifest window.
    - `_die` keeps exit 1.
    - One handler per signal: `trap '_agsec_on_signal 130' INT; trap '_agsec_on_signal 143' TERM; trap '_agsec_on_signal 129' HUP`. It reads globals `_AGSEC_PHASE`, `_AGSEC_STATE_DIR` and `_AGSEC_BIN`, prints by phase, and runs `exit "$1"`:
      - before :235: `Canceled. Nothing was changed.`;
      - unpack window, fresh install: `Stopped. Removed the partial install.` (the EXIT handler does the removal);
      - unpack window, re-run: `Stopped. Your existing install may be partly updated.` plus the rerun command (B13.2 narrows this once the swap is atomic);
      - after :286: `Stopped. Partly installed; every change is recorded in <STATE_DIR>/install-manifest.json.`, then one command: rerun or `<BIN_DIR>/agent-secrets uninstall --dry-run`.
    - **Do not use `exec` at :385 without D19(b),** and do not background setup: a background child starts with SIGINT ignored and cannot re-trap it (the verifier's case L), which would break lib/store.sh:100's plaintext shred and Ctrl-C in the wizard.
    - With a trap set, bash defers it until the foreground child returns (case I), so the `--max-time` in B12.1 is what bounds the wait during a download.
  - **Tests:**
    - B9.10's TERM-during-download test.
    - TERM in the unpack window (a tar shim that sleeps) gives 143, removes the fresh tool, and prints `Stopped. Removed`.
    - `{ bash "$baked" </dev/null 2>&1 >/dev/null; } | head -1` under `mm_no_ctty` still finishes wiring: `PIPESTATUS[0]` is 0, and the manifest and symlinks exist.
  - **Callers:** no test passes a status of 130, 141, 143 or 129 (the verifier's grep). No repo caller pipes the installer through `head` or `sed`. tests/one_command.bats:47-49 forbid `line ` before `: ` on a dry run, and this adds nothing there. The EXIT-cleanup pins at tests/install.bats:166-169 and :180-183 still hold.
  - **Residual limit:** after the handoff, setup's own writes can still get SIGPIPE (E13).

#### B13: writes and concurrency

- **B13.1 Foreign targets are backed up, including symlinks** (R350, R146, R002). install.sh:140, :290-297, :299-306. Rollback in B5.12, the same fix in setup in B6.15. Decision D21.
  - **Verified:**
    - :292 skips any symlink, so a user's own `~/bin/cursor-agent` symlink is replaced by `ln -sf` with no backup. Uninstall's `rm -f` then removes it. The link is lost; the file it points to survives.
    - :295 ignores a failed record, and :300 then clobbers the target.
    - A foreign symlink **to a directory** is worse: `ln -sf` keeps the user's link and drops a stray link inside their directory, so the wrapper is never wired (the verifier measured it with BSD `ln`).
    - cmd/setup.sh:349-356 has the same defect.
  - **Change:**
    - Replace `_bak_user_target` with a call to `manifest_backup_user_target` (B5.12). lib/manifest.sh is already sourced by :276, and setup.sh:20 sources it too.
    - :300 and :305 use `ln -sfn`.
    - On a failed backup or record, `_die "Couldn't record the backup of $t; nothing replaced. Your file is unchanged. …"` before any `ln`. The comment at :287-289 names this loss.
    - For the plan (B9.11), add a small inline `_target_is_foreign`, because `_render_plan` runs before lib/ exists: a target exists (or is a link) and `readlink` does not equal `$INSTALL_DIR/bin/<name>`. A false "foreign" affects only the plan text, because the real decision is the canonical check in B5.12. Print one `• replace your existing <path> (backed up to <state>; uninstall restores it)` per target, with no new prompt.
    - Keep :140 byte-identical (tests/install.bats:55).
  - **Tests:**
    - A foreign file symlink is restored as a link by uninstall.
    - A dangling symlink is restored.
    - A symlink to a directory is replaced by the wrapper, and nothing lands inside the directory.
    - The plan names a replaced target.
    - Our own link produces no backup and no plan row.
    - A failed record aborts before `ln`.
  - **Callers:** tests/install.bats:119 needs exit 0 for a closed-stdin agent install, and AGENTS.md:38-47 promises no human step. So this row backs up and proceeds, and never refuses; refusing is D21(B). No test places a foreign symlink in front of install.sh, and `preinstall` appears only in install.sh (grep).
- **B13.2 Staged unpack and swap** (R351, R326). install.sh:234-244. Decision D20.
  - **Verified:**
    - :236 untars into the live directory. An interrupt mixes versions, files removed in a newer version are never deleted, and on a re-run no trap is armed.
    - The layout guard runs after the overlay, so a mis-cut tarball damages a live install.
    - `vendor/bin` lives inside `$INSTALL_DIR` (lib/deps.sh:46-51), so a plain swap would delete the vendored jq, age and sops.
    - A same-version re-run is the documented repair path (cmd/doctor.sh:149, :163, :166, :314-316; cmd/setup.sh:564), so an early exit would strand a damaged install.
  - **Change** (the two verdicts disagree on this; §8 explains why both parts are kept):
    - Keep the whole flow and exit codes, and keep B12.3's trap, because deps_ensure (:274) can still abort after the swap.
    - `staging="$(mktemp -d "$HOME_DIR/.agent-secrets.staging.XXXXXX")"`, then unpack there with the same `--strip-components=1`, then run the layout guard against staging.
    - If `$INSTALL_DIR/vendor` exists, `cp -Rp` it into staging.
    - Set staging's mode to the live directory's, or for a fresh install to what `mkdir` would give. `mktemp -d` creates 0700, and `manifest_record_file` records the mode, so a change would break move-to-tail dedup.
    - Swap with two renames under B13.3's lock: `mv live "$INSTALL_DIR.old"`, `mv staging live`, then remove the old tree.
    - At startup, under the lock and **before** the FRESH_INSTALL test, if `live` is missing and `.old` exists, move `.old` back.
    - Keep `$INSTALL_DIR` a real directory, not a versioned symlink, because lib/manifest.sh's rollback never deletes through a link and would leave residue (lib/manifest.sh:180-207, :231).
    - Add staging to `_AGSEC_CLEANUP_CMD`. A live install is still never deleted on abort.
    - Narrow B12.5's re-run message to `Stopped. Your existing install was not changed.` before the swap.
  - **Residual limit:** a shell cannot exchange directories atomically, so a very short gap remains between the two renames. A wrapper such as apiKeyHelper invoked in that gap fails.
  - **Tests** (install-twice cases; there is none today):
    - Same version: `already installed`, exit 0, `vendor/` preserved.
    - A stale file in the old tree is gone.
    - A mis-cut tarball leaves the live tree byte-identical and no `.agent-secrets.staging.*`.
    - A leftover `.old` with no live dir is recovered.
  - **Callers:** tests/install.bats:167 and :182 and audit_regressions.bats:110 assert no `.agent-secrets` after a failed fresh install, and the trap covers staging. tests/install.bats:89 and :105 still see `SHA-256 verified`, because nothing skips the download.
- **B13.3 Concurrent installs** (R368, R319, R351). install.sh, between :229 and :234; :260; :286; :385. Doc side in B8.15.
  - **Verified:**
    - install.sh takes no lock (the verifier's grep of install.sh, lib, cmd, bin and scripts found no `flock` or `mkdir` lock).
    - AGENTS.md:40-45 tells every agent lacking the tool to install it, so parallel sessions are plausible.
    - The worst effects, which the finding omits: an aborting fresh install runs `rm -rf $INSTALL_DIR` under a sibling (:234, :260); tar overwrites libs a sibling is sourcing (:236-237); `rm -f` of age.key or recovery.key at setup.sh:80 and :101 can hit another run's in-flight mint.
    - `.new` predictability is not exploitable by another user in owner-controlled directories. The defect is same-user concurrency. B5.4 already replaces `${file}.new` at lib/manifest.sh:110 and :303, and `agsec_commit` keeps the mode (tests/audit_regressions.bats:240-241 pins that), so no new manifest row is needed.
  - **Change:**
    - Take the lock between :229 and :234: after `_note_new`, run `mkdir -p "$STATE_DIR"`, then loop on `mkdir "$STATE_DIR/install.lock"`, writing `$$` to a pid file inside. Inline it, because lib/common.sh's `agsec_lock` is not unpacked yet.
    - That placement leaves `--help`, `--dry-run`, consent, preflight and the SHA gate free of mutation, so today's refusal paths keep zero residue.
    - Bounded wait of about 60 s (R019). On timeout, `_die` (exit 1) names the holder's pid and tells the user to re-run when it finishes.
    - Reclaim a stale lock only when `kill -0` on the recorded pid fails: `mv` the lock dir to a unique name, then remove it.
    - Release through `_AGSEC_CLEANUP_CMD`, ordered before the `rmdir` of `$STATE_DIR`. A separate `trap … EXIT` would be clobbered at :260 and disarmed at :286.
    - Hold it through :385, because setup runs as a child and the key races are in setup. A second install during a long wizard gets the conflict error, which is intended. This depends on D19(a).
    - **Do not** add a second lock around `_manifest_append`. `setup` calls it as a child while the parent holds the install lock, so it would wait until the timeout.
  - **Tests:** a held lock with a live pid gives exit 1 and the conflict text; a dead-pid lock is reclaimed; after any exit the lock dir is gone and an empty state dir this run created is removed.
  - **Callers:** the gates and their pinned strings all run before the lock. Each test has its own `AGENT_SECRETS_HOME` (tests/test_helper.bash:7), so locks cannot cross. No caller branches on a lock state. The only new outcome is exit 1, already the refusal code.
  - **Remaining scope:** a direct `agent-secrets setup` or `uninstall` stays unlocked unless a re-entrant marker is added later.

#### B10: PTY suite additions

- **B10.1 Consent on a pty** (R015, R147, R338, R228). Adds to B10's consent rows: Ctrl-D at the prompt exits 130 with the receipt. Three bad answers then a fourth exit 130. `y` installs. The fixture installs nothing when declined: an empty curl log and no `~/.agent-secrets`.
- **B10.2 The offer after the result** (B11.4), using the baked mirror fixture:
  - Plain TTY, Enter at consent, drive the wizard (`n`, then `4`), Enter at the offer: no CLAUDE.md, exit 0, and no `Canceled.` (R340).
  - The same with `y` at the offer: the block is written after `You're set up`.
  - `--discovery` on a TTY: no offer, rules written, and the wizard still runs (setup not reduced to its standalone screen).
  - `--no-discovery` on a TTY: no offer (B10's existing row).
  - `--import-env X` on a TTY: the plan says `setup --headless`, no `Make every coding agent`; with `--no-discovery` too, nothing written.
- **B10.3 Mode parity with setup** (R113, R116, R014, R006). A table test on a pty and off one:
  - Inputs: `--headless`, `--import-env X`, `CLAUDECODE=1`, `CI=1`, `2>log`, no terminal, and plain `tty`.
  - For each, the plan's setup line and setup's own title must agree (`setup --headless` with `(headless)`, or the wizard line with its first prompt).
  - Also: agent + TTY, CI + TTY and `2>log` never block on a read.
  - `curl | bash` on a pty still prompts (spawn `sh -c "cat install.sh | bash -s"`, so stdin is a pipe with a controlling terminal behind it), so the rebind's documented purpose has a pin.
- **B10.4 Every printed command parses** (R100, R393). Owned here because it needs B5.10, B6.11 and B7.14's seams.
  - **install.sh side** (`AGSEC_PARSE_ONLY=1`, exit 0, empty curl log): every `Examples:` line in `_agsec_usage`; the `_self_cmd` argument forms; the dry-run next-step with flags; `--help` from `_usage_die`; C7.1's `AGENT_SECRETS_BASE_URL=<URL> bash install.sh` with a synthetic URL.
  - **Dispatcher side** (`AGSEC_PARSE_ONLY=1 bash bin/agent-secrets …`, exit 0): every command install.sh prints: `setup --discovery`, `setup`, `uninstall --dry-run`, `uninstall`, `doctor`.
  - **Negative control:** `AGSEC_PARSE_ONLY=1 bash install.sh --bogus` exits 2, which proves the seam is after validation.
  - C7.4's `--yes --headless` joins this list if D10(b) is approved, and C8's `--json` if approved.
- **B10.5 Non-TTY tests must not depend on the developer's terminal** (R390, R397).
  - **Verified:** `_attach_tty` rebinds any non-TTY stdin when /dev/tty opens and no agent variable is set. From a real terminal, tests/install.bats:67, :77, :88, :103, :143, :166 and :181, tests/one_command.bats:45 and tests/audit_regressions.bats:106 block on the terminal, and tests/install.bats:153 renders the wrong plan and fails. CI has no controlling terminal, which hides this.
  - **Change:** wrap those calls in `mm_no_ctty` (A2). Do not add a test seam to install.sh. Keep tests/install.bats:119 as is, because it sets `CLAUDECODE=1`. If D17(A) lands, file runs are non-interactive and the wrap becomes redundant but harmless.
  - **Test:** none beyond the suite itself; B10's gate is that a local `bats tests/install.bats` from a terminal does not hang.
  - **Callers:** the assertions in those tests do not change. Skip reporting follows the §1 gate: an expect-based test that skips must report the skip count, and it must be 0.

#### Rows for other Wave B units

**B4** (`lib/deps.sh`, `tests/deps.bats`)
- **B4.13 Retry notice on dependency fetches** (R316). lib/deps.sh:95.
  - **Change:** `_deps_curl` keeps `--proto '=https' --tlsv1.2`, per its comment. Merging it with install.sh's `_fetch` would drop that hardening or force https onto mirrors. Use `--no-progress-meter` with the same probe and fallback as B12.1, and rewrite `Will retry` lines to `Retrying automatically…` through a small filter. Exit codes pass through; `_deps_download_verify` collapses any failure to return 1 (:102).
  - **Tests** (tests/deps.bats): A2's `AGSEC_MOCK_CURL_RETRY_NOTE=1` gives the notice, and B4.9's flag test also asserts `--proto` and `--retry-max-time`.
  - **Callers:** install.sh:272-274 and tests/deps.bats:10, :38, :43, :68; the `_deps_curl` name stays because tests/deps.bats:10 sources the lib alone.

**B5** (`lib/manifest.sh`, `tests/uninstall.bats`)
- **B5.12 One helper for user targets, and rollback restores links** (R350, R003). lib/manifest.sh `_manifest_rb_edit` (:235, :274).
  - **Change:**
    - New `manifest_backup_user_target T BASENAME`, used by install.sh (B13.1) and setup.sh (B6.15). A target is ours only if it is a symlink resolving to this install's `bin/<name>`, compared by canonical path (physical parent plus basename), because a false "foreign" would record a backup of our own link. A dangling symlink or a regular file that is not ours counts as foreign.
    - Copy with `cp -PR`, because `cp -p` follows the link (the verifier measured it).
    - Keep the existing base names `<name>.preinstall.bak` (install) and `wrapper-<name>.bak` (setup). tests/audit_regressions.bats:79 and :152 use the second.
    - Backup refresh follows B9.12: when the backup exists and differs, rename the old one to `<base>.<UTC-timestamp>`, write the new one at the same path, and keep one edit record. Do not add a second record: LIFO would restore the older file last. The verdict's versioned-name option would need a change to how records are stored, and this does not.
    - Return non-zero when the copy or the record fails.
    - `_manifest_rb_edit`: add a branch before `[ -f "$backup" ]`: `if [ -L "$backup" ]; then rm -f "$p" && ln -s "$(readlink "$backup")" "$p"`. Today a dangling link backup hits "edit backup missing", and a live one comes back as a dereferenced copy. This must come before B5.1's missing-backup return.
  - **Tests** (tests/uninstall.bats): a foreign symlink backup restores as a link; a dangling one too; a differing second user file keeps the old backup under a timestamped name, and uninstall restores the newer file; the S4 LIFO test at tests/audit_regressions.bats:142-159 stays green.
  - **Callers:** install.sh:299-306, cmd/setup.sh:349-356.

**B6** (`cmd/setup.sh`, `lib/wire.sh`, `tests/flows.bats`)
- **B6.13 Stderr decides interaction too** (R113, R014). cmd/setup.sh:547-551, next to B6.2.
  - **Verified:** with stderr redirected on a terminal, every prompt is invisible once A.8 moves the ui_* helpers to stderr.
  - **Change:** after B6.2's branch, `elif [ ! -t 2 ]; then HEADLESS=1; HEADLESS_WHY="stderr is not a terminal"`. Keep the guard for UNATTENDED and `--headless` first, and keep the exact strings `coding-agent session` and `no terminal attached`. Their branches stay ahead of this one.
  - **Tests:** B6.12's matrix gains `script -q /dev/null bash -c '… setup 2>log'`: headless, the reason in the log, no prompt.
  - **Callers:** the expect drives run on a full pty, so they are unaffected. tests/one_command.bats:66-79 still reports `no terminal attached` with no terminal.
- **B6.14 --import-env never echoes a value** (R355, R069, R436). cmd/setup.sh:515-521, :533, :534.
  - **Verified:** :534 echoes `$2`, the very mistake tests/headless.bats:86 calls the leak. The `''` arm at :518 is dead, so `,` and a space pass.
  - **Change:** :534 uses :537's generic wording with no value. `_import_env_valid` requires at least one name and rejects glob characters before the unquoted `for`. :533's hint becomes `--import-env needs <NAME>[,<NAME>…]`.
  - **Tests:** tests/headless.bats:87-90 stays unchanged and still sees status 2 and `--import-env`. New in tests/flows.bats: `setup --import-env 'sk-ant-SEKRET'` prints no `SEKRET`; `setup --import-env ,` exits 2.
- **B6.15 Wrappers through the shared helper** (R350, R003). cmd/setup.sh:349-356.
  - **Change:** `_wire_tools` calls `manifest_backup_user_target` (B5.12). A failure dies with `agsec_die` before any `ln`. `ln -sfn` replaces `ln -sf`. Keep the pristine-backup comment's intent, and update it for B5.12's refresh rule.
  - **Test** (tests/flows.bats): a foreign symlink at `~/bin/claude-agent` is backed up and restored.
- **B6.16 Copy that the install flow makes false** (R157, R123). cmd/setup.sh:385, :423; lib/wire.sh:69.
  - **Change:**
    - :423 becomes `(Claude Code reads the agent rules in ~/.claude/CLAUDE.md, if you added them.)`. Today it says "already covered", which is false before the offer (B11.4) and after a decline.
    - :385 becomes `Writing the agent-secrets rules (advisory, recorded in the manifest) into:`.
    - wire.sh:69 becomes `wired apiKeyHelper into settings.json (recorded in the manifest)`.
  - **Tests:** the pins survive: tests/headless.bats:153 needs `Writing the agent-secrets rules`; tests/headless.bats:127 and tests/wizard_interactive.bats:175 need `wired apiKeyHelper`. `already covered` is pinned nowhere (grep).

**B7** (`cmd/doctor.sh`, `tests/doctor.bats`)
- **B7.17 Doctor's stale advice** (R004, R235). cmd/doctor.sh:316.
  - **Verified:** "re-run the installer to add" is the same advice cmd/setup.sh:369 replaced with `setup --discovery`.
  - **Change:** :316 ends `add them with: agent-secrets setup --discovery`. Keep the `agent rules` label pinned at tests/discovery.bats:67, :71 and :78.
  - **Not changed:** :314-315 (stale, tampered). No one has checked what `setup --discovery` repairs there.
  - **Test:** the not-installed row names `setup --discovery`.

**B8** (adds `SECURITY.md` and `docs/FAQ.md` to its files for Wave B; C4 and C6 take them in Wave C)
- **B8.14 Exit 130 in the docs** (R337, R338). AGENTS.md:160-162. Add `130` canceled. B3.2, B4.3 and B9.5 all add it, and round 1 updated only the per-verb help rows. Top-level help's exit rows get the same line.
- **B8.15 The documented download path** (R351, R368). README.md:58, :78; AGENTS.md:44-45.
  - **Verified:** both write a fixed `/tmp/agent-secrets-install.sh`. /private/tmp is sticky, so another user cannot replace a file the victim created. The real risks are a pre-planted file or symlink that `curl -o` writes through, and parallel runs on one path (standard curl and sticky-bit semantics, not exercised).
  - **Change:** identically in both places, keeping `&&` and the pinned tag:
    `f="$(mktemp "${TMPDIR:-/tmp}/agent-secrets-install.XXXXXX")" && curl -fsSL https://raw.githubusercontent.com/renchris/agent-secrets/v0.1.3/install.sh -o "$f" && bash "$f"`
    - No `.sh` suffix is needed, because the guard tests only the file (B9.15).
    - Amend README.md:78 to say the script stays at `"$f"`.
    - Leave the `/tmp/x.sh` transcript at README.md:73 as it is, because it is a recorded measurement.
    - Do not advertise anything an unreleased tag lacks: README and AGENTS pin v0.1.3, and that script keeps its old behaviour.
  - **Test:** a help.bats check that README.md:58's command and AGENTS.md's use the same form. No test runs them.
  - **Callers:** the literal path appears only at README.md:58 and AGENTS.md:44-45 (the verdict's grep), so nothing else breaks.
- **B8.16 SECURITY.md:65.** "opt-in, tty-only (never in a `curl | bash` pipe)" is false for headless, which writes by default. Reword to state both paths. AGENTS.md:58's "advisory + reversible" follows D22.
- **B8.17 Help rows.** lib/help.sh:25 adds `empty = $HOME` (lib/common.sh:61), and AGENTS.md:150 mirrors it. help.sh:38 replaces `advisory, reversible` with `advisory, recorded in the manifest` (R157). No test pins `base dir for all state` (grep); tests/help.bats:98 checks only the name.
- **B8.18 docs/FAQ.md.** Line 71 says `AGENT_SECRETS_INSTALL_URL` replaces the trust root and is not digest-checked (D23). Add: do not embed credentials in a mirror URL; use `~/.curlrc` or `$CURL_HOME/.curlrc` with `netrc` in it, because install.sh passes no `--netrc` (R355, D25).

---

## 4. Wave C: contract-changing fixes

Each fix lists its callers and its migration. Each is gated on the operator decision named in its heading, and the code units land only for approved decisions. **C4 lands first**: it adds `agsec_name_reserved` and the new error format that C2 consumes. **C6 lands last**: it owns help and docs.

### C1: uninstall consent and preview (F4: R002, R146, R148, R150, R124, R015, R120, R152). Decision D1
Owner: `cmd/uninstall.sh`, `tests/uninstall.bats`, `tests/audit_regressions.bats`.

**Change:**
1. Parse `--dry-run`, `--yes/-y` and `--purge-data`.
2. Run `agsec_require jq` and the manifest JSON validation **before** any consent check, so MAN-CORRUPT keeps "not a valid JSON array" (audit_regressions.bats:47-49).
3. On a real run, first print the plan to stderr with `agsec_plan`. Reuse the `manifest_rollback --dry-run` lines plus the state dir and the parent-rmdir lines. End with "Some effects cannot be undone." (the Keychain item deletion).
4. **Rollback (destructive tier):**
   - Interactive: `Remove agent-secrets? (y/N)` unless `--yes`. A decline is `agsec_canceled` (130).
   - Non-interactive without `--yes`: `agsec_need_confirmation "uninstall" --yes "agent-secrets uninstall --yes"` (exit 2, nothing touched).
5. **Purge (severe tier):**
   - Interactive: preview `rm -rf <config_dir> (store + age keys)`, then "This cannot be undone.", then `To confirm, type the directory name "secrets":`. A mismatch names the expected answer and keeps the store.
   - Non-interactive: purge only with `--purge-data --yes`. Refuse `--purge-data` when `agsec_in_agent_session`, matching share.sh:45 and AGENTS.md:26 ("human-gated").
   - Without `--purge-data`, keep the store (current behaviour).

**Callers (verdict census):**
- tests/uninstall.bats:52-55 (`</dev/null`, expects 0 and "uninstall complete").
- tests/uninstall.bats:63 (`printf 'N\n' |`, expects the roster purge).
- tests/audit_regressions.bats:59-61 (UNINST-HANG, `</dev/null`, expects 0).
- tests/audit_regressions.bats:47-49 (MAN-CORRUPT).
- Docs: lib/help.sh:103-112, README.md:115, 324, 424, AGENTS.md:26, 107, 169, llms.txt:23.
- No caller outside the repo: ~/.claude/settings.json and claude-infrastructure hooks, scripts, skills and commands have none.

**Migration:** update the callers in the same commit.
- :52 and audit:59 add `--yes`, and each gets a sibling test asserting that the run without `--yes` exits 2 and leaves everything in place.
- :63 becomes `--yes </dev/null`.
- MAN-CORRUPT stays as it is, protected by validating first.
- No deprecation flag; there are no known external callers.

**Tests:**
- `@test "non-interactive uninstall without --yes exits 2 and touches nothing"`.
- `@test "declining the rollback prompt exits 130"` (PTY or a confirm seam).
- `@test "--purge-data without --yes exits 2"`.
- `@test "--purge-data is refused inside an agent session"`.
- `@test "the plan is printed before any removal"`.

**D1 (operator decision):** should `--purge-data` exist?
- Today there is deliberately **no** non-interactive way to delete the store and age keys (help.sh:105, "no --force bypass").
- Option (a), the plan's default: add it, refused in agent sessions. This satisfies R124, "every prompt has a flag".
- Option (b): keep the purge interactive-only and add just the typed confirmation. Smaller attack surface.

### C2: consent flags on share, receive and backup (F7: R010, R151, R439, R009), plus the F9 receive part and F20 headlines. Decisions D2, D3, D4, D6
Owner: `cmd/share.sh`, `cmd/receive.sh`, `cmd/backup.sh`, `tests/share.bats`, `tests/receive.bats`, `tests/backup.bats`.

**Change (F7):**
- **share:** add `-y|--yes`, which sets `assume_yes=1`. Gate :116 and :132 on it instead of `AGENT_SECRETS_UNATTENDED`. `--yes` must **never** bypass :45 (agent session) or :52 (the tty gate).
- **share :116/:132 and backup.sh:13:** for one release, honour `AGENT_SECRETS_UNATTENDED` as consent but print `agsec_warn "AGENT_SECRETS_UNATTENDED as consent is deprecated for share/backup; pass --yes"`. Remove it in the release after. Do **not** rename the variable: it is still setup's test mode (cmd/setup.sh:22, AGENTS.md:152, many tests).
- **receive:** `-y|--yes` is canonical. `--yes-i-reviewed` becomes a hidden alias that sets the same variable and prints a one-line deprecation warning. The texts at :48 and :140 say `--yes`.

**Change (F9 receive part; only if D4 is approved):**
- Interactive receive always shows the effective name and asks for confirmation, not only on a collision. The `name:` line sits outside the ciphertext, so the sender or the relay can alter it.
- Under `--yes`, a reserved name is refused with exit 2, using `agsec_name_reserved` from C4.

**Change (F20; only if D6 is approved):**
- share.sh:125 headline becomes "could not encrypt $name for sharing (age failed)".
- backup.sh:63 moves its hint into agsec_die's recovery argument.

**Callers:**
- tests/share.bats:218-224 grants consent through the env var alone. Add `--yes`, and keep a deprecated-path test that asserts the warning.
- tests/share.bats:226-246 (tty gate) stays. Add `--yes` to one of them to prove the gate still holds.
- tests/receive.bats:59, 68, 77 keep the alias for coverage. Add one `--yes` test.
- If D4 is approved, every interactive-seam receive test needs `y\ny` in its confirm file (a second confirm read).
- Docs: lib/help.sh:123, 131, 133, 135, 159 (via C6), AGENTS.md:34, docs/research/colleague-sharing-design.md:742 (add a rename note), docs/plans/colleague-sharing-v0.2-plan.md.
- Outside the repo: only research docs in claude-infrastructure. No script calls it.

**Migration:** keep the old behaviour behind a deprecation (the alias plus the env-var warning) for one release, with a changelog line.

**Decisions:**
- **D2:** `share --verify --yes`. Should `--yes` skip the readback that `--verify` makes mandatory, or should the combination be refused with exit 2? Recommend refusing.
- **D3:** accept renaming the deliberately long `--yes-i-reviewed` (colleague-sharing-design.md:742) and deprecating env-var consent?
- **D4 and D6:** see C4.

### C3: setup discovery default and the health-check exit (F8: R010, R015, R146; F28: R003, R339, R187). Decisions D5 and F28 (no decision required)
Owner: `cmd/setup.sh`, `install.sh`, `tests/headless.bats`, `tests/install.bats`, `tests/one_command.bats` (only if a fixture turns out to need it).

**F8 change (only if D5 is approved):**
- `DISCOVERY` starts at 0 in every mode: setup.sh:27 and :552 become `[ -n "$DISCOVERY" ] || DISCOVERY=0`.
- `--discovery` on its own keeps the standalone screen (:557). Combined with `--headless` or `--import-env`, it sets DISCOVERY=1 for the full flow.
- `--no-discovery` is still accepted as a no-op, because install.sh:383 and user scripts pass it.
- When headless runs with DISCOVERY=0, print the plan from `agsec_discovery_plan` under "Not written. To make agents on this Mac aware of agent-secrets, run: agent-secrets setup --discovery" and exit 0.
- Optional: an env pin `AGENT_SECRETS_DISCOVERY=1`. Interaction mode itself must never turn discovery on.
- install.sh:
  - Add a `--discovery` passthrough to the flag loop, the usage text (:87, :101) and `setup_args` (:380-385).
  - The plan line at :146-150 becomes "machine-wide agent rules: NOT written (pass --discovery to write them)".
  - Remove "headless writes them by default" from :87, :101 and :343-345.

**F8 callers:** install.sh:380-385, tests/headless.bats:149-158, tests/install.bats:131, README.md:150, 390, 403, 406, AGENTS.md:58, 135, llms.txt:14, docs/plans/AGENT_ENTRYPOINT_HEADLESS.md:110, 137, 163, help.sh:33-38, 44, 49.

**F8 migration:** update callers in the same commit.
- headless.bats:149-158 asserts that nothing is written and the hint is printed, and adds a `setup --headless --discovery` case that writes and announces.
- install.bats:131 asserts that CLAUDE.md is absent by default, or passes `--discovery`.

**D5 (operator decision):** this reverses a deliberate, documented feature. Agent-run headless installs would stop telling other agents on the Mac about agent-secrets unless asked (AGENT_ENTRYPOINT_HEADLESS.md:110).

**F28 change:**
- :571: drop `exec` and capture doctor's code.
- :589: `hc=0; bash "$AGENT_SECRETS_CMD/doctor.sh" --summary || hc=$?`.
- hc=1: still run `_done_screen` (headless.bats:47-49 needs its follow-ups), with `ui_warn "health check found problems — see the ✗ rows above; next: agent-secrets doctor"` in front. Change the title to "Set up, with problems". `return 1` without `_state done`.
- hc=2: internal error, return 1.
- install.sh:385: append `|| { _say "Setup finished with problems — run: agent-secrets doctor"; exit 1; }`.

**F28 callers:**
- install.sh:385. The curl|bash one-liner's exit code becomes setup's.
- Healthy-path asserts stay: headless.bats:13-20, 42-43, 61-64, 97-100; flows.bats:41-43; wizard_interactive.bats:140, 172; install.bats:124; one_command.bats:78, 117, 130.

**F28 migration:** same commit, no flag.
- R003 is a MUST, and it matches commit 36c95d1 ("the install one-liner fails loudly instead of reporting a false success").
- **First run those five suites** to confirm no fixture has a latent ✗ row. The verdict could not confirm this statically.
- New test: `@test "setup exits 1 and does not say 'You're set up' when the health check finds a ✗"`, using a doctor shim that exits 1.

**Round 2 note on C3.** C3's install.sh rows, and its `tests/install.bats` ownership, move to C7, so install.sh has one owner in Wave C. C3 now owns `cmd/setup.sh`, `tests/headless.bats` and `tests/one_command.bats`.

Two of the moved rows needed fixing:
- **The F8 `--discovery` passthrough, as written, breaks setup.**
  - install.sh passes `--headless` only when the user passed it (:381).
  - `setup --discovery` without `--headless` runs only the standalone discovery screen and returns (setup.sh:557).
  - So on a TTY, or on a no-TTY run where setup picks headless by itself (setup.sh:547-549), the forwarded flag would skip the key mint and the whole wizard.
  - C7.3 forwards it correctly.
- **The F28 line at install.sh:385 is mostly covered by B9.10**, which already reports a failed setup with recovery commands. C7.3 only adjusts the wording once C3 makes setup exit 1 on a failed health check. Whether install passes setup's code through or normalises it to 1 is D14.

### C4: core (F9 reserved env names: R363, R359, R011; F20 error format: R276, R277, R280, R185, R182, R205, R217). Decisions D4 and D6
Owner: `lib/common.sh`, `lib/store.sh`, `lib/egress.sh`, `cmd/run.sh`, `cmd/add.sh`, `cmd/doctor.sh`, `bin/agent-secrets`, `tests/reserved_env.bats` (new), `tests/egress.bats`, `tests/onboarding.bats`, `tests/custody.bats`, `tests/wizard_interactive.bats`, `SECURITY.md`.

**F9 change (only if D4 is approved):**
- `agsec_name_reserved NAME` in common.sh matches: PATH, LD_*, DYLD_*, NODE_OPTIONS, BASH_ENV, ENV, PYTHONPATH, PYTHONSTARTUP, PERL5OPT, RUBYOPT, `*_PROXY` and `*_proxy` (HTTP, HTTPS, ALL, NO), SSL_CERT_FILE, NODE_EXTRA_CA_CERTS, AGENT_SECRETS_*, AGSEC_*. The canary `AWS_BACKUP_ACCESS_KEY_ID` must **not** match.
- `store_add` (store.sh:69) refuses a reserved name with exit 2. This covers add, receive, setup `--import-env` and the unattended seed. Mirror the message in add.sh:17.
- **At injection**, `store_exec` and `store_exec_managed` read `store_names` (names only, no values). For each reserved name already stored that is not in `--allow-env`:
  - Warn once on stderr: `env_var_skipped NAME`.
  - Export a parent snapshot `__AGSEC_PARENT_NAME`. This includes the egress values set at egress.sh:96-98.
  - Prefix the `sh -c` string with `NAME="$__AGSEC_PARENT_NAME"; unset __AGSEC_PARENT_NAME;`, or `unset NAME;` if the parent had no value. No value ever reaches argv.
- cmd/run.sh: `--allow-env NAME` (repeatable, before `--`), passed through by egress_run.
- The precedence documentation goes in help.sh:78 (via C6).

**F9 callers:**
- store_add: setup.sh:246, 264, 306; receive.sh:171; store.sh:225 (the canary).
- store_exec: egress.sh:86, 93, 95, 104; doctor.sh:378, which must still return 0.
- bin/claude-agent, bin/cursor-agent, cmd/smoke.sh:45.
- No in-repo caller uses a reserved name (verdict grep). The real exposure is **end-user stores** that already hold such names, which cannot be checked statically.

**F9 migration:**
- New writes are rejected.
- Existing entries are **skipped with a warning, never deleted or refused**, so the wrappers and doctor keep working.
- `--allow-env NAME` restores the old behaviour per name.
- Add a changelog line.

**F20 change (only if D6 is approved):**
- `agsec_die`: rich `✗ <headline>`, plain `Error: <headline>`, plus the Wave A recovery block.
- `agsec_warn`: rich `! <msg>`, plain `Warning: <msg>`.
- `agsec_attn`: `!` in rich mode, with ASCII fallbacks in plain mode.
- New `agsec_plural N WORD`.
- store.sh:102 becomes "could not decrypt the store", with recovery "Check custody: agent-secrets doctor".
- store.sh:108 becomes "could not encrypt the store with sops".
- bin/agent-secrets:110 moves "(try: agent-secrets help)" into the recovery argument.
- Plurals:
  - egress.sh:102 and doctor.sh:384: "1 rule" or "N rules".
  - doctor.sh:413: "1 optional check hidden" or "N optional checks hidden".

**F20 callers to update in the same commit:**
- tests/onboarding.bats:20 matches the literal `check(s)`. Match "optional check" plus "hidden" instead.
- tests/onboarding.bats:25-26 runs `grep -c '⚠'` on doctor. Count `"status":"attn"` rows from `doctor --json` instead.
- tests/custody.bats:29 asserts ⚠. Use the JSON status or `!`.
- tests/wizard_interactive.bats:28 asserts that "ERROR" is absent. Assert that neither `✗ ` nor `Error:` nor any store_add headline appears; otherwise the test passes silently.
- tests/dispatcher.bats:29, 54, 72 match "unknown command", which is kept.
- lib/help.sh:90, 94 (C6) and SECURITY.md:119 (`WARN` becomes `Warning:`).
- Exit codes, `doctor --json`, and claude-infrastructure/hooks/lib/jev.sh:111 are unaffected.

**F20 migration:** update callers in the same commit. The release note says doctor's text glyph ⚠ is now `!`, and scripts should gate on `doctor --json` and the exit code, which are unchanged.

**Tests (tests/reserved_env.bats):**
- `@test "add PATH exits 2"`.
- `@test "receive --yes refuses an envelope named HTTPS_PROXY"`.
- `@test "a stored HTTPS_PROXY is skipped with env_var_skipped and the egress proxy wins"`: seed through sops directly, run `run -- printenv HTTPS_PROXY`, expect the loopback URL.
- `@test "--allow-env HTTPS_PROXY injects it"`.
- `@test "store_exec -- true still returns 0 with a reserved name stored"`.

**D4 (operator decision):** the denylist's contents; skip-with-warning versus refuse at injection; whether `--allow-env` ships now; and the extra receive confirmation prompt (C2).

**D6 (operator decision):** adopt R182's `!` for warnings in place of ⚠, and `✗`/`Error:` in place of `ERROR`. help.sh:90 currently tells agents that the ✓/⚠/✗ text glyphs are something they can gate on.

### C5: list JSON shape, phase 2 (F11: R248, R251). Decision D7
Owner: `cmd/list.sh`, `tests/store.bats`.

**Change:**
- Output `{"secrets":[{"name","rotate_by"}],"pagination":{"next":null}}`. An empty store also returns this object, not `[]`.
- Keep the key `rotate_by`, not `rotateBy`. R246 says JSON mirrors the data model, and manifest.toml stores `rotate_by`.
- Optional: a hidden `--legacy-array` for one major version.

**Callers:**
- tests/store.bats:49 (`.[].name` becomes `.secrets[].name`).
- AGENTS.md:121, the agent recipe (`.[] | select(...)` becomes `.secrets[] | select(...)`).
- help.sh:71 (the example) and llms.txt:16, both via C6.
- claude-infrastructure/hooks/lib/jev.sh:111 uses text `list` and is unaffected.

**Migration:** same commit, behind a next-major release, with a changelog line and an optional legacy flag.

**D7:** cut this in 0.2.0 together with the rest of Wave C, or hold it? Ship `--legacy-array` or not?

### C6: help and docs for the approved Wave C items. Decision D8
Owner: `lib/help.sh`, `tests/help.bats`, `README.md`, `AGENTS.md`, `llms.txt`, `docs/plans/AGENT_ENTRYPOINT_HEADLESS.md`, `docs/research/colleague-sharing-design.md`, `docs/plans/colleague-sharing-v0.2-plan.md`, and the release-notes file.
- Apply only the rows for approved items:
  - C1: the uninstall synopsis, `--yes`/`--purge-data` flags, and exits 2 and 130. Replace "no --force bypass" with "purge needs --purge-data --yes and is refused in agent sessions".
  - C2: share `-y, --yes`; receive `-y, --yes`; env rows marked deprecated.
  - C3: setup's discovery rows and exit rows (:51-52).
  - C4: run's `--allow-env` and precedence; doctor's glyph text (:90, :94).
  - C5: list's example.
- **D8:** no CHANGELOG exists (measured with `ls`). Either:
  - create `CHANGELOG.md` and add `CHANGELOG.md export-ignore` to `.gitattributes`, so the release tarball's contents stay as .gitattributes documents them; or
  - carry the notes in the GitHub release body. That path goes through the user-gated `scripts/release.sh`.
  - Also decide the version for the Wave C release (0.2.0 recommended). Bumping it is user-gated.

### Round 2 additions to Wave C

**C1**
- **Text-mode refusal.** The non-interactive refusal goes through `agsec_need_confirmation`. Its recovery names `agent-secrets uninstall --yes`, and the message states the consequence: "removes every recorded file, the PATH block, the launchd job, the settings.json edit and the Keychain items".
- **R263 is N/A.** It covers `userActionRequired`, `data.effects` and `next[].when`, and uninstall has no `--json`.
- **Mode matrix (R403)** for `Remove agent-secrets? (y/N)` and the typed purge confirmation:
  - `tty`: each prompt appears.
  - Every other mode without `--yes`: exit 2, nothing removed.
  - `agent` with `--purge-data --yes`: exit 2.
- **audit_regressions.bats handoff.** C1 owns tests/audit_regressions.bats. If D10(c) is approved, C7 takes that file for one line (:106) after C1 commits.

**C2**
- **Deprecations.** `--yes-i-reviewed` and env-var consent go through `agsec_deprecated` (A.14). Each names its replacement and prints once per run (R308, R385).
- **Mode matrix (R403) for `--yes`:**
  - `--yes` never bypasses share's tty gate or its agent refusal (E5).
  - On receive and backup, `--yes` skips the prompt in every mode.

**C4**
- **D6 also covers install.sh and scripts/release.sh.** It now decides install.sh's `ERROR:` prefix (`_die`, `_usage_die`) and scripts/release.sh:24. C4 changes lib/common.sh:96; C7.1 changes install.sh and release.sh. The three prefixes then move together, or not at all.
- **doctor `--fields`.** If D7 approves `--fields` for doctor, C4 adds it, because C4 owns cmd/doctor.sh in Wave C. The fields are `category`, `status`, `check` and `detail` per row.

**C5**
- **D7 gains `--fields <FIELDS>`** (R252). `list --json --fields name` keeps only the named keys. An unknown field exits 2 and lists the valid ones (`name`, `rotate_by`). Additive.

**C6** (now also owns `docs/FAQ.md`; lands after C7)
- **Glossary (R423), only if D16 is approved.**
  - Add a Nouns table to AGENTS.md. Each noun lists its meaning, the selector forms it accepts, and its banned synonyms.
  - Add a help.bats lint that fails when a banned synonym appears in lib/help.sh.
  - Copy in cmd/ follows in a later release.
- **Install docs for whichever D9-D11 options are approved:** AGENTS.md:38-49, README.md:58 and :129, docs/FAQ.md:67, docs/plans/AGENT_ENTRYPOINT_HEADLESS.md:38 and :136.
- **Pass 2:**
  - Lands after C8.
  - Adds the install rows for whichever of D10(b), D17, D18, D19 and D20 are approved, and the stream note from C7.5.
  - Adds `--json` for install only once a tag carries it (C8.9).
  - D22(B), if approved, rewrites README.md:112 and :377, SECURITY.md:66, AGENTS.md:58, assets/hero.svg:41 and the reversible.mmd diagram. That diff touches fence blocks, so run `[ -d node_modules ] || npm ci` and `npm run diagrams:check` (§1).
  - Writes the E8-E14 records.
  - Any new help example passes the parser test in the same commit (R100; B8.9 and B10.4 iterate the spec and the printed commands).

### C7 (new): install.sh contract and presentation. Decisions D5 (sub-question), D6, D9-D15
**Owner:**
- `install.sh`, `tests/install.bats`, `tests/install_tty.bats`.
- `scripts/release.sh`, line 24 only, and only under D6.
- `tests/audit_regressions.bats:106`, only under D10(c), and only after C1 commits.

**Order:** lands after C1 and before C6.

**Size:** about 250 LOC in the worst case, with every decision approved (estimated). **Pass 2:** about 425 LOC worst case (§6). C7 also takes tests/install_plan.bats, tests/install_failure.bats and tests/install_writes.bats for Wave C, because C7.1 and C7.4 change what they pin. C8 follows C7 and holds install.sh after it.

- **C7.1 Error copy** (R276, R277, R280, R102, R285, R004; the prefix is R205 via D6). install.sh:31, :80, :198, :226, :228, :244.
  - **Not decision-gated, except the prefix.** It sits in Wave C so install.sh has one owner per wave, and so it can share D6's glyph set.
  - **New `_die` layout:** a headline, a blank line, an instruction ending in `:`, then the command indented 4 spaces.
  - **Per site:**
    - :31 puts its URL in a runnable `curl … | bash` line.
    - :198 gives `mv "<path>" "<path>.bak"`.
    - :226 shrinks from 317 characters (measured with `wc -c`) to about 85. It then gives the pinned-tag one-liner and `AGENT_SECRETS_BASE_URL=<MIRROR_URL> bash install.sh`.
    - :228 names the URL.
    - :244 drops the maintainer `git archive` instruction and its `${TAG}` placeholder (R102), and points at `https://github.com/renchris/agent-secrets/issues`.
  - **Compatibility.** Keep exit 1 and the pinned substrings: "no baked release digest", "SHA-256 mismatch", "not a directory".
  - **The prefix.** `ERROR:` stays unless D6 is approved. If it is, the prefix becomes `Error:` (`✗` on a TTY) here, in lib/common.sh:96 (C4) and in scripts/release.sh:24, all together. tests/wizard_interactive.bats:28 is already updated by C4.
  - **Tests:**
    - The three pinned substrings still match.
    - :226's headline is 100 characters or fewer (R277).
    - Each new install.sh recovery command passes the parse-only seam (B9.3f) with exit 0: the pinned-tag form, and `AGENT_SECRETS_BASE_URL=<MIRROR_URL> bash install.sh` with a synthetic URL (R100).
  - **Pass 2 additions** (R275, R276, R277, R280, R285, R205; finding "Errors lack recovery"). B12.1 already wraps fetch failures. These rows are the remaining copy, and the verdict's contract is compatible:
    - **`_die` layout helper at :80:** headline, optional rows, blank line, then recovery with the command indented 4 spaces. No global ERR trap. `Error:` plain, and `✗` only when `[ -t 2 ]`, both under D6.
    - **:228:** `Couldn't verify <file>. SHA-256 mismatch.`, with `URL`, `Expected` and `Actual` rows (the URL through `_agsec_show_url`). Recovery is `_self_cmd`, plus the issues link if it repeats. The gate stays fail-closed and before any mkdir. The pinned substring `SHA-256 mismatch` stays (tests/install.bats:79).
    - **:226 (now in B12.2's guard):** `Can't verify this installer. It carries no baked release digest.` Move the reason to a detail row. Recovery offers two options (R280 allows at most two): the pinned release one-liner, or `AGENT_SECRETS_BASE_URL=<MIRROR_URL> bash install.sh`. The pinned substring `no baked release digest` stays (tests/install.bats:69).
    - **:198 (now in `_preflight_dirs`):** `Can't install into <dir>. It's not a directory.` Recovery: `mv <path> <path>.bak`, then `_self_cmd`. The pinned substring `not a directory` stays (tests/audit_regressions.bats:109). Its first line is under 100 columns; the finding's "no recovery" claim was overstated for this site, because it does name one in prose.
    - **:244 (now against staging, B13.2):** tell end users the release is mis-cut and link the issues page. `git archive` appears only under `If you run a mirror, rebuild with:`.
    - **:31:** stay inline and POSIX, because `_die` is not defined there. `Error: Couldn't fetch install.sh from <url>.` The recovery must drop the stale "it curl-pipes this URL", since README.md:58 now uses `-o` then `bash`.
    - **Record, do not silently fork:** lib/common.sh:96 and scripts/release.sh:24 keep `ERROR` unless D6 moves all three together.
    - **Tests:** the headlines of :226, :228 and :198 are 100 characters or fewer (R277). :228's rows name the expected and actual digests. Each pinned substring still matches. `status -eq 1` on each.
- **C7.2 Presentation** (R205, R186, R230, R211, R232, R231; R185 is weak, per its verdict). Compatible.
  - **Glyph table next to `_say`.** Plain mode applies when `AGENT_SECRETS_PLAIN` or `NO_COLOR` is set, with `--no-color`, when `[ -t 2 ]` is false, or when `TERM=dumb`.
    - The pairs are `→`/`->`, `•`/`-`, `·`/`,` and `│`/`|`.
    - They are used at :79, :138-155, :175, :349, :353, :355 and :362-367.
  - **Banner.** :162 becomes `Showing the install plan. Nothing will change.`.
  - **Em-dash chains.** Rewrite the chains at :138, :149, :155, :226 and :349 as sentences. Keep every pinned substring whole and on one line (the B9 header lists them), and never add "real terminal".
  - **Wrapping.** Wrap plan bullets at `${COLUMNS:-80}`, with continuation lines indented 4 spaces. Split :143 into two bullets so that "back up an existing ~/.claude/settings.json" starts a bullet. Today's source lines run 180, 185 and 191 characters at :143, :149 and :155 (measured with awk length).
  - **Tests:**
    - Plain-mode stderr has no non-ASCII byte (`LC_ALL=C grep '[^ -~]'` is empty).
    - At `COLUMNS=80`, no plan line is over 80 columns unless it is a single unbreakable path.
    - B10's transcripts are extended.
  - **Pass 2 additions** (findings "Glyphs and layout", "Copy voice and nouns"; R186, R205, R181, R182, R009, R046, R231, R131, R230). All compatible; each keeps every pinned substring and stderr as the stream.
    - **The selector tests fd 2, not fd 1.** Every glyph here goes to stderr, and `agsec_use_plain` (lib/common.sh:74-79) tests `[ ! -t 1 ]`, the wrong stream under R115. Inline it next to `_say`, as `_agent_session` is inlined. D26 decides whether `NO_COLOR` alone selects plain glyphs.
    - **More pairs:** `…`/`...`, ` — `/` - ` and `·`/`,` or `/`. Measured by the verifier: 36 output lines have non-ASCII bytes (`grep -nP` piped to `grep -E`), mostly `—` and `…`. R205 names `…`; `—` is an extension of it.
    - **Substitute in templates only.** Do not run sed or translate over whole messages: `$INSTALL_DIR`, `$BIN_DIR`, `$IMPORT_ENV` and `$_pth` are user data and keep their bytes. Sites beyond the row above: :94, :97, :162, :175, :198, :212, :226, :228, :244, :384.
    - **:31 is ASCII unconditionally:** it is in the POSIX guard, before any helper, and nothing asserts on it.
    - **Plain rows start at column 0** (R205), and `_step` in plain mode prints just the command.
    - **Result rows.** Split the receipt as `✓ Installed agent-secrets v0.1.3.` in rich mode and plain `Installed agent-secrets v0.1.3.`. Do not put `✓` on `SHA-256 verified.`, which is secondary progress (R182), or on plan and discovery rows. No `%-16s` table helper is needed: `grep -c '%-' install.sh` is 0, so R181 is thin here.
    - **One noun: "agent rules"**, the name lib/help.sh:38-39 and cmd/doctor.sh:312-323 already use. Change "agent-secrets rules" at :145 and :149, and "machine-wide discovery" at :349 and :367. Keep `--no-discovery` and `setup --discovery` as option names, and keep doctor's JSON values (`"category":"discovery"`). Keep "block" only for the physical file section, written as "agent rules block" at :352 and :354, so it stays distinct from the "PATH block" at :141. Do not edit `agsec_render_rules` output: it sits under an integrity marker.
    - **Case (R231).** "OFFER" and "EVERY" at :145, "EVERY" at :149, "NO" at :155 and "EACH" at :352 go to sentence case.
    - **:356 (R131):** `[y = yes, write them (recommended) · Enter = skip (default)]: `, and the `[yY]*` case at :358 is unchanged.
    - **R230 is narrower than the row above says.** The verifier counted at most one em dash per printed line (awk over :139-165 and :345-370), so there are no real chains. Treat those rewrites as optional style, and keep `agent-secrets installer` at :141 (tests/one_command.bats:49).
    - **Tests:** a `--dry-run` with `TERM=dumb` and with stderr redirected has no bytes outside ASCII apart from user paths. A rich-mode check needs a pty (B10's transcripts). `agent rules` appears, and `agent-secrets rules` does not, in the plan.
- **C7.3 C3's install.sh rows, corrected.**
  - **F8, only if D5 is approved.**
    - When install is not interactive (B9.7), forward `--discovery` to setup only as `--headless --discovery`.
    - On an interactive TTY, do not forward it. Instead it pre-answers install's own prompt at :346: write the rules without asking (R125). **Pass 2:** B9.3(d) now ships that pre-answer in Wave B. This row adds only the forwarding.
    - The plan line and the usage text change as C3 said.
  - **F28.** When setup exits 1 after C3's health-check change, B9.10's failure branch reads `Setup finished with problems. Run: agent-secrets doctor`.
  - **Tests:**
    - `install.sh --discovery` on a TTY still runs the wizard (B10 harness).
    - Without a TTY it passes `--headless --discovery`; assert this through a setup argv log shim.
- **C7.4 Decision-gated items.** Each lands only if approved:
  - D9(A): delete the TTY prompt.
  - D10(b) or (c): consent flags.
  - D11(B): require `--headless`.
  - D12(A): strict dry-run exit.
  - D13(a): https-only.
  - D15(a): sentinel rename. Set and check both `__AGENT_SECRETS_REEXECED` and `AGSEC_REEXECED` for one release, because an older install.sh re-fetched through `AGENT_SECRETS_INSTALL_URL` checks only the old name and would otherwise re-exec in a loop.
  - Each item updates its callers in the same commit, as listed in its decision.
  - **Pass 2 adds:** D17(A) rebind narrowing; D18 option 2; D19(b) `exec`; D20(B); D21(B); D23(B); D25(b). Each lands only if approved. D13's row now also covers `--proto` on the self re-fetch at :30 (B12.1's code gains it).
- **C7.5 Install's stdout carries only the identifier** (R016, R173, R177). install.sh:385. Finding "stdout carries setup prose". **Contract: breaking.** The guideline's table classes a stream change as a contract change, even though no repo caller depends on it. Ship in the tagged release with a release note. Not decision-gated: no repo rule documents a different contract (`grep stdout` over AGENTS.md and the rules file found only never-print-secrets).
  - **Verified:**
    - install.sh's own lines use stderr, but :385 inherits stdout for setup.
    - A.8 moves `ui_title`, `ui_say` and `ui_step` to stderr. `agsec_ok`, `agsec_attn` and `agsec_bad` stay on stdout by design (A.2), and setup's `doctor.sh --summary` prints rows through them (setup.sh:571, :589). So `x=$(bash install.sh)` still captures prose after Wave A, and no identifier.
    - R273's wrapper exemption covers a user-named child, not the tool's own subcommand chained as a step, so it does not excuse this. The tension is recorded here.
  - **Change** (install.sh only; do not edit lib/ui.sh or cmd/setup.sh for this):
    ```sh
    _run "$BIN_DIR/agent-secrets" setup ${setup_args[@]+"${setup_args[@]}"} >&2
    if [ ! -t 1 ] || [ "$INTERACTIVE" -eq 0 ] || [ "$HEADLESS" -eq 1 ]; then printf '%s\n' "$BIN_DIR/agent-secrets"; fi
    ```
    - The identifier is the dispatcher path only, not "path or version". AGENTS.md:60-61 tells agents to call that path.
    - It is suppressed on an interactive TTY (R173), and it runs after B11.4's offer, so it is the last thing printed.
    - It prints only on exit 0: `set -euo pipefail` (:35) aborts before the printf if setup fails, and setup's exit code still propagates.
    - The dry run returned earlier (:161-166), so it prints nothing on stdout.
    - This depends on D19(a).
  - **Tests** (tests/install.bats, `--separate-stderr` or redirects):
    - A headless install's stdout equals exactly `$AGENT_SECRETS_HOME/bin/agent-secrets`.
    - Dry-run stdout is empty.
    - Failing setup: stdout empty (R176).
    - The merged-output assertions stay as they are, because bats `run` merges streams (`grep -rn separate-stderr tests` found nothing).
  - **Callers:** tests/install.bats:121-125 and :146 (`You're set up`, `imported SEEDED_TOKEN`) still match through the merge. tests/one_command.bats:45 uses `2>&1`. No `$(…install.sh)` capture exists; the README.md:69 and install.sh:12 matches capture curl. External scripts using `bash install.sh >log` would see a change. Tag-pinned URLs keep the old behaviour.
- **C7.6 Docs for C7.5.** C6 adds the stream note to the install section. The release note names the change.

### C8 (new): install.sh `--json` result. Decision D24
**Owner:** `install.sh`, `tests/install_json.bats` (new). **Order:** after C7, before C6. **Size:** about 180 LOC (estimated). Finding "No --json result for an agent-run mutation" (R243, R244, R248, R253, R254, R325). Verdict contract: compatible.

Default-mode text, streams and exit codes stay byte-identical. Every line is gated behind `--json`.

- **C8.1 Parsing.** Pre-scan argv for `--json` before the parser, so `--bogus --json` still yields a JSON error. This replaces B10's `json-tty` assertion (exit 2) in the same commit, and it joins B9.4's `--version --json`. Unknown options exit 2 either way. The bash-guard failure at :31 runs before main and must stay POSIX-clean: a `case " $* " in *" --json "*)` branch prints a hand-written one-line error document. Add `--json` to help.
- **C8.2 Stream isolation.** "Separate setup's stdout" is not enough. As soon as JSON mode is known, run `exec 3>&1 4>&2; exec 1>"$log" 2>&1`, with `$log` an mktemp 0600 file. That captures setup's stdout, `doctor.sh --summary`, `_say`, `_step`, `_render_plan`, `agsec_*`, and raw curl and tar output. Delete the log on success.
- **C8.3 One EXIT path.** Raw `set -e` aborts and `agsec_die` bypass `_die`, so the error document cannot live in `_die`. `_agsec_on_exit` (B12's shared design) emits on fd 3 for success and fd 4 for failure, and preserves `$?`.
- **C8.4 No jq for the document.** deps_ensure does not run until :274, so jq is not guaranteed. Use a small bash 3.2 string escaper for all documents, including paths such as the `o'brien` home at tests/install.bats:172.
- **C8.5 Success document** (R248, R251, R325):
  `{"installation":{"version","install_dir","bin_dir","state_dir","manifest"},"outcome":"installed"|"planned","next":[{"command":"<bin_dir>/agent-secrets doctor"}]}`.
  - `--dry-run --json` returns outcome `planned` with a `changes` array, which is the machine form of the plan disclosure.
  - Compact unless fd 3 is a TTY.
  - Use snake_case, matching `help --json` (`exit_codes`, `names_only`). This is recorded against R246 as E10.
  - Do not claim health: setup runs `doctor --summary || true` (setup.sh:589), and C3's F28 changes that only if approved. Keep the doctor step in `next`.
- **C8.6 Error document** (R253-R261): one line, last on stderr, with status, reason, message, next and data (including the log path). `action_required` only before any effect, `error` after one (R254).
- **C8.7 Consent** (R010, install.sh:5). `--json` skips `_attach_tty` and every `read`, and passes `--headless` to setup, so setup.sh:558-560 cannot attach a tty. **`--json` must not become a keypress bypass.** If stdin is a real TTY at :174, refuse before any mutation with `action_required`, reason `confirmation_required`, `userActionRequired:true`. Non-TTY stdin keeps the documented path at :168-172. D24 covers the remaining disclosure question.
- **C8.8 Tests** (tests/install_json.bats): success (stdout passes `jq -e`, stderr empty); usage error; dependency failure (one-line stderr document, residue removed); dry-run `planned`; TTY refusal; the mode matrix for `json-tty` (R403); a parser pin for each new help example (R100).
- **C8.9 Docs.** Do not change AGENTS.md:44-45 to advertise `--json` until a tag carries it: the pinned v0.1.3 install.sh rejects it, and release publishing is user-gated (.claude/rules/agent-operating-lessons.md). C6 adds the row after the tag.
- **Callers:** no repo caller passes `--json` to install.sh or asserts that it is rejected (`grep -rn 'unknown argument' tests` found none). `tests/help.bats:54` and `:91` pin 11 commands, and install.sh is not in that manifest. The cleanup-trap tests at tests/install.bats:159-185 must stay green, because C8.3 changes the EXIT path.

### Needs decision (round 2)

Each decision gives both options. "Recommended" marks the option the plan implements by default; for D9-D14 that is the compatible one already in B9. The repo's documented contract and its callers win over a checklist rule. Where they conflict, the conflict is recorded here and in the exceptions below; the rule is not dropped.

**Pass 2 reading guide.** D17-D26 are new. For D10, D13 and D17 the recommendation differs from what ships before the operator answers, and each one says so: Wave B keeps today's contract there, and the recommended change lands in C7.4 only if approved. D18-D26 otherwise follow the rule above.

- **D5, sub-question: a positive discovery option for install.**
  - (a) C7.3's corrected passthrough.
  - (b) No install-level `--discovery`. The positive form is `--no-discovery=false` (B9.3c), and users run `agent-secrets setup --discovery` afterwards.
  - Recommend (a) if D5 is approved, (b) otherwise.
  - **Pass 2:** R068 and R455 require the positive form, so (b) no longer holds. B9.3(d) accepts `--discovery` in Wave B and never forwards it, which is safe with D5 unanswered. D5 now decides only whether C7.3 adds the forwarding.
- **D6, extended:** the `ERROR:`/`Error:` choice also covers install.sh and scripts/release.sh:24 (C7.1).
- **D7, extended:** add R252's `--fields` to list (C5) and doctor (C4), or record an exception. Both are additive; recommend adding them with the list object shape.
- **D9: install.sh's interactive consent prompt** (finding "Typing 'n' at the consent prompt still installs").
  - Rules: R125/R156 (an intent-stating command needs no confirmation) against the repo's documented human gate (install.sh:4-5, :167-173).
  - (A) Treat install as an ordinary action. Delete the TTY prompt, and keep the rendered plan as the preview.
  - (B, recommended, implemented in B9.5) Keep the gate with Enter = install and `n` = exit 130.
  - A strict default-No (R147) is a third, breaking option: bare Enter would cancel for interactive users who press Enter today. Install is reversible through the manifest, so R147's "destructive" premise is weak.
- **D10: consent without a TTY, and the consent options** (findings "Runs without a TTY install with no --yes" and "Missing standard global options").
  - Rules R146, R010, R439 and R117 conflict with the repo's design:
    - install.sh:5: "STOP-ASK gates have NO --force/env bypass";
    - install.sh:167: "no --force/env bypass";
    - AGENTS.md:38-49: zero-human install;
    - docs/plans/AGENT_ENTRYPOINT_HEADLESS.md:38 and :136;
    - tests/install.bats:110 and :138 pin exit 0.
  - The plan's own A.4 says "non-interactive mode never grants consent", which install.sh's no-TTY path deliberately breaks.
  - (a, recommended) Record exception E1 and add no `--yes`. Add `--non-interactive` only as a safe alias: without a TTY it equals `--headless`; on a TTY it exits 2, saying consent needs the keypress. The prompt is never skipped.
  - (b) Add `-y/--yes`, which only skips the TTY keypress. The no-TTY path is unchanged. This contradicts install.sh:5 and needs the maintainer's sign-off.
  - (c) Strict, and breaking. With no TTY and no `--yes`, exit 2 with `Can't install agent-secrets without --yes in non-interactive mode.` plus the exact command, placed after the `--dry-run` return (install.sh:161-166). The same commit adds `--yes` to:
    - AGENTS.md:45, README.md:58 and :129, docs/FAQ.md:67;
    - tests/install.bats:67, :77, :88, :103, :119, :143, :166, :180;
    - tests/audit_regressions.bats:106.
    It also rewrites install.sh:5 and docs/plans/AGENT_ENTRYPOINT_HEADLESS.md:38 and :136. Installers already pinned at v0.1.3 keep the old behaviour.
  - Under any option, an optional `--json` install receipt (R243) can be added: `{"install":{"version","path"},"outcome":"installed"|"planned"}` on stdout, with progress staying on stderr. No caller needs it.
  - **Pass 2 (finding "Having no TTY counts as consent").** R439 and R124 are generalized checklist rules, so `--yes` is not dropped. The verifier recommends (b), so **the recommendation moves from (a) to (b)**. Nothing lands until the operator answers, because install.sh:5 is the repo's stated contract. Both options stay.
    - **(b), in detail (compatible; all callers preserved):**
      - Tier the install as ordinary. Add `-y|--yes` to the parser and to help. The gate becomes `if [ "$INTERACTIVE" -eq 1 ] && [ "$ASSUME_YES" -eq 0 ]`.
      - `--yes` answers only that gate. It supplies no data, is not forwarded to setup, does not imply `--headless`, and does not answer the discovery offer (R010). Unattended on a terminal is `--yes --headless`.
      - Non-TTY behaviour and exit codes stay unchanged, so no test or one-liner changes.
      - Correct install.sh:5, :168 and :338 and SECURITY.md:65 (B11.1 and B8.16 do this under every option).
      - Repo precedent: cmd/backup.sh:18 already has `--yes`.
      - Tests: `--yes` on a pty skips the gate; `--yes` with no TTY equals today's behaviour; `--yes` is not forwarded to setup (argv log shim).
    - **(c), corrected counts (breaking):** the verifier counted **7** tests that would fail, because the gate at :174 runs before preflight, the digest check and setup: tests/install.bats:67, :77, :88, :103, :119, :143 and tests/audit_regressions.bats:106. A further 2 (tests/install.bats:166 and :181) would pass vacuously and stop exercising the cleanup trap, so each needs `--yes` too. install.sh has no `--json`, so `confirmation_required` can only be a text code unless C8 lands. cmd/doctor.sh:149, :166, :314 and :316 say "re-run the installer" and also assume a bare re-run works.
    - **Under every option:** the env route must be either closed or documented, because `CLAUDECODE=1 … </dev/null` at a real terminal skips the gate. D18 decides which.
    - **The rules cannot all apply together.** R146's destructive tier, R010 and R124's `--yes` path assume a destructive tier; R125 and R158 assume an ordinary one. Under the ordinary tier the non-TTY path is compliant and the TTY prompt is the violator. R014 and R006 hold on either tier.
    - **"High" is arguable.** The install is explicit, recorded and loses no data, and the repo reserves STOP-ASK for data loss. The strongest destructive argument is the discovery fan-out into other tools' agent files (SECURITY.md:60).
- **D11: no-TTY runs chain into headless setup** (finding "Mode is resolved inline").
  - (A, recommended; B9.7 does the compatible part) Exception E2.
  - (B) Without a TTY, or in CI, fail fast unless `--headless` is explicit. This is breaking: it changes AGENTS.md:44-45 and tests/install.bats:119, :166 and :180, and needs a release note.
  - If D5 is approved (discovery off by default), E2's user impact shrinks.
- **D12: the dry run on an unreleased install.sh** (finding "--dry-run only prints the plan").
  - (B, recommended, in B9.8) Report REFUSE in the plan and exit 0.
  - (A) Exit 1. The same commit must give tests/install.bats:51, :153 and tests/one_command.bats:45 an `AGENT_SECRETS_BASE_URL` or a baked digest.
  - Every published tag carries a baked digest (v0.1.3:install.sh:51), so this only matters on main.
- **D13: `--proto '=https'` on install.sh's fetches** (finding "Downloads have no ... timeout").
  - (a) Force https. This breaks any http or file mirror that `AGENT_SECRETS_BASE_URL` or `AGENT_SECRETS_INSTALL_URL` allows today; the docs only show https (docs/FAQ.md:65).
  - (b, recommended) Keep the scheme open. lib/deps.sh:95 already pins https for the dependency binaries.
  - **Pass 2 (finding "The re-exec path"; R470, R011).** The self re-fetch at :30 differs from :213 and :223: its text is executed with no digest (:32), while the tarball is checked afterwards. So add a third option, and recommend it:
    - (c, recommended) `--proto '=https' --tlsv1.2` on :30 only, and keep :213 and :223 open. An `http://` or `file://` `AGENT_SECRETS_INSTALL_URL` then fails with the existing :31 error. No in-repo user sets that variable (only install.sh:20, :29 and docs/FAQ.md:71 mention it), and the FAQ's mirror examples are https. An external non-https mirror would break, so name this in the release note. It stays gated, because (b) was the plan's default.
- **D14: setup's exit code through install** (finding "Real outcomes are hidden", and F28).
  - (a, recommended) Pass setup's code through; R337 allows a wrapped child's code.
  - (b) Normalise it to 1, as C3's F28 row was written.
  - No caller depends on either.
- **D15: the internal environment-variable prefix** (finding "Env vars that change behavior are undocumented", and A.13).
  - R079 wants `__AGENT_SECRETS_` for internal and test variables.
  - The repo uses `AGSEC_` for about 19 of them. The verifier measured AGSEC_CONFIRM_SRC ×38, AGSEC_MOCK_GH_REMOTE ×23, AGSEC_TEST_CONFIRM ×15 and AGSEC_MOCK_DL_DIR ×10 (`grep -rhoE '_*AGSEC_[A-Z_]+' | sort | uniq -c`).
  - (a) Rename all of them in one pass. The install.sh sentinel keeps both names for one release (C7.4).
  - (b, recommended) Keep `AGSEC_` and record exception E4.
  - Also: R074 would make an explicitly empty `AGENT_SECRETS_HOME` fail rather than fall back to `$HOME`. Recommend documenting the empty-as-unset behaviour instead (B9.1), which R079 allows.
- **D16: a noun glossary** (R423, a MUST; no glossary exists).
  - Measured synonyms (`grep -oi` counts in lib/help.sh / cmd/*.sh):
    - "public key" 6/8, "pubkey" 14/8 and "recipient" 13/37 all name the same thing;
    - "credential" 0/3 and "vault" 0/2 compete with "secret" and "store".
  - (a, recommended) C6 adds the glossary and the help.sh lint. Draft:
    - **secret**: a NAME=value entry in the store; selector NAME; banned: credential, vault entry.
    - **store**: the encrypted secrets.env; banned: vault.
    - **recipient**: an `age1…` public key that can decrypt an envelope; banned in prose: public key. The `pubkey` command name stays.
    - **envelope**: the armored block share prints.
    - **recovery key**: the off-machine age private key.
  - (b) Record an exception.
- **D17: the `/dev/tty` rebind** (finding "Mode resolution ignores CI, stderr and agent sessions"; R014, R119, R113). install.sh:125-132; documented as deliberate at install.sh:120-124, lib/common.sh:168-171 and docs/plans/ONE_COMMAND_SETUP_V2.md:87 and :157 (the verdict cited :141-145, but those lines are a results table; corrected by grep here).
  - **Verified:** `</dev/null` and `echo y |` on a machine with a usable /dev/tty are rebound to the terminal (:129). So the non-interactive signal is lost, and so is the UNATTENDED seed line. `echo y` was never accepted as an answer (:181-186 never read stdin), so R119 applies narrowly.
  - **(A, recommended to the operator)** Rebind only when the script itself arrives on stdin. A redirected file run is non-interactive.
    - Detect with `_AGSEC_SRC="${BASH_SOURCE[0]:-}"` at top level after :35, plus `[ -z "$_AGSEC_SRC" ] && [ -p /dev/stdin ]`.
    - A `$0` file test is wrong. The verifier measured on bash 3.2.57: `printf … | /bin/bash` gives `$0=/bin/bash`, which is a file. Top-level `BASH_SOURCE` was empty for piped and `bash -c` runs and set for a file run, and `[ -p /dev/stdin ]` was true for a pipe and false for `</dev/null`.
    - setup.sh:558 would re-attach by itself, so in that case install exports `AGENT_SECRETS_NONINTERACTIVE=1` for the child. B6.2's branch then gives a true reason. Do not forward `--headless` (B11.6).
    - Cost: `bash install.sh </dev/null` at a terminal stops prompting and does the real headless setup, including global discovery. It also makes the non-TTY tests hermetic (B10.5), and README.md:79 already discourages the piped form.
    - Lands in C7.4.
  - **(B, in force until answered)** Keep the rebind everywhere, keep exception E2, and use `--non-interactive` (D10) as the opt-out.
- **D18: does a detected environment replace the consent keypress?** (findings "Mode resolution", "A declined discovery offer", "Mode detection is duplicated"; R113, R117, R124 against install.sh:4-5 and :168). The verdicts disagree, and the repo's documents disagree with each other.
  - For skipping: AGENTS.md:38-48 ("no human step"), README.md:154-155 ("nobody to prompt"), install.sh:108-110, and :171 ("running the installer IS the consent").
  - Against: install.sh:5 and :168 ("no --force/env bypass").
  - **(1, implemented by B9.7, recommended)** Agent session, CI and `2>log` on a TTY skip the keypress and take the no-terminal branch. Today an agent on a pty blocks on an unbounded `read` at :176. A user-facing contract outranks a code comment, so B11.1 corrects the comment. Cost: an environment variable can skip a human's keypress at a real terminal, though `CLAUDECODE=1 … </dev/null` can do that today.
  - **(2)** Keep the keypress for anything a human supplied (`2>log`, `--non-interactive`) and skip it only for a detected agent and CI.
  - **(3, the default in two verdicts)** Keep raw `[ -t 0 ]` at the keypress, with no behaviour change. An agent on a pty keeps hanging, which contradicts AGENTS.md.
  - Options 2 and 3 land in C7.4, and B10's matrix rows change with them.
- **D19: how install hands off to setup** (R416 against R123, R240, R173, R187). install.sh:385. Three verdicts and B9.10 need control back after setup (the offer, B11.4; the stdout identifier, C7.5; the lock release, B13.3; B9.10's setup-failure report and final receipt). One verdict says `exec`.
  - The verifier's model scripts: with a trap set, bash defers it until the foreground child returns (the handler fired at 2 s, not 0.2 s). With no trap, the shell dies and leaves the child running. Background plus `wait` is not an option: the child starts with SIGINT ignored and cannot re-trap it, and its stdin becomes /dev/null.
  - **(a, recommended, implemented)** Keep setup as a child. Ctrl-C still reaches setup, because the terminal signals the whole foreground process group. A TERM or HUP sent only to the installer's pid is handled after setup returns, so R416 is partly met. Exception E12 records this.
  - **(b)** `exec` at :385. R416 is met, and setup gets signals directly. It loses the post-setup receipt, the stdout identifier (a recorded R173 exception) and the post-result offer (the offer returns before setup, per B11.4's fallback). The lock must be released before the `exec`, so setup is unguarded.
- **D20: same-version re-run** (finding "A re-run overlays in place"; R326 against the repo's repair path, cmd/doctor.sh:149, :163, :166, :314-316).
  - **(A, recommended, implemented in B11.3 and B13.2)** Print `already installed` and re-apply everything. R326 asks for `already Y` and exit 0, which this meets in text, and the flow continues because a re-run is the documented repair.
  - **(B)** Print it and skip only the download and swap when the version matches. This is faster, but VERSION alone cannot prove the tree is complete after an interrupted overlay, so it cannot repair a damaged install.
- **D21: replacing a file the installer did not create** (finding "wrapper symlinks"; R146, R350 against install.sh:5 and AGENTS.md:38-47).
  - **(A, recommended, implemented in B13.1)** The backup and restore make it reversible, so treat it as R146 ordinary, with no confirmation.
  - **(B)** Strict R146 and R350: an interactive y/N and a required `--yes` when a non-interactive run finds a foreign target. This is breaking for agent installs that hit one (tests/install.bats:119 expects exit 0). It adds a bypass flag the repo rejects, unless D10(b) is approved.
- **D22: "reversible" outside the CLI output** (finding "Copy promises"; R157).
  - **(A, recommended, implemented in B11.5, B6.16, B8.17)** Change only printed strings. README.md:112 and :377, SECURITY.md:66, AGENTS.md:58, assets/hero.svg:41 and the reversible.mmd diagram keep the word, so docs and CLI differ.
  - **(B)** Also rewrite the docs and assets. That means regenerating the diagrams and a larger, separate change. Under (B), that unit runs `[ -d node_modules ] || npm ci` and `npm run diagrams:check` (§1), because README fence blocks would change.
- **D23: the `sh` path** (finding "The re-exec path"; R470).
  - **(A, recommended, implemented in B9.15)** Keep the re-fetch, narrow line 6's claim to the tarball and dependency binaries, and document the override as unverified. install.sh:12-14 promises both `bash` and `sh`, and docs/feedback/ONE_COMMAND_INSTALL_FEEDBACK_V2.md:54-57 records the `sh` form exiting 0.
  - **(B)** Drop the re-fetch, print the exact bash command, and exit 2. This is breaking for the `curl | sh` outcome, and it contradicts those two sources.
  - A digest on the re-fetch is not offered: install.sh is the declared trust root (:46-47), and a self-digest is a fixed-point problem.
- **D24: disclosure under `--json`** (C8; R244 against install.sh:168-172, which treats the shown plan as the disclosure).
  - **(1, recommended)** Non-TTY `--json` proceeds, and the result document lists the changes, because stderr must stay empty.
  - **(2)** Require a new explicit consent flag. This conflicts with install.sh:5 unless D10(b) is approved.
  - Separately: `--format=json` on doctor and list needs no decision here. B2.4 and B7.2 already add `--json` and keep `--format=json` as a deprecated alias. `--format` is never added to install.sh (R438).
- **D25: credentials in a mirror URL** (finding "Credentials in a mirror URL"; R018, R355).
  - **(a, recommended, implemented in B12.1, B9.14)** Redact in output, and keep credentialed URLs working. `ps` can still see the URL in curl's argv.
  - **(b)** Reject userinfo in the URL. This also closes argv, but breaks anyone using URL credentials today (no repo doc shows that usage). Closing argv without rejecting needs a curl config input and a matching change to tests/mocks/curl:19.
- **D26: does `NO_COLOR` also select plain glyphs?** (finding "Glyphs"; R207 against AGENTS.md:151 and lib/help.sh:20, which document `NO_COLOR` and `AGENT_SECRETS_PLAIN` as plain output with no box-drawing).
  - **(A, recommended, implemented in C7.2)** Yes, because the repo's documented contract wins. Recorded as a conflict with R207.
  - **(B)** `NO_COLOR` keeps glyphs per R207, which requires changing AGENTS.md:151 and lib/help.sh:20.

### Exceptions to record (R422)

Each record states the rule, the reason, the user impact and the test that pins it. They go in SECURITY.md or AGENTS.md, owned by C6, and are written only for the options the operator picks.

- **E1: install.sh treats running it without a TTY as consent** (R146, R010; basis R156). Applies if D10(a).
  - **Reason:**
    - The command name states the intent.
    - Every target is fixed under `$HOME`, not inferred. **Pass 2 fix (R156):** this is false for discovery. The discovery targets are inferred from what is present on the machine, and R156 requires an inferred target in argv non-interactively, so stated intent alone does not cover it. The record must name that, and `--no-discovery` is the opt-out. It must also name both residual behaviours: the same argv prompts on a TTY but proceeds without one, and discovery writes inferred targets by default off-TTY (setup.sh:552) but defaults to skip on a TTY. Reference tests/install.bats:119. E1 also applies if D10(b) is chosen, because (b) changes only the TTY path.
    - The plan is always printed first.
    - Every change is recorded in install-manifest.json, so one `uninstall` reverts it.
    - AGENTS.md:38-49 documents the zero-human install.
  - **Impact:** an agent can install unattended, including machine-wide discovery rules unless it passes `--no-discovery`.
  - **Tests:** install.bats:110 and :138, plus B9.13's message.
- **E2: install.sh re-attaches /dev/tty under a pipe, and a no-TTY run goes headless** (R113, R014, R408). Applies if D11(A).
  - **Reason:** this keeps `curl | bash` one command for a human (install.sh:120-124), and agents follow AGENTS.md:44-49.
  - **Impact:** the same command writes discovery files without a TTY and offers them, defaulting to skip, with one. A `2>file` run on a terminal now proceeds without the keypress (B9.7).
  - **Tests:** install.bats:110, :152 and :159; B10's matrix.
- **E3: agent sessions never prompt, and there is no `--non-interactive=false` override** (R117).
  - **Reason:** an agent's pty is transcript-captured, so a "hidden" prompt there is not hidden. See setup.sh:543-545 and the comment at install.sh:122-124.
  - **Impact:** a human working inside an agent session runs setup and receive in a real terminal.
  - **Tests:** headless.bats, install.bats:110, B6.12's `agent` row.
- **E4: internal variables keep the `AGSEC_` prefix** (R079). Applies if D15(b).
  - **Reason:** about 19 internal and test variables already use it.
  - **Impact:** none for users; none appear in help.
  - **Test:** a help.bats check that no `AGSEC_` name appears in `help --json`.
- **E5: share's tty gate has no flag** (R124, R014). This is round 1's "dropped by design" (§5), now recorded as an exception.
  - **Reason:** the gate is the exfiltration boundary (share.sh:46-51), and a flag would let an agent share a value.
  - **Impact:** sharing always needs a human at a terminal.
  - **Tests:** share.bats:226-246, B3.15.
- **E6: the setup wizard does not summarize its answers before the first mutation** (R135, first half).
  - **Reason:** each question follows the step it governs. The key mint at setup.sh:576 comes before the first question (:171), and the recovery-key question depends on the minted key, so there is no batch of answers to summarize.
  - **Impact:** none beyond the per-step screens.
  - **Tests:** the replay half is implemented (B6.10); wizard_interactive.bats:148.
- **E7: the dispatcher's `--version` prints `agent-secrets <version>`, not the bare version** (R086). Round 1's B7.8 kept this form.
  - **Reason:** tests/dispatcher.bats:74 pins the `agent-secrets ` prefix. Callers outside the repo were not searched.
  - **Impact:** a script must strip the prefix, or use `--version --json`, which B7.8 adds.
  - **Alternative:** switch to the bare version in B7.8 and update dispatcher.bats:74. Install's new `--version` (B9.4) prints the bare version, because it has no callers.

**Round 2, pass 2 records.** E2 now applies if D17(B) or D11(A) holds.
- **E8: usage errors do not name a token that may hold a value** (R304).
  - **Reason:** names only in every output (SECURITY.md:186, tests/headless.bats:86, install.sh:8). A typo or stray positional can carry a secret. R355 also forbids echoing it.
  - **Impact:** `--foo=value` names only `--foo`, and a surplus positional is not repeated.
  - **Tests:** tests/common.bats (pass 2), B9.2, B6.14.
- **E9: install.sh's help is hand-written, and help is found by a pre-scan** (R087, R063).
  - **Reason:** the script runs before lib/ exists (install.sh:108), so no shared metadata can drive it, and :22-33 must answer `--help` before any re-fetch.
  - **Impact:** the two can drift.
  - **Test:** B9.16's parity test, both directions.
- **E10: JSON keys stay snake_case** (R246). C8 only.
  - **Reason:** `help --json` and the store model already use it (`exit_codes`, `names_only`, `rotate_by`).
  - **Impact:** none for repo callers.
  - **Test:** C8.8.
- **E11: install.sh keeps its own TTY and CI checks** (R408, R116).
  - **Reason:** a bootstrap duplicate, because common.sh is sourced at :265, after the checks. They are confined to `_attach_tty` and `_resolve_mode`. Other files stay under A's lint.
  - **Impact:** none.
  - **Tests:** B9.7's two tests.
- **E12: TERM or HUP sent only to the installer's pid waits for setup** (R416). Applies if D19(a).
  - **Reason:** see D19.
  - **Impact:** a stuck wizard needs the signal sent to setup or the process group. Ctrl-C works normally.
  - **Test:** B12.5's TERM tests cover the pre-setup windows.
- **E13: setup's own writes can still get SIGPIPE after the handoff** (R341).
  - **Reason:** B12.5 protects install.sh's process only.
  - **Impact:** exit 141 on a closed stderr. Setup is idempotent and resumes (README.md:315, setup.sh:102-106), so a re-run heals it.
  - **Test:** none yet; a later setup audit owns it.
- **E14: two retry gaps** (R316, R313).
  - **Reason:** :30 has no notice, because the POSIX guard has no process substitution. curl's `--retry` does not retry a connection closed mid-body (exit 18), and `--retry-all-errors` is the only native option that would, but it also retries a 404 (R314). `--speed-limit` did not fire on a stall after a partial body, so `--max-time` is the bound (the verifier measured both).
  - **Impact:** on those paths a failure surfaces at once.
  - **Test:** B12.1's flag test. Also, README.md:58 and AGENTS.md:44's bootstrap curl stays unbounded by design: B8.15 keeps it short and readable.

---

## 5. Dropped

**Whole findings:**
- "add silently replaces an existing secret value." Refuted. It is a documented upsert on an argv-named target, which is R146's ordinary tier. Refuse-plus-`--force` would break canary arming (store.sh:225), doctor's remedy, and the rules already installed in agents' configs.
- "add edits ~/.claude/settings.json as a side effect." Refuted for R354 and R366. The edit is related, announced, recorded, reversible and documented, and jq keeps all other keys. The small leftovers are folded in: the symlink write-through goes in B6.4, and the `writes` row goes in B8.6.

**Vercel-specific:** none. Every kept rule was judged general CLI practice.

**Sub-claims dropped from kept findings (one line each):**
- R209, pubkey: captured stdout is already colorless (common.sh:77).
- R125, setup: the headless auto-yes is harmless, so the proposed "exit 2 at every headless prompt" is dropped.
- R353, atomic writes: `umask 077` already runs before the writes.
- R464: `-V` already has one meaning. `-v` is added as an alias, not a fix.
- run.sh:14, "ignores unknown options": it already rejects them. Only the ordering is optional (B1.10).
- uninstall.sh:85: the best-effort `rmdir … || true` is correct.
- R147, backup `[Y/n]`: creating a private repo is additive and reversible, so the default stays.
- F10's "0600 env file": dropped. It would put plaintext secrets on disk; sops exec-env is kept.
- F11's `rotateBy`: dropped in favour of R246's `rotate_by`.
- F12's "switch doctor to jq": dropped. Doctor must run on a bare machine.
- F6's "name a flag for share's tty gate": dropped by design. share.sh:45 stays at exit 1.
- F18's "agsec_interactive at stdin-payload sites": dropped. It would read secrets with echo on.
- F25's idle timeout on relay(): dropped, because tunnels are long-lived.
- F26's EXIT trap in restore_flow: dropped, because it would clobber setup.sh:107.
- F11/F12 "deprecation note on stderr for --format=json": made silent instead, per R244.

**Round 2 notes on this section.** These are appended; the lines above stay as written.
- **"R464: `-V` already has one meaning" cited the wrong rule.**
  - R466 limits short options to Reference G, which has `-v` and not `-V`.
  - `-V` stays accepted, because tests/dispatcher.bats:69-75 calls it. It is no longer listed in help and now warns as deprecated (B7.11, B8.8).
- **The F11/F12 "made silent" choice is replaced by A.14.**
  - R385 requires a `deprecated` warning, and R244 keeps stderr empty in JSON mode.
  - So the warning goes into the JSON document where the result is an object (doctor), and onto stderr in text mode.
  - It is silent only for list's bare array, until C5 gives list an object shape.
- **F6's "name a flag for share's tty gate", dropped by design, is now exception E5** (R422). The rule is recorded rather than dropped.
- **The R147 reasoning for backup's `[Y/n]` also covers install.sh's consent prompt.** B9.5 keeps Enter = install. The strict default-No variant is D9.
- **Vercel-specific: still none.**
  - Every round-2 rule is general practice. That covers R060, R100, R107, R108, R135, R176, R228, R252, R308, R349, R385, R401-R404, R423 and R466, plus the rules cited by the 18 install.sh findings.
  - The checklist's exclusion list (checklist.md:766-786) names only Vercel inventories, product rules and brand marks. Its "Flag is reserved for the feature-flag product" entry is the Vercel-specific half of R060; the general half ("option", not "flag" or "argument") applies here.

**Round 2, pass 2 notes on this section.**
- **Vercel-specific: still none.** All 31 verdicts say `vercelSpecific: false`. Every cited rule is in the checklist's generalized list and outside its exclusions (checklist.md:766 onward). That includes R439 (`--yes`), R337 (exit codes 0/1/2/130) and R438 (`--json`, no `--format`).
- **Rule citations dropped from individual findings, with the rule kept elsewhere:**
  - R013 (declined discovery offer): `--no-discovery` is valid input, not invalid input replaced.
  - R019 (residue): the cleanup is unbounded in scope, not in time, and there is no loop.
  - R099 (next steps): every printed command already uses long options. R103 replaces it.
  - R043 and R371 (re-exec guard): no target is picked by fuzzy match there, and bin/agent-secrets has no upgrade command (the verifier's grep).
  - R437 (standard options): nothing is advertised without behaviour. It holds only through R455's on/off row, because `--no-discovery` had no `--discovery`.
- **A weak fit, kept:** R296 (errors). The installer fetches static files with no API, so one local `_fetch_die` meets it (B12.1).
- **Sub-claims refuted by verdicts:**
  - "Having no TTY" as a whole is too broad: `_attach_tty` rebinds when a terminal exists (:125-132).
  - "Undocumented env var": docs/FAQ.md:71 documents `AGENT_SECRETS_INSTALL_URL`.
  - "Help names no env vars" holds only for install.sh; lib/help.sh has rows for the CLI.
  - `--help`'s offline failure at :31 is narrower than stated: a fully offline `curl … | sh` fails at the first curl.
  - `| head -5` does not die mid-mutation; about 16 lines or more are needed (estimated).
  - Launchd's "records the job regardless" is correct behaviour for rollback.
  - The "Scan for help first" objection under R063 stands only as exception E9, and the mis-citation of R086 as covering `--bogus --help` is corrected: R083 is the rule.
- **The critic's note on R157 was wrong for install.sh.** "grep finds no … 'reversible' promises in CLI output strings" misses install.sh:149 and :352, cmd/setup.sh:385 and lib/wire.sh:69 (measured with `grep -n -i reversible`). B11.5, B6.16 and B8.17 fix them. D22 covers the docs.
- **Its note on R156 is too strong too.** Discovery is an inferred target written off-TTY, so "satisfied" is corrected in E1.

---

## 6. Implementation sizing

All figures are **estimates**: I counted the lines each listed change touches, plus about one bats block per behaviour. Nothing was measured.

Updated in round 2. The "Est. LOC" column gives the round-2 estimate, with round 1's figure in parentheses. It uses the same method: changed lines per row, plus about one bats block per behaviour. **Updated again in pass 2:** where a figure changed, it reads "new (pass 1 old)". All are still estimates by the same method.

| Wave | Unit | Files owned (disjoint within the wave) | Est. LOC R2 (R1) | Lands |
|---|---|---|---|---|
| A | A1 shared helpers | lib/common.sh, tests/common.bats (new), tests/store.bats:85 | ~380 (pass 1 ~370; R1 ~300, which included lib/ui.sh) | first |
| A | A2 ui, test helpers, mocks (new) | lib/ui.sh, tests/ui.bats (new), tests/mode_matrix.bash (new), tests/test_helper.bash, tests/mocks/curl, tests/mocks/launchctl | ~195 (pass 1 ~180) | after A1 |
| B | B1 store and child contract | lib/store.sh, lib/egress.sh, lib/egress-proxy.pl, lib/keychain.sh, cmd/run.sh, tests/egress.bats, tests/foundation.bats | ~235 (~220) | first in B |
| B | B2 add/list/pubkey | cmd/add.sh, cmd/list.sh, cmd/pubkey.sh, tests/store.bats, tests/pubkey.bats | ~180 (~155) | after B1 |
| B | B3 share/receive | cmd/share.sh, cmd/receive.sh, tests/share.bats, tests/receive.bats | ~240 (~165) | after B1 |
| B | B4 backup/deps | cmd/backup.sh, lib/deps.sh, tests/backup.bats, tests/deps.bats, tests/mocks/gh | ~205 (pass 1 ~190) | after A2 |
| B | B5 uninstall/rollback | lib/manifest.sh, cmd/uninstall.sh, tests/uninstall.bats, tests/mocks/launchctl | ~260 (pass 1 ~220) | after A2 |
| B | B6 setup/wire/restore | cmd/setup.sh, lib/wire.sh, lib/restore.sh, tests/flows.bats, tests/wizard_interactive.bats | ~240 (pass 1 ~190) | after B1 |
| B | B7 doctor/smoke/dispatcher | cmd/doctor.sh, cmd/smoke.sh, bin/agent-secrets, lib/help_search.sh (new), tests/doctor.bats, tests/dispatcher.bats, tests/mocks/osascript | ~300 (pass 1 ~295) | after B1 |
| B | B9 install.sh parse and help (new; pass 1's single B9 is now split) | install.sh (serial), tests/install.bats, tests/install_helper.bash (new) | ~340 (pass 1 ~450 for all of B9) | after A2 |
| B | B11 install.sh mode, consent, plan (pass 2) | install.sh (serial), tests/install_plan.bats (new) | ~440 (new) | after B9 and B6 |
| B | B12 install.sh download, outcomes, signals (pass 2) | install.sh (serial), tests/install_failure.bats (new) | ~430 (new) | after B11 |
| B | B13 install.sh writes and concurrency (pass 2) | install.sh (serial), tests/install_writes.bats (new) | ~330 (new) | after B12 and B5 |
| B | B10 install.sh PTY suite (new) | tests/install_tty.bats (new), plus one wrap line each in tests/one_command.bats:45 and tests/audit_regressions.bats:106 | ~300 (pass 1 ~170) | after B13 |
| B | B8 help and docs | lib/help.sh, tests/help.bats, AGENTS.md, llms.txt, README.md, SECURITY.md, docs/FAQ.md, tests/common.bats (skip line) | ~350 (pass 1 ~325) | last in B |
| C | C4 core (D4, D6, D7 doctor part) | lib/common.sh, lib/store.sh, lib/egress.sh, cmd/run.sh, cmd/add.sh, cmd/doctor.sh, bin/agent-secrets, tests/reserved_env.bats (new), tests/egress.bats, tests/onboarding.bats, tests/custody.bats, tests/wizard_interactive.bats, SECURITY.md | ~255 (~235) | first in C |
| C | C1 uninstall consent (D1) | cmd/uninstall.sh, tests/uninstall.bats, tests/audit_regressions.bats | ~135 (~110) | after C4 |
| C | C2 consent flags (D2, D3, D4, D6) | cmd/share.sh, cmd/receive.sh, cmd/backup.sh, tests/share.bats, tests/receive.bats, tests/backup.bats | ~125 (~105) | after C4 |
| C | C3 setup (D5, F28) | cmd/setup.sh, tests/headless.bats, tests/one_command.bats | ~85 (~110; its install.sh rows moved to C7) | after C4 |
| C | C5 list shape (D7) | cmd/list.sh, tests/store.bats | ~60 (~30) | after C4 |
| C | C7 install.sh contract (new; D5, D6, D9-D15, D17-D23, D25, D26) | install.sh, tests/install.bats, tests/install_tty.bats, tests/install_plan.bats, tests/install_failure.bats, tests/install_writes.bats, scripts/release.sh (D6 only); tests/audit_regressions.bats:106 only under D10(c), after C1 commits | ~425 worst case (pass 1 ~250) | after C1 |
| C | C8 install.sh `--json` (pass 2; D24) | install.sh (after C7), tests/install_json.bats (new); one assertion in tests/install_tty.bats (C8.1), after C7 commits | ~180 (new) | after C7 |
| C | C6 help and docs (D8, D16, D22) | lib/help.sh, tests/help.bats, README.md, AGENTS.md, llms.txt, docs/FAQ.md, docs/plans/*, docs/research/colleague-sharing-design.md, CHANGELOG.md or the release notes | ~220 (pass 1 ~205) | last |

**Totals (estimated):** Wave A ~575, Wave B ~3,850, Wave C ~1,485 in the worst case, about **5,910 LOC** in all. Pass 1 estimated ~550, ~2,495 and ~1,115, about 4,160 in all. Round 1 estimated ~300, ~1,340 and ~720, about 2,360 in all.
- Every unit is under 500 LOC.
  - The largest are B11 (~440), B12 (~430), C7 (~425 worst case), A1 (~380) and B8 (~350).
  - B11 and B12 have the least headroom. If B11 runs over, split B11.3 into its own serial unit with its own test file. If B12 runs over, do the same with B12.5. Neither change needs another file owner.
- Files are disjoint within each wave, with two sequenced exceptions:
  - **install.sh cannot be split** (it runs before lib/ is unpacked), so disjointness there holds by serial order instead: B9 → B11 → B12 → B13 in Wave B, and C7 → C8 in Wave C. Only one unit holds it at a time, each owns its own test file, and none of them runs in parallel with another. This is a deliberate deviation from strictly disjoint files.
  - Under D10(c), C7 edits tests/audit_regressions.bats:106 only after C1, the file's owner, has committed. C8 edits one assertion in tests/install_tty.bats only after C7 has committed.
- Across waves a file passes to the next wave's owner only after the earlier wave has merged. Files that change hands:
  - lib/ui.sh: A2, then later waves.
  - tests/mocks/launchctl: A2, then B5.
  - tests/mocks/curl: A2.
  - install.sh: B9, then C7.
  - tests/install.bats: B9, then C7.
  - tests/install_tty.bats: B10, then C7.
  - tests/install_plan.bats: B11, then C7.
  - tests/install_failure.bats: B12, then C7.
  - tests/install_writes.bats: B13, then C7.
  - tests/one_command.bats: B10 (one line at :45), then C3.
  - tests/audit_regressions.bats: B10 (one line at :106), then C1.
  - SECURITY.md: B8, then C4.
  - docs/FAQ.md: B8, then C6.

---

## 7. Round 2 changes

**Inputs:**
- 18 verified findings for install.sh (unit `agent-secrets-install`), which round 1 did not audit as a CLI.
- The entries in `/tmp/cli-bp/critic2.json` that concern this repo.

**Method:** static reading only, at `main` @ `5266599`. Nothing in the repo was run, edited or committed. Every critic claim and every cited site was checked against the code. Where a check corrected a claim, the correction is in the row.

**Edited in place** (each marked "Round 2 fix"):
- §1 "CLIs covered" (install.sh).
- A.3 `agsec_scan_json`.
- B2.1, B2.4, the B2 test list.
- B7.2.
- B8.2 and B8.6 (the `-V` rows).
- The §6 table and totals.

**Appended** (all other sections are unchanged):
- The Phase 0 addendum.
- The §1 gate additions.
- "Round 2 additions to Wave A": A.11-A.16 and unit A2.
- The Wave B pointer line.
- "Round 2 additions to Wave B": B1.11-B8.13 and units B9 and B10.
- The C3 note.
- "Round 2 additions to Wave C": C7, D9-D16 with the D5/D6/D7 extensions, and exceptions E1-E7.
- The §5 notes.
- This section.

**Where the 18 install.sh findings went:**

| # | Finding (short title) | Verdict contract | Plan rows |
|---|---|---|---|
| 1 | Typing 'n' at the consent prompt still installs | compatible as refined | B9.5, B10; D9 |
| 2 | Runs without a TTY install with no --yes | breaking (strict option) | E1, D10, C7.4, B9.13 |
| 3 | Help on stderr, wrong layout, over 80 columns, network re-fetch | compatible | B9.1 |
| 4 | Usage errors exit 1, not 2 | compatible | B9.2 |
| 5 | Option-parsing gaps | compatible | B9.3; D5 sub-question |
| 6 | --no-discovery ignored by the interactive prompt; plan omits --import-env | compatible | B9.6, B10 |
| 7 | Mode resolved inline from `[ -t 0 ]` | compatible part / breaking option B | B9.7, E2, D11 |
| 8 | --dry-run skips preflight and the digest gate | breaking for the digest part only | B9.8, D12 |
| 9 | Downloads have no timeout or retry | compatible | B9.9, B4.9; D13 |
| 10 | Real outcomes hidden | compatible | B9.10; D14 |
| 11 | Missing standard global options | compatible | B9.4; D10 |
| 12 | Plan preview leaves out effects | compatible | B9.11 |
| 13 | Backup loss, in-place plist, unescaped paths | compatible | B9.12 |
| 14 | No INT/TERM/HUP handling; temp dir leaks | compatible | B9.10 |
| 15 | Error copy | compatible (prefix via D6) | C7.1 |
| 16 | Presentation: glyphs, banner, em dashes, wrapping | compatible | C7.2 |
| 17 | Env vars undocumented; sentinel prefix | compatible (rename via D15) | B9.1; D15, E4 |
| 18 | Tests too loose; key paths untested | compatible | B9 tests, B10 |

**Critic entries concerning this repo:**
- **missedFindings:**
  - **R228.** Confirmed at share.sh:133 ("Proceed? [y/N]") and at ui.sh:38, where the "Continue?" default is dead because every caller passes a prompt. Fixed in B3.12 and A.10.
  - **ui_menu fallback (R013, R122, R134).** Confirmed at ui.sh:60-62. "Silently stores" is overstated: the next prompt names ANTHROPIC_API_KEY. Fixed in A.10 and B6.9.
  - **R135.** Confirmed. B6.10 adds the replay; E6 covers the summary half.
  - **R349.** Confirmed at store.sh:71. Fixed in B1.11.
  - **R060.** All 10 sites confirmed, plus install.sh:103 and round 1's own B2.1 text. Fixed in A.12 and the per-unit rows.
- **uncoveredClis:** install.sh is now covered by B9, B10 and C7.
- **planConflicts:**
  - **New `--format` spellings.** Round 1 added the space forms `--format json` and `--format text` (A.3, B2.4, the B2 test, B7.2). They do not exist today (list.sh:13-16, doctor.sh:20-21), and R438 bans new `--format` spellings. Corrected in place.
  - **Gate list.** Round 1 dropped two CI steps and the README's diagram check, which needs `npm ci` because node_modules is gitignored. Both are now in the §1 gate additions.
  - **Rules dropped as Vercel-specific.** This plan already treated the rules as general practice, and round 2 keeps that.
  - **Other repos' items.** The `--confirm`, `<CENTS>`, Standing-converge and cc-bats items concern other repos. A grep of this plan finds no `--confirm`, `<CENTS>` or `<N>`.
- **unmentionedRules:**
  - R100: A.13, B8.9, B9.3f.
  - R107 and R108: B7.12, B7.13, B8.11.
  - R176: B2.10, B3.14, B4.11.
  - R245-R264:
    - A.11 adds `next[].argv`, the warnings channel and the canceled document.
    - `retryable` is never emitted, because no JSON-mode failure here is safely retryable.
    - R263 is N/A: no destructive command has `--json`.
  - R252: D7.
  - R308 and R385: A.14.
  - R401, R403 and R404: A.15, B8.12, the per-unit matrix rows, B10.
  - R423: D16, C6.
  - R088, R092, R096 and R101: B8.10. R104 was already covered by B3.7.
  - R112 and R117: E2, E3.
  - Already satisfied, no change:
    - R119: payload stdin never answers a prompt (add.sh:29; receive reads its confirm from the tty source).
    - R018, R133, R356-R358, R340 and R342.
- **Found while verifying, not in the critic:**
  - **CI=true on GitHub runners.** GitHub-hosted runners set `CI=true`, and A.4 and B6.2 make CI imply non-interactive. The PTY wizard drives (one_command.bats:96, wizard_interactive.bats:119 and :152) would then fail in CI while local gates stay green. Fixed by A.16.
  - **Unowned curl mock.** Round-1 B3 relies on a curl call log that no unit owned. A2 now owns it.
  - **C3's `--discovery` passthrough.** On a TTY or an auto-headless run it would run setup's standalone screen (setup.sh:557) and skip the key mint. Fixed in C7.3.
  - **R466.** `-V` is outside the short-option table: B7.11, B8.8.
  - **R086.** The dispatcher prints `agent-secrets <version>` rather than the bare version: E7.

**Counts:**
- New units: A2, B9, B10, C7.
- New decisions: D9-D16, with D5, D6 and D7 extended.
- New exception records: E1-E7.
- Sizing: about 2,360 → about 4,160 LOC (estimated), every unit under 500.

---

## 8. Round 2 changes: pass 2 (31 verified install.sh findings)

**Inputs:**
- 31 verified findings on unit `agent-secrets-install`, each with a skeptic verdict, caller census and refined fix. The earlier 18 install.sh findings in §7 covered the same file at a coarser grain, so most of these extend or correct rows that already existed.
- `/tmp/cli-bp/critic2.json`, re-read against this plan and the code.

**Method:**
- Static reading only, at `main` @ `5266599`: Read, grep and sed.
- Nothing in the repo was run, edited or committed. No CLI under audit was executed.
- Figures attributed to "the verifier" come from the verdicts and were not re-run here.

**Edited in place** (each marked "Pass 2 fix"), because the old text would have caused a bug:

| Row | What was wrong | Evidence |
|---|---|---|
| B9.9 | `--retry` on :30's `$(curl …)` capture can feed a corrupted body to `exec bash -c` | The verifier measured rc=0 with the partial body captured |
| B9.2, A.12 | The usage error echoed the whole token, so `--import-envv=sk-ant-…` leaks a value | SECURITY.md:186, tests/headless.bats:86 |
| B9.1 | The `/bin/sh install.sh --help` test is vacuous, because a real `$0` never reaches the fetch | install.sh:24 |
| B9.3(b) | Validating in the option arm breaks last-wins, and an empty list passed | setup.sh:518 is dead |
| B9.3(c,d) | Missing `--no-*` and `--discovery` forms | R068, R455 |
| B9.4 | `--no-color` as a no-op left the chained setup colored | lib/common.sh:76 |
| B9.5 | The re-ask loop had no bound | R019 |
| B9.7 | The `_attach_tty` diff test would fail on arrival, and the lint would trip on a comment | :120, :127-128 |
| B9.8 | The fallback command was the form README.md:64-75 warns about; "apply exactly this plan" overclaimed | README.md:64-75 |
| B9.10 | "Nothing was changed" is false after :235; exit was always 130 after :286 | R294, R337 |
| B9.11 | The `-f && !-L` test misses foreign symlinks; the discovery targets were unnamed | R350, R001 |
| B9.12 | `${x//&/&amp;}` is unsafe under newer bash; refusing exotic paths broke a supported case | tests/install.bats:172 |
| B4.7, B4.9 | A 300 s cap is too short for a 50 MB binary on a slow link; total waiting had no limit | The verifier's `wc -c` |
| D5, D10, D13, E1 | Sub-option, recommendation and reason corrected (see the rows) | R068, R439, R156 |
| B9.6, B9.13, B8.13, C7.3 | Pointers and wording aligned with the rows above | B11.4, C7.2, B9.3 |
| §6 | Table, totals and handoff list | This section |

**Appended:**
- The Phase 0 pass 2 addendum, the §1 pass 2 gates and "Round 2, pass 2 additions to Wave A".
- "Round 2, pass 2: install.sh serial track, and rows for B4-B8": new units B11, B12 and B13, new rows B9.14-B9.16, B10.1-B10.5, B4.13, B5.12, B6.13-B6.16, B7.17 and B8.14-B8.18.
- C7.1 and C7.2 pass 2 additions, C7.5, C7.6, new unit C8.
- D17-D26, E8-E14, the §5 notes, this section.

**Where the 31 findings went:**

| # | Finding (short title) | Severity | Verdict contract | Earlier rows it overlapped | Pass 2 rows |
|---|---|---|---|---|---|
| 1 | No TTY counts as consent; no --yes | high | compatible as refined; strict option breaking | E1, D10, C7.4, B9.13 | D10 update, E1 fix, B11.1, B8.16, D18 |
| 2 | Consent proceeds on any reply | high | compatible | B9.5, B10, D9 | B9.5 fix, B10.1, B8.14 |
| 3 | Declined offer overridden; plan misstates mode | high | compatible | B9.6 | B9.6 fix, B11.4, B6.16, B10.2, D19 |
| 4 | Mode ignores CI, stderr, agent on a TTY | high | compatible | B9.7, E2, D11 | B9.7 fix, B11.6, B6.13, B10.3, D17, D18 |
| 5 | Usage errors exit 1 | medium | compatible | B9.2 | B9.2 fix, A.12 fix, E8 |
| 6 | Help on stderr, wrong structure | medium | compatible | B9.1 | B9.1 fix, B9.16, E9 |
| 7 | --help can fetch | medium | compatible | B9.1 | B9.1 test fix |
| 8 | Standard options and forms missing | medium | compatible | B9.3, B9.4, D5, D10 | B9.3 fix, B9.4 fix, D5 update |
| 9 | Input validated after the install | medium | compatible | B9.3 | B9.3 fix, B12.2, B11.2, B6.14, E8 |
| 10 | --dry-run does no validation | medium | compatible | B9.8, D12 | B9.8 fix, B11.2 |
| 11 | Plan omits targets, replaced install, mirror trust | medium | compatible | B9.11 | B9.11 fix, B11.3 |
| 12 | Copy promises reversibility | low | compatible | none | B11.5, B6.16, B8.17, D22 |
| 13 | Symlinks replace user files with no backup | medium | compatible | B9.11, B9.12 | B13.1, B5.12, B6.15, D21 |
| 14 | Failure residue; cleanup removes others' dirs | medium | compatible | B9.10 | B12.3 |
| 15 | "Installed." despite silent failures | medium | compatible | B9.10 | B12.4, A2 launchctl knob |
| 16 | No signal or cancel handling | medium | compatible | B9.10 | B9.10 fix, B12.5, D19, E12, E13 |
| 17 | Downloads have no timeouts or retries | high | compatible | B9.9, B4.7, B4.9 | B9.9 fix, B12.1, B4.7 and B4.9 fixes, B4.13, A2 curl knob, E14 |
| 18 | Errors lack recovery and layout | medium | compatible | C7.1, B9.10 | B12.1, B12.4, C7.1 additions |
| 19 | Next steps are prose or stale | low | compatible | B9.8, C7.1 | B9.14, B9.2 fix, B9.8 fix, B7.17 |
| 20 | stdout has setup prose, no identifier | low | **breaking** | none | C7.5, C7.6 |
| 21 | No --json result | medium | compatible | D10 (optional note) | C8, D24, E10 |
| 22 | Re-exec runs a local `sh`; no verification | medium | compatible with D23(A) | D13 | B9.15, D13(c), D23, B8.18 |
| 23 | Env vars undocumented; sentinel prefix | low | compatible | B9.1, D15, E4 | B9.16, B8.17 |
| 24 | Credentials echoed from a mirror URL | low | compatible | none | B12.1, B9.14, B8.18, D25 |
| 25 | Re-run overlays with no no-op report | medium | compatible | B9.11, B9.12 | B11.3, B13.2, B9.12 fix, D20 |
| 26 | Concurrent installs; fixed /tmp path | medium | compatible | B5.4 | B13.3, B8.15 |
| 27 | Paths unescaped in plist and rc | low | compatible | B9.12 | B9.12 fix |
| 28 | Glyphs have no plain fallback | low | compatible | C7.2 | C7.2 additions, D26 |
| 29 | Copy voice and nouns | low | compatible | C7.2, D16 | C7.2 additions |
| 30 | Mode detection duplicated | low | compatible | B9.7 | B9.7 fix, B11.6, E11, D18 |
| 31 | Tests miss prompts, help, TTY modes | medium | compatible | B9 tests, B10 | B10.1-B10.5, A2 `mm_no_ctty` |

**Where the verdicts disagreed with each other.** Each verdict was written alone, so these were resolved here:

| Question | Positions | Resolution |
|---|---|---|
| `exec` setup at :385? | Finding 16: yes (R416). Findings 3, 20, 26 and B9.10: control must return | Child, by default. Recorded as D19 and E12 |
| Where the receipt prints | Finding 15: before setup; the done screen stays last. B9.10: after setup | Both. The line before setup claims only the tool install (B12.4). B9.10's line confirms the whole run, below the done screen, and is absent on failure |
| Help stream | Finding 6: stdout. Finding 7: keep stderr | stdout (R083 is a MUST; no caller reads it) |
| Finding help | Finding 6: scan anywhere. Finding 7: walker. Finding 8: no scan | Scan, because R083 says help skips other validation. E9 |
| Usage error code | Finding 5: exit 2. Findings 6 and 8: leave at 1 | Exit 2 (R337; AGENTS.md:161) |
| Who skips the keypress | Findings 2, 4: agent or CI skips. Findings 3, 30: keep raw `[ -t 0 ]` | B9.7's default stands. Both options in D18 |
| Rename into place | Finding 14: no. Finding 25: yes, with `vendor` carried over | Both: staging plus the trap, because 14's objections are the ones 25 answers (B13.2) |
| Backup naming | Finding 13: versioned names and a record change. B9.12: move the old one aside | B9.12, because it needs no record change (B5.12) |
| rc line with exotic paths | B9.12: refuse. Finding 27: escape | Escape, because tests/install.bats:172 treats exotic homes as supported |
| Other text at the consent prompt | Finding 2: cancel. B9.5: ask again | Ask again, bounded (R019) |
| Preflight position | B9.8: above the dry-run branch. Finding 10: same place plus dry run | Finding 10, because :4 makes consent the first screen |
| `--version` | Finding 8: flag in the loop. B9.4: pre-scan | Pre-scan. Finding 8 itself notes that the loop leaves the POSIX path needing the network (R379) |
| The fetch helper | Findings 17, 18 and 24 each specified `_fetch` | One `_fetch` and one `_fetch_die` (B12.1) |

**Critic entries concerning this repo, re-verified against the code** (commands named):
- **missedFindings.** All five still hold, and all were integrated in §7. Nothing here changes them.
  - R228: `sed -n 133p cmd/share.sh` shows `Proceed? [y/N]`, and lib/ui.sh:38 has `Continue?`.
  - R013, R122 and R134: lib/ui.sh:60-62.
  - R135: `grep -rn 'without prompts' cmd lib` finds 0.
  - R349: lib/store.sh:71.
  - R060: `grep -rn -i 'unknown flag\|unknown argument' cmd lib install.sh` lists 11 sites (setup.sh:539, share.sh:25, receive.sh:27, doctor.sh:27, uninstall.sh:20, backup.sh:19, help.sh:52, :74, :101, :112, install.sh:103).
- **uncoveredClis.** install.sh is now covered by B9-B13, C7 and C8.
- **planConflicts.**
  - **Dropped install step:** §1 has `[ -d node_modules ] || npm ci` before `npm run diagrams:check`. B8.15 edits README.md:58 and :78, outside the fence blocks at :191, :236 and :281, so it does not trigger the check. D22(B) would, and says so.
  - **New `--format` or `--confirm`:** none. After these edits, `grep -n -- '--confirm\b\|<CENTS>\|<COUNT>\|<String>\|<Boolean>\|<MS>'` finds only §7's own sentence reporting the absence. `--format` appears only as the existing deprecated `=json`/`=text` aliases and the "not added" notes. C8 adds `--json`, and C8.5 keeps `--format` off install.sh (R438).
  - **`--yes`:** kept as the consent spelling (R439). D10 lists both options, and `--yes` never implies `--json` or data (R010).
  - **Exit codes:** every new row uses 0, 1, 2, 130 or 128+n (R337).
  - **Rules dropped as Vercel-specific:** none (§5).
  - **The other repos' entries** (personal, agent-context-sync, doc_classifier, claude-session-search) do not concern this repo.
- **unmentionedRules.** The §7 list stands, with two corrections from this pass:
  - R157's "satisfied" was wrong for install.sh (§5).
  - R156's "satisfied" is too strong for discovery (E1).
  - R119 applies narrowly: nothing reads stdin as an answer at :181-186 (D17).
  - Newly cited and now covered: R316 (B12.1, B4.13), R340 (B11.4), R341 (B12.5), R416 (B12.5, D19), R302 (B11.2, B12.2), R140 (B11.3), R154 (B11.4), R240 (B11.4), R326 (B11.3, B13.2).
- **R100, every new printed command gets a parser test:**
  - install.sh's help examples, `_self_cmd`, the dry-run next step and C7.1's recovery commands: B10.4 and B9.3's tests.
  - The dispatcher commands install.sh prints (`setup --discovery`, `setup`, `uninstall --dry-run`, `uninstall`, `doctor`): B10.4.
  - D10(b)'s `--yes --headless` and C8's `--json`: added to the list if approved.
  - The `launchctl bootstrap` and `mv` lines are not this CLI's parser, so they are not covered.

**Limits carried from the verdicts:**
- Callers outside this repo were not searched for most findings (a cross-repo grep was denied in one verdict, and most stayed in the repo).
- `bin/agent-secrets` could not be grepped by several verifiers because of a deny rule (§1's harness trap). No conclusion here depends on it, but its references to install.sh are unconfirmed.
- Nothing about launchd or the real network was exercised. The bats suite was not run.
- B11 and B12 are close to the 500 LOC limit by estimate (§6 gives the split).

**Counts:**
- Findings integrated: 31 of 31. By verdict contract: 30 compatible, 1 breaking (measured by reading the input JSON). Options marked breaking inside "compatible" findings are in D10(c), D11(B), D21(B), D23(B) and D25(b).
- New units: B11, B12, B13, C8. Existing rows corrected: 22 (counted by hand from `grep -n 'Pass 2'`): B9.1-B9.13, A.12, B4.7, B4.9, B8.13, C7.3, D5, D10, D13, E1.
- New decisions: D17-D26. New exception records: E8-E14.
- Sizing: about 4,160 → about 5,910 LOC (estimated), every unit under 500.

## 9. Wave B landing notes

Wave B landed on main by fast-forward push, one unit at a time, on 2026-11-08 and 2026-11-09. Every unit's gate is `bash /tmp/cli-conv-gate-run.sh` (every §1 gate: shellcheck, telemetry, bash 3.2 parse, `perl -c`, assets and the secret scan, bats with the TAP plan asserted, plus `diagrams:check` when README or assets change) on the exact tree that was pushed, or on a stack that contained it. The one bats skip in every run is the R408 lint (`tests/common.bats`, "TTY/CI checks only in lib/common.sh"); see B8 below. Contract packets in force: ad226c7513ea (keep today's exit codes, JSON shapes, confirmation flags and preview-by-default) and 8825ca436960 (D1-D26 keep today's behavior until answered).

| Unit | Landed sha | Gate |
|---|---|---|
| B1 | c8b4eb9 | GATES rc=0, bats 1..323, not ok 0, skip 1 |
| B4 | 87171aa | GATES rc=0 on c8b4eb9 + B4, bats 1..337, not ok 0, skip 1 |
| B5 | 1c770c0 | GATES rc=0 on 87171aa + B5, bats 1..348, not ok 0, skip 1 |
| B9 | 96054e2 | GATES rc=0 on 1c770c0 + B9, bats 1..367, not ok 0, skip 1 |
| B2 | d79ecb1 | GATES rc=0 on 96054e2 + B2, bats 1..383, not ok 0, skip 1 |
| (test) | 0d03e92 | load-tolerant egress SIGTERM and concurrent store_add tests; covered by B3's gate |
| B3 | 58d065c | GATES rc=0 on d79ecb1 + test + B3, bats 1..397, not ok 0, skip 1 |
| B7 | 4ed7ec5 | GATES rc=0 on 58d065c + B7, bats 1..419, not ok 0, skip 1 |
| B6 | 0e3bb8d | GATES rc=0 on 4ed7ec5 + B6, bats 1..434, not ok 0, skip 1 |
| B11 | 25fdb14 | GATES rc=0 on 0e3bb8d + B11, bats 1..454, not ok 0, skip 1 |
| B12 | 28875a4 | GATES rc=0 on 25fdb14 + B12, bats 1..468, not ok 0, skip 1 |
| (test) | 2db4fce | wizard Ctrl-C test fix: repeat Ctrl-C until restore_flow returns; gated with B13 |
| B13 | 4c441ca | GATES rc=0 on 28875a4 + test + B13 + B9.5 fix (the tree of 7a997cf), bats 1..478, not ok 0, skip 1 |
| (B9.5 fix) | 7a997cf | Ctrl-C at the consent prompt is a decline with its receipt; gated with B13 |
| B10 | 8a8334d | GATES rc=0 on 7a997cf + B10, bats 1..498, not ok 0, skip 1 |
| B8 | f3fb1d4 | GATES rc=0 on 8a8334d + B8, bats 1..507, not ok 0, skip 1, diagrams:check rc=0 |

### Conflicts and deviations, by unit

Each one keeps the caller working and does not widen the change.

**B1 (store)**
- B1.1: `store_has` matches names literally (`grep -qxF`); `store_init` dies through `agsec_die_undecryptable` when the canary returns 2 (the plan's version exited silently).
- B1.5: bash 3.2 starts background jobs with SIGINT and SIGQUIT ignored, and `trap - INT` cannot undo that. `store_exec_managed` launches the child through `/usr/bin/perl -e '$SIG{INT}=$SIG{QUIT}="DEFAULT"; exec …'` (same pid).
- B1.10 vs B1.12: an unknown `-x` is `agsec_unknown_option`; a bare word before `--` keeps the old usage line, which `tests/flows.bats:65` and `tests/store.bats:74` pin.
- Two B1 tests were made load-tolerant in their own commit (0d03e92): the egress SIGTERM test's child now sleeps 600 s, longer than the 120 s wait for it to appear; the concurrent `store_add` test asserts the contract under a 10 s store-lock timeout (a writer that reports success finds its name; one that fails names the lock).

**B2 (add, list)**
- B2.4: help does not list `list --format=json`; the alias still works (B8 dropped it from help).

**B4 (backup)**
- B4.10: the `backup.sh` catch-all is split: `-*` is `agsec_unknown_option`, a bare positional is `agsec_unexpected_argument` (both exit 2).

**B5 (uninstall)**
- B5.11: the row says "prompt only in a tty", but B5.9's `agsec_noninteractive` treats stdout-redirected with stdin and stderr on a tty as interactive. Kept `agsec_noninteractive`; the test asserts the prompt there. JSON on a tty is asserted as exit 2.
- B5.12: `manifest_backup_user_target` takes an optional third argument OURS (default `$AGENT_SECRETS_ROOT/bin/<name>`) so install.sh can pass `$INSTALL_DIR/bin/<name>`.

**B6 (setup)**
- B6 made setup's `_import_env_valid` require at least one name (matching install). B9's loop in `tests/install.bats` that pinned "setup accepts ','" now expects status 1; `tests/install.bats` joined B6's paths.
- B6.16 vs `tests/one_command.bats:150-160` (wizard lines at most 72 columns): the row's done-screen line "(Claude Code reads the agent rules in ~/.claude/CLAUDE.md, if you added them.)" is 78 columns. Kept the words over two `ui_say` lines. The row-verbatim "Writing the agent-secrets rules (advisory, recorded in the manifest) into:" (74 columns) stays: it shows only when the user accepts discovery, a path no width test covers.
- The flows.bats mode-matrix probe redirected only the `printf`, not setup's stderr; it now runs `bash -c 'exec 2>"$1"; …'`.

**B7 (doctor, dispatcher)**
- Fixed the stale comment at `lib/common.sh:44` (the dispatcher's `-V` sed was removed by B7.8).

**B9 (install.sh: parsing, help, re-exec)**
- B9.3(a): the row's `Unexpected argument '$1'` would echo the token; kept the names-only "Unexpected argument for install.sh." per `agsec_unexpected_argument` and B9.2's no-echo rule.
- B9.14's dry-run test and B9.3's parse-only check of B9.8's printed command moved to B11 (rows B9.8 and C7.1 were not yet present). `_self_cmd` and the POSIX `_agsec_show_url` seam are in place.
- B9.15: the `docs/FAQ.md:71` edit was left to its owner, B8.18; the install.sh comment parts of D23(A) are done.
- B9.5's PTY tests moved to B10.

**B11 (install.sh: consent, setup parity, plan, offer)**
- B9.7/B11.6: `INTERACTIVE` and `_attach_tty` treat `AGENT_SECRETS_NONINTERACTIVE=1` as nobody present (parity with `setup_resolve_mode`, which B11.4's test pins). On a tty with that variable the consent keypress is skipped, as in CI.
- B9.11/B13.1: `_target_is_foreign` is defined inline (the B13.1 spec); B13 rewords the foreign-symlink plan row to say the link is backed up.
- B9.8/B11.3: a mirror with no baked digest prints "Checked only against the mirror's own .sha256: transport integrity, not tamper evidence." instead of "SHA-256 verified." No test pinned the old line.
- B11.4 follows D19(a): setup stays a child; the discovery offer runs after it, only on the wizard path, only without `--no-discovery`.

**B12 (install.sh: downloads, exit handler, receipts, signals)**
- B12.1/B9.9, POSIX part not done: the `sh` re-fetch keeps `$(curl -fsSL URL)` with no `-o` and no curl budget, because B9's `tests/install.bats:382-411` serve install.sh through the curl mock's stdout mode and pin the argv to `-fsSL <url>`; the plan's `-o` form fails both (measured). URL redaction on the error line is done. Finishing it needs those tests moved to `AGSEC_MOCK_DL_DIR` with a URL match.
- B12.5: the plan's literal `_say(){ ( printf ... >&2 ) 2>/dev/null || true; }` silences all output on bash 3.2 (the subshell's `2>/dev/null` also catches its `>&2`; measured). Wrote `( printf ... >&2 ) || true`, which keeps the row's intent (the subshell takes SIGPIPE).
- B9.10/B12.5: recovery commands in the recorded window print `<INSTALL_DIR>/bin/agent-secrets uninstall --dry-run`, because the `~/bin` link may not exist yet; setup-phase messages use BIN_DIR as planned.
- The retry notice uses `curl ... 2>&1 | _retry_notice` under pipefail instead of `2> >(...)`: bash 3.2 cannot wait on a process substitution.
- D14(a) (setup's exit code passes through), D19(a) (setup stays a foreground child) and D25(a) (URL redacted on display only) are in force.

**B13 (install.sh: backups, staged swap, lock)**
- The foreign-symlink plan row now reads "replace your existing symlink <path> (backed up to $STATE_DIR/<f>.preinstall.bak; uninstall restores it)"; the replacing note "is replaced in place, with no backup" became "is replaced, with no backup" (the staging swap).
- Install lock: `$STATE_DIR/install.lock`, a 60 s wall-clock wait, a dead pid's lock reclaimed at once, an unreadable pid's after 5 s (the `agsec_lock` rules). New global `_AGSEC_SWAPPED`.
- Landed with two neighbors in the same push: a test fix for B6's "Ctrl-C during the hidden key paste restores terminal echo" (under load bash 3.2 can swallow a SIGINT that arrives while it reaps a subshell, so the drive repeats Ctrl-C every 20 s until `restore_flow` returns), and a B9.5 fix found by B10's PTY suite: Ctrl-C at the consent prompt killed the installer with no receipt, because the INT trap was armed only after consent. The consent loop now traps INT itself and prints "Canceled. Nothing was changed." with exit 130, as for "n".

**B10 (install.sh TTY tests)**
- New `tests/install_tty.bats` (20 tests, skip 0). `load mode_matrix` was added to `tests/one_command.bats` and `tests/audit_regressions.bats`, and the `tests/install.bats:427` shim test is wrapped in `mm_no_ctty` too (beyond the rows' list, needed for a stable controlling-tty state).
- On this Mac's expect 5.45, the one-braced-argument form never matches a `[Y/n]` pattern; the drives use the unbraced multi-pattern form.

**B8 (help and docs)**
- The R408 lint (`tests/common.bats`, "TTY/CI checks only in lib/common.sh") stays skipped: enabling it fails on `cmd/setup.sh`'s `elif [ ! -t 2 ]` (B6.13's branch in `setup_resolve_mode`). The skip reason names that line.
- The stale common.bats `-V` test is retitled "lib/common.sh keeps exactly one unindented AGENT_SECRETS_VERSION fallback, a semver".
- B8.5: `help --json` `flags[]` gains `type`, `value_hint`, `default` and `choices` (fields added only, no shape change).
- B8.12 (PR-body transcripts): not applicable; Wave B landed by push to main, with no PR.
- B8.13 (document the new installer flags) vs B8.15 (advertise nothing an unreleased tag lacks; the docs pin v0.1.3): kept the B8.13 lists with a note that they arrive with the next release and that v0.1.3's install.sh lacks them.
- help folds text with a byte-counting awk, because macOS `fold` under `LC_ALL=C` gives non-ASCII bytes zero width.
- `lib/help.sh` lists uninstall's exit 1 (partial rollback, B5) and backup's exit 2 without `--yes` when not interactive (B4.2) and 130 on decline (B4.3).
