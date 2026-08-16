---
status: complete
---

# Onboarding UX rebuild — `agent-secrets setup`

## Phase 0 — Agent Team Orchestration

**EXECUTION LOCUS: S** — one dispatched handoff session owns the whole rebuild. No justification
needed (S is the default). The work is a single subsystem (`cmd/setup.sh` + its `lib/ui.sh`
helpers) where every finding touches the same control flow, so splitting it across teammates would
serialise on one file and land merge conflicts rather than parallelism.

| Field | Value |
|---|---|
| Locus | **S** — dispatched session, `--cwd ~/Development/agent-secrets`, Fable 5 @ xhigh |
| Roster | 1 session. Read-only `Explore` subagents permitted for codebase sweeps; **no code-writing teammates** |
| Dependency graph | F3 (crash) → unblocks end-to-end testing → F1/F2 (key custody redesign) → F4/F5/F6 (messaging + layout) → F7 (error copy). F3 first because nothing can be verified end-to-end until setup completes |
| Worktree | none — `agent-secrets` has a single writer; repo is clean on `main` |
| Wave order | one wave |
| Lead context budget | this plan is the durable state; the dispatched session recycles on its own if it exhausts context |
| Succession point | after F3 lands and `setup` completes end-to-end — that is the natural seam if a recycle is needed |

**Status:** DONE · created 2026-08-16 · landed 2026-08-16 (F1–F7, six commits — see Status log)
**Trigger:** a real first-run by the author, observed end-to-end in a live session. It did not complete.
**Scope (frozen):** make `setup` reach a complete, correct install on a first run without the
clipboard ever carrying a private key and without aborting at [4/7] — while preserving every
existing security invariant (names-only, agent-session refusals, fail-closed store writes).

---

## Why this exists

The README's promise is *"encrypted at rest · injected just-in-time"* with a one-command install.
The measured first run was **seven screens, two out-of-band password-manager tasks, one silently
destroyed private key, and a crash at [4/7]** that left the install incomplete. The operator's own
words: *"This whole agent-secrets is really confusing… this is far from a 'one command setup'."*

Every finding below is from that single run. None is hypothetical.

---

## F1 — The clipboard is used as a transport for private keys (ROOT DEFECT)

`cmd/setup.sh` [3/7] places the **primary private key** on the clipboard, then — on the same
screen — replaces it with the **recovery key**. The clipboard is global, volatile, single-slot,
and shared with every other process and with the human's own muscle memory.

Observed twice in one run:

1. The operator **screenshotted the terminal** to ask a question. That put an image on the
   clipboard and destroyed the primary key sitting there unsaved.
2. Recovering from (1) with `pbcopy < age.key` **overwrote the recovery key**, which was at that
   moment the unsaved one.

The design assumes an uninterrupted human who pastes immediately and does nothing else. A first-time
user asking questions mid-wizard is not an edge case — it is the expected case.

**Direction (not a mandate — derive the right answer):** a private key should never transit the
clipboard as the *only* copy. Candidates: write it to a `0600` file and tell the user the path (it
already is one — `~/.config/secrets/age.key`); render it as a QR for phone capture; offer
`--print-key` on demand rather than push-once. The invariant to hold: **a key the user has not
demonstrably saved must remain retrievable.**

## F2 — Destructive delete gated on an unverified assertion, and the asymmetry is backwards

`cmd/setup.sh:83-86`:

```sh
_confirm "Saved your RECOVERY key offline?" y || { rec_keep=1; … }
agsec_have pbcopy && printf '' | pbcopy
[ "$rec_keep" -eq 1 ] || rm -f "$rec"
```

A bare `y` — the **default** — deletes the file. Meanwhile the *primary* key, which stays on disk
and in Keychain and is therefore the recoverable one, is gated on a **public-key paste-back
verification**. The verified prompt guards the safe key; the unverified prompt destroys the
irreplaceable one.

Worse, the paste-back check is weak on its own terms: the public key it asks you to type back was
**printed on screen four lines above**, so it proves nothing about whether the private half was
saved.

## F3 — [4/7] aborts, leaving the install incomplete

`cmd/setup.sh` first-secret path:

```sh
ui_read_secret "Value for $name" | store_add "$name"
```

Produced, on a real interactive TTY after choosing `3) custom` and naming `CODA_API_TOKEN`:

```
Value for CODA_API_TOKEN:
ERROR add takes a NON-EMPTY single-line value on STDIN (got end of input).
```

The wizard exited to the shell at [4/7]. Screens 5–7 — wrapper symlinks, `apiKeyHelper`,
`settings.json` wiring — never ran, and `doctor` still reports all four as missing. Note the
contrast with the `UNATTENDED` branch directly above it, which was hardened against exactly this
class of stdin failure (BLOCKER #3) while the interactive branch was not.

**Reproduce:** run `setup` on a fresh store, choose `3`, supply any custom name.

## F4 — The hidden prompt is indistinguishable from a hang

macOS `security(1)` renders `password data for new item:` with no echo and no cursor movement. The
operator's verbatim question was **"where is this hidden prompt"** — the screen offers no affordance
saying *type here; nothing will appear; that is correct*. The later `add` path does print such a
hint; the Keychain path does not.

## F5 — Output assumes a wide terminal

Run in a split pane, status lines wrap mid-token (`prompt-` / `free reads?` split across lines;
`✓ Keychain custody — primary` wrapping into the next screen's header). The wizard is most likely
to be run beside something else, which is the narrow case.

## F6 — The recovery-key mental model is never stated

Nothing on screen explains the two keys' different jobs: **primary** = daily decryption, lives on
disk + Keychain, dies with the Mac; **recovery** = offline second leg, the only thing that survives
a dead disk, and therefore worthless without `agent-secrets backup` having pushed the encrypted
store off-machine. The operator could not tell which key mattered, and neither could the assistant
walking him through it. A user who cannot state the model cannot make the save/skip decision the
wizard demands of them.

## F7 — Agent-session refusals are correct but explain the wrong thing

Running `add` inside a Claude Code session emits a `note:` line about piping from a variable,
followed by a dominant `ERROR … got end of input`. The actual remedy — *open a real terminal; this
session has no TTY* — is in the quiet line, not the loud one. The refusal itself is right and must
stay; only its messaging is at fault. Same for `setup`'s refusal, which is the one that reads well.

---

## Constraints — do not trade these away

1. **Names-only holds.** No command may print, log, or persist a secret value outside the encrypted store.
2. **Agent-session refusals stay.** `setup`/`share` must keep refusing inside an agent session; F7 is a
   messaging fix, not a gating change.
3. **Fail-closed store writes stay.** Never store an empty or placeholder value in an interactive run.
4. **Uninstall stays manifest-complete.** Any new file or wiring gets a manifest record.
5. **No new runtime dependency.** sops + age + gum only; no vendor, no network at setup time.

## Definition of done

- `setup` runs to [7/7] on a fresh store, including the custom-secret path, with no abort.
- No private key is placed on the clipboard as its only copy; a key the user has not saved stays retrievable.
- No destructive delete fires on an unverified assertion.
- The two-key model is stated on screen in one sentence before the user is asked to act on it.
- Output is legible at 80 columns.
- `doctor` reports zero failing rows after a clean run.
- `bats tests/` passes with 0 failures; new regression tests cover F2 and F3.

## Status log

- **2026-08-16** — Findings F1–F7 captured from a live first-run (author, macOS, iTerm2 split pane).
  Run outcome: store created, Keychain custody primary, **aborted at [4/7]**, wrappers/apiKeyHelper
  unwired, recovery key destroyed unsaved. Store itself is healthy — decrypt self-test passes.
- **2026-08-16** — **Rebuild landed, F1–F7 all closed.** Six commits, one dispatched session:
  `7d251bc` (F3: [4/7] abort-proof — empty-entry retry/skip ladder, name validation, guarded
  screen, execute-only source guard for tests) · `8bc9148` (F1+F2+F6: recovery-key custody —
  verified paste-back gates the delete, clipboard never the only copy, two-key model on screen) ·
  `db93262` (F4: the invisible Keychain prompt named before it appears) · `d591fcc` (F5: 80-col
  sweep incl. doctor row word-wrap, presentation-only) · `eb4c7c6` (F7: agent-session empty-STDIN
  error leads with the real remedy) · plus this plan-close commit. Regression locks:
  `tests/wizard_interactive.bats` (8 canned-stdin unit tests + 2 expect(1) E2E PTY runs of the
  full wizard, incl. the author's exact failed scenario) and a store.bats F7 pair.
  **Key learnings** (durable): (1) F3's mechanism was *the wizard's own clipboard scrub* — setup
  taught Cmd-V two screens earlier, scrubbed the clipboard at the end of [3/7], then died on the
  resulting empty paste via store_add's fail-closed refusal under `set -e`; resilience (retry →
  skip) belongs at the screen layer, the store's refusal itself is correct and unchanged.
  (2) A paste-back only proves a save if the clipboard is SCRUBBED before the verification read —
  otherwise it verifies possession of the wizard's own copy (the old public-key echo-back defect).
  (3) expect(1) PTY locks: `expect_after` must be declared AFTER `spawn` (declared before, it
  binds to the pre-spawn id and timeouts go silent → a desync cascades into a forever-blocking
  `wait`), and answers to hidden prompts need a beat (`sleep 1`) — bash's `read -s` termios switch
  flushes queued input, eating instant sends. Both were measured, not theorized.
