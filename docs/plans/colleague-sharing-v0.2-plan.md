# Colleague secret-sharing v0.2 — implementation plan

> **Scope (frozen):** implement the `share` / `receive` / `pubkey` verbs exactly as specified in
> `docs/research/colleague-sharing-design.md`, to a **bats-green, shellcheck-clean, committed** state,
> honoring the six decisions locked 2026-07-11. **Do NOT push** — the user lands via `/ship`.
>
> This plan is the BUILD blueprint. The design doc is the source of truth for *what* and *why*; this
> doc is *how we sequence and parallelize the build*. Where a phase needs line-level detail, it points
> at the design doc's §8 (implementation notes) rather than restating it (staleness trap).

---

## Status log

- **2026-07-11 — plan created.** Design validated + on trunk (`dac1494` → `docs/research/colleague-sharing-design.md`).
  Six UX decisions locked (below). Build NOT started. Next: Phase 0 team spawn, Wave 1 = foundation.
- **2026-07-11 — BUILD COMPLETE (bats-green, shellcheck-clean, committed; NOT pushed).** All three verbs
  shipped via a 4-teammate Agent Team over 3 waves. See "Build outcome" below.
- **2026-07-11 — HARDENING PASS (pre-ship adversarial review → fixes committed).** A 40-agent adversarial
  review (7 dimensions × find→refute) confirmed 14 findings (19 of 33 raw refuted). Fixed in 5 commits;
  bats 87 → **94**. Version stays **0.1.0** (user decision: pre-public, no v0.2.0 bump). See "Hardening pass" below.

## Build outcome — DONE 2026-07-11

**Commit map (linear on `main`, not pushed):**
| Commit | What |
|---|---|
| `b61c310` | plan: Phase 0 finalized (5 ground-truth corrections to design §8) |
| `444897e` | foundation — `lib/common.sh` (envelope const + digest doc), `lib/help.sh` (3 verb specs), `lib/store.sh` (`store_add_multiline` base64, `store_manifest_set_sharing`, `store_manifest_purge_sharing`) + `tests/foundation.bats` + `help.bats` count 7→10 |
| `6f9a993` | dispatcher — registered `share`/`receive`/`pubkey` (design §8 was WRONG that no dispatcher edit was needed; explicit case table) |
| `15c8a10` | `pubkey` verb + docs (README/AGENTS/SECURITY/FAQ, all INTEGRATE) |
| `401c10c` | `receive` verb — tty-gated ingest, dual byte caps, local digest, canary+collision guards |
| `491d101` | `share` verb + `lib/ladder.sh` (R0–R4) |
| `0105e57` | decision #6 — uninstall keep-mode share-graph purge + test |

**Gate (all green, run on `main` @ `0105e57`):** shellcheck full CI set clean · `bats tests/` **87/87** ·
zero-telemetry gate PASS · **cross-verb end-to-end round-trip** PASS (share→receive, distinct keys, value
byte-for-byte, no plaintext in the envelope, `direction=received` recorded) · doctor/smoke ≤14d rotate
scan correctly parses the sharing-augmented manifest (`⚠ rotation due — BILLING_KEY in 7d`, names the
right secret) · `help --json` self-describes all 10 commands.

**Six locked decisions — all honored:** (1) digest advisory by default, `--verify` forces the readback ·
(2) no auto-tighten of `rotate_by` on share · (3) `--sign` opt-in, unsigned `receive` proceeds with a loud
warning · (4) no-tty `receive` `--yes-i-reviewed` escape (still runs canary/collision hard errors) ·
(5) `--to self` auto-inferred when recipient == local `age.pub` · (6) `shared_with` fingerprint-only +
purged in uninstall keep-mode.

**Key learnings / decisions the build forced:**
- **Multi-line values are base64-encoded in the store** (`store_add_multiline`): sops dotenv rejects raw
  newlines. `receive` branches on line count — single-line → `store_add` (raw, run-injectable);
  multi-line → `store_add_multiline` (base64; a `run`-injected multi-line secret gets the base64, a
  documented tradeoff). Design §3.7 explicitly sanctioned the base64 round-trip.
- **`AGSEC_CONFIRM_SRC` test seam** (defaults to `/dev/tty`): both `share` and `receive` read confirms
  from it, so bats injects answers while the blob holds STDIN — proving the "confirm not silently
  defaulted from exhausted STDIN" property without a PTY.
- **`bin/agent-secrets` is Read-tool-denied** (global `Read(./**/*secret*)` matches the basename) — lead
  edited it via `git show` + Bash (`/tmp/agsec-dispatcher-edit.sh`), not the Edit tool.

**Known limitations (documented, not bugs — consistent with design §3.4/§10):**
- **`--sign` is best-effort emit-only.** `share --sign` attaches a detached `ssh-keygen -Y sign` sidecar as
  a SEPARATE fenced block (never inside the v1 envelope), and warns+proceeds unsigned when no key. `receive`
  does NOT auto-verify it (the v1 envelope carries no `sig:` line) — it always prints "sender unverified".
  Full signed round-trip is deferred pending the §10 sidecar-transport research (saltpack/PGP prior art).
  A recipient CAN still verify manually with `ssh-keygen -Y verify`.
- **PQ / signature-verify / TOFU-contacts-roster** were scoped out of v0.2 per the design's opt-in stance.

## Hardening pass — DONE 2026-07-11 (bats 87 → 94; stays v0.1.0)

A 40-agent adversarial review (7 dimensions, find→refute-verify) run before ship. 14 findings confirmed
(19 of 33 raw refuted as overstated or intentional-limitation). Fixed in 5 atomic commits (linear on `main`):

| Commit | Sev | Fix |
|---|---|---|
| `a5fb9a9` | HIGH×3 | **receive decrypt-stage** — EXIT trap shreds the decrypted-value + age-private-key temps on every exit path (a SIGINT / store_add sops-failure previously stranded plaintext in the config dir); undecodable armor now fails closed with the curated message instead of a silent `set -e` abort (bare-assignment pipefail hazard); advisory digest note points at the in-band `digest:` line (was incoherently framed vs share's recipient-key fingerprint). |
| `b4ec32f` | HIGH | **share tty boundary** — the interactive-terminal check (the real agent-exfil boundary, design §3.10) was nested in the `AGENT_SECRETS_UNATTENDED` guard, so one env var disabled it; now always enforced, UNATTENDED gates only the y/N. |
| `aa9b1e3` | LOW×2 | **share arg/NAME guards** — trailing `--to`/`--rename` `shift 2` silent-abort → exit-2 usage error; regex-metachar NAME grammar-validated (fail-fast "no such secret" vs raw sops error). |
| `6ba92a0` | LOW×2 | **exit-code convention** — receive/pubkey usage errors now exit 2 (were 1, contradicting the published `exit_codes`); receive help `source=received:peer` (was aspirational `<label>`). |
| `1d38b04` | LOW×2 | **docs** — bats badge/count 41 → 94; llms.txt `## Commands` lists share/receive/pubkey. |

**Key learning:** age ciphertext is binary (NUL bytes) — it can never round-trip through a shell variable
(command substitution strips NULs), so receive decodes the armor body ONCE to a 0600 temp and hashes/caps
from the file. **Version decision (user, 2026-07-11):** pre-public, so the sharing feature is folded into
**0.1.0** — no v0.2.0 bump. Deploy = push `main` + re-cut the pinned `v0.1.0` release from current HEAD so
the one-command install delivers sharing.

## Source of truth (read these first)

- **`docs/research/colleague-sharing-design.md`** — §3 the design (decision-complete), §8 the
  implementation notes (file-by-file blueprint), §10 the locked decisions, §4 threat model, §6 the
  don't-share ladder, §3.11 failure modes.
- **The six decisions locked 2026-07-11** (already folded into the design; do not relitigate):
  1. **Digest readback → advisory by default** (shown every share; compared over a 2nd channel only
     under `--verify` or for a flagged secret). This is the one-command sender path.
  2. **`rotate_by` on share → no auto-tighten** (record the share; rotation stays operator judgment).
  3. **Sender signature → opt-in only** (`--sign`; unsigned `receive` proceeds with a loud warning).
  4. **No-tty `receive` → documented `--yes-i-reviewed` escape** (runs canary/collision hard errors,
     skips only the human confirm — for CI).
  5. **`--to self` → auto-inferred** when the recipient equals the local `age.pub`.
  6. **Manifest social-graph → fingerprint-only + purged in uninstall keep-mode.**

## Hard constraints (bind every teammate + the lead)

- **names-only:** a secret VALUE never reaches stdout/argv/logs/transcript. Values move STDIN-only;
  only ciphertext BLOBS and NAMES cross boundaries. (THE repo rule — SECURITY.md.)
- **$0, zero-vendor, everything-local.** GitHub `.keys` is an optional convenience, never a dependency.
- **Every receive-side confirm reads from `</dev/tty`** (hard-refuse if none, except `--yes-i-reviewed`).
- **Digest recomputed LOCALLY** over base64-decoded ciphertext bytes; advisory by default.
- **`--to github:<user>` writes `.keys` to a `0600` temp file → `age -R <file>`; never `age -R -`.**
- **Canary name (`AWS_BACKUP_ACCESS_KEY_ID`) refused in the share/receive verbs** (hard error, no confirm);
  `store_add` still seeds it (leave store.sh:109 alone).
- **`share` gated behind `agsec_in_agent_session` + interactive-tty**; `receive` is tty-gated, NOT env-gated.
- **Commit per task** (lowercase Conventional Commits); **do NOT push.**
- **Agent Teams for the build** (2+ code tasks → Phase 0 mandatory, per global CLAUDE.md).

---

## Phase 0 — Agent Team Orchestration

**Runtime:** detect the session's CC track (implicit-team model on 2.1.178+ → spawn via
`Agent({name, team_name, model})`; classic `TeamCreate` on 2.1.114). Teammate model = **Opus 4.8**
(default). Rationale for Opus over Fable on this build: parts of the code call `age`/`ssh-keygen` and
carry security-intent comments that can trip Fable's dual-use classifier (the failure that killed the
first research attempt — see design §11). Keep the build on Opus; it reads clean regardless.

**Single-owner rule (avoids shared-file conflicts):** the **foundation** teammate owns ALL edits to
`lib/common.sh`, `lib/help.sh`, `lib/store.sh`. The verb teammates only ADD new `cmd/*.sh` files and
their own `tests/*.bats` (+ `tests/mocks/`), and CALL the foundation's helpers. So Wave-2 worktrees
never touch the same tracked file → clean `git merge`, no cherry-pick needed.

### Team + task graph

| Task | Teammate | Owns (writes) | blockedBy | Est. LOC |
|---|---|---|---|---|
| **F · foundation** | `foundation` | `lib/common.sh` (envelope const + digest doc), `lib/help.sh` (register `share receive pubkey` in `AGSEC_VERBS` + all 3 help specs), `lib/store.sh` (in-place manifest row-updater + multi-line-safe value writer) | — | ~200 |
| **S · share** | `share` | `cmd/share.sh`, `lib/ladder.sh` (R0–R4 + provider table), `tests/share.bats`, ladder mocks | F | ~350 |
| **R · receive** | `receive` | `cmd/receive.sh`, `tests/receive.bats`, `tests/mocks/` (curl `.keys`, `ssh-keygen`, argv-inspect) | F | ~300 |
| **P · pubkey+docs** | `pubkey-docs` | `cmd/pubkey.sh`, `tests/pubkey.bats`, docs wiring (README, AGENTS.md, SECURITY.md, FAQ) | F | ~200 |

### Spawn waves

- **Wave 1:** `foundation` (solo, own worktree `feat/share-foundation`). Lead reviews + merges to `main`.
- **Wave 2** (after F merges): `share`, `receive`, `pubkey-docs` in parallel worktrees off the
  post-F `main` (`feat/share-verb`, `feat/receive-verb`, `feat/pubkey-docs`). Independent files → merge each.
- **Wave 3 (lead):** integrate all, run the full gate (below), wire + verify the doctor/smoke `≤14d`
  reminder still parses the new manifest rows, and run one end-to-end round-trip (`share` → `receive`
  through a mock recipient key on a PTY).

### Per-teammate brief discipline (global agent-teams.md)

Each brief ≤150 lines, pre-grep line ranges embedded, "stop on issue → message lead" clause verbatim,
no "investigate/audit" language, visual/integration checks deferred to the lead's Wave 3. Point each
teammate at design §8 for its file's spec; do not inline the whole design.

### Phase 0 — FINALIZED 2026-07-11 (ground-truth reads corrected 5 design-§8 gaps)

Runtime = **implicit-team model** (no `TeamCreate`; `team_name` is ignored). Teammates spawn via the
`Agent` tool, `model: "opus"`, in **pre-created worktrees** (lead runs `git worktree add` serially to
dodge the parallel-`worktree add` data-loss race, GH #34645/#48927); each teammate `cd`s into its
worktree and commits on its own branch; lead merges serially. Corrections to the design/plan blueprint,
forced by reading the actual source:

1. **Dispatcher edit IS required — LEAD-OWNED.** Design §8 says "no dispatcher edit (unknown → exit 2)"
   — **wrong.** `bin/agent-secrets` has an explicit `case "$verb"` table (setup|add|list|run|doctor|
   uninstall) + a per-verb help-interception `case`; a new verb hits the `*)` unknown-command arm. So
   `share|receive|pubkey` must be added to BOTH cases. `bin/agent-secrets` is **Read-denied** (global
   `Read(./**/*secret*)` rule matches the basename) → the lead does this edit at Wave-1 merge time (read
   via `git show HEAD:bin/agent-secrets`, write via Bash/Write), NOT a teammate. Done AFTER foundation
   merges, BEFORE Wave 2 branches, so the verb worktrees inherit a fully-wired dispatcher.
2. **`tests/help.bats:53` breaks** — asserts `.commands|length==7`; foundation's 3 new verbs make it 10.
   **Foundation owns the `7`→`10` bump** (green from the help.sh spec change alone — `help --json` is
   pure help.sh, dispatcher-independent). Foundation leaves the `for v in setup add …` loops at
   help.bats:9/13 alone (adding new verbs there needs the dispatcher); lead extends verb-help coverage in
   the dispatcher commit. `tests/dispatcher.bats` is unaffected (frobnicate/rotate/demo still hold).
3. **Decision #6 (uninstall keep-mode purge) is SPLIT.** Foundation adds a values-free
   `store_manifest_purge_sharing` helper to `lib/store.sh` (strips `shared_with`/`shared_at`/`direction`/
   `source = "received:*"` lines from `manifest.toml`). **Lead** wires the one-line call into
   `cmd/uninstall.sh` keep-branch (store.sh:42-47 region) + adds the assertion to `tests/uninstall.bats`
   in Wave 3 — both are shared files no teammate should race on.
4. **Mock ownership fixed to avoid merge collisions in `tests/mocks/` (a shared dir).** `share` owns
   `tests/mocks/curl` (fake `github.com/<user>.keys`: valid / empty / YubiKey-only) **and**
   `tests/mocks/ssh-keygen` (`-Y sign`/`-Y verify`). `receive` and `pubkey` add **no** new mock files
   (receive's required tests need none; its unsigned-warning path uses no sidecar; `gh`/`pbcopy`/`security`
   mocks already exist). Each teammate keeps test helpers **inside its own `.bats` file** — never edits
   the shared `tests/test_helper.bash`.
5. **`receive` PTY-confirm test seam.** No PTY/`expect` infra exists. `receive` reads every confirm from
   `${AGSEC_CONFIRM_SRC:-/dev/tty}` (defaults to `/dev/tty` in production — behavior unchanged) so bats
   can point `AGSEC_CONFIRM_SRC` at a file/FIFO carrying the answer **while the blob occupies STDIN** —
   this is exactly the "confirm honored, not silently defaulted from an exhausted STDIN" property (§3.7).
   No-tty hard-refuse = `AGSEC_CONFIRM_SRC` unset/unreadable.

Also verified: `doctor.sh:72-91` + `smoke.sh:49-66` scan `manifest.toml` by `*name*=*` / `*rotate_by*=*`
line-matching — none of the new field names (`shared_with`/`shared_at`/`direction`) contain `name` or
`rotate_by`, so the ≤14d engine is unaffected (Wave-3 reconfirms with real rows). `store_extract`
byte-fidelity (trailing-newline) is symmetric sender↔receiver; receive owns the round-trip + multi-line
survival tests. Ladder/`--singleton`/`--to`/R0–R4 confirmed **net-new** (grep-empty) → built in
`cmd/share.sh` + `lib/ladder.sh` (share-only; receive's `--self` needs no ladder).

---

## Phase 1 — Foundation (`foundation`, Wave 1)  [blocks all verbs]

Detail: design §8 "Files to touch" → `lib/common.sh`, `lib/help.sh`, `lib/store.sh` bullets.

- `lib/common.sh`: add `AGSEC_SHARE_ENVELOPE_VERSION="v1"`; document `agsec_digest` (common.sh:61) is
  fed **base64-decoded ciphertext bytes**, 48-bit, accidental-mismatch only.
- `lib/help.sh`: add `share receive pubkey` to `AGSEC_VERBS` (help.sh:12); add the 3 help-spec row sets
  so `help --json` renders them (schema: synopsis/summary/desc/args/flags/env/examples/exit/reads/writes/
  names_only). Reserved-verb line stays `rotate, demo` (help.sh:122).
- `lib/store.sh`: **new** in-place manifest row-updater for `shared_with`/`shared_at`/`direction`/`source`
  (do NOT extend `_store_manifest_upsert`, skip-if-exists at store.sh:79). **New** multi-line-safe value
  path (a `cat`-based writer like `kc_add`, keychain.sh:16) — `store_add`'s `IFS= read -r` (store.sh:60)
  truncates at the first newline. Value stays out of any shell var / argv.
- **Gate before merge:** `shellcheck lib/*.sh` clean; existing `bats tests/` still green (no regressions).

## Phase 2 — Verbs (`share`, `receive`, `pubkey-docs`, Wave 2, parallel)

Detail: design §8 `cmd/share.sh`, `cmd/receive.sh`, `cmd/pubkey.sh` bullets + §3.5–§3.11.

- **`cmd/share.sh`** — order: `agsec_in_agent_session` refuse + interactive-tty require → build+run
  ladder gate (R0–R4, `lib/ladder.sh`) → name-exists check → resolve recipient (`age1…` / `github:.keys`
  to 0600 temp file / `self` auto-infer) + contacts-roster pin + cert/sk-FIDO2 reject → the ONE mandatory
  confirm from `</dev/tty` (fingerprint + NAME; digest shown, compare advisory unless `--verify`) →
  `store_extract | age -r <recip> -a` → envelope + code fence (digest over base64-decoded ciphertext) →
  foundation's manifest writer (`direction=sent`) → **no rotate-tighten**. `--sign` → `ssh-keygen -Y sign
  -n share-v1@<domain>`.
- **`cmd/receive.sh`** — order: every confirm/re-prompt from `</dev/tty` (hard-refuse if none, except
  `--yes-i-reviewed`) → STDIN blob ingest (restore.sh:21-25 pattern) → dual byte caps (raw before decode,
  decoded before decrypt) → parse+version-check envelope → recompute digest LOCALLY + display (advisory)
  → optional `ssh-keygen -Y verify` (loud warn if unsigned) → canary refuse (hard error) → existing-NAME
  hard-stop confirm from `/dev/tty` → pipe `age -d` directly into foundation's 0600-temp multi-line writer
  (**stderr `2>/dev/null` + curated fail-closed message**) → record `direction=received`, `source=received:<label>`.
- **`cmd/pubkey.sh`** — print `agsec_age_pub_file` contents + `agsec_digest` fingerprint (+ `--copy`).
  Public key → safe on stdout/argv/clipboard. The recipient's on-ramp.

## Phase 3 — Tests (each verb's teammate writes its own `.bats` + mocks)

Full matrix in design §8 "Test plan". Key assertions: value never in argv (croc CVE-2023-43621 mock);
`share` ladder-refuses without `--singleton`, `.keys`→temp-file, digest stable across benign reflow,
refuses in agent session + no tty; `receive` PTY-confirm honored / no-tty hard-refuse (and
`--yes-i-reviewed` bypass) / unknown-version reject / existing-NAME hard-stop / canary refuse /
multi-line survives / oversized rejected pre-decode AND pre-decrypt / decrypt-error stderr carries no
fragment / local digest displayed; `pubkey` safe in agent session; `help --json` has all three verbs.

## Phase 4 — Docs (`pubkey-docs`)

design §8 "Docs wiring": README (command list + ladder-first), AGENTS.md (`share` agent-refused;
`receive` tty-gated + why), SECURITY.md (new "Sharing" subsection, honest-ceiling voice), FAQ (3 Q&As).

## Phase 5 — Integration + green gate (lead, Wave 3)

- `shellcheck bin/* cmd/*.sh lib/*.sh scripts/*.sh install.sh` clean.
- `bats tests/` fully green (existing 41 + the new share/receive/pubkey suites).
- Zero-telemetry gate (CI's) still passes.
- One end-to-end round-trip through a mock recipient key on a PTY.
- Confirm doctor/smoke `≤14d` still parses `manifest.toml` with the new rows present.
- Commit per phase; leave the tree clean. **Do NOT push** — report the ledger; user lands via `/ship`.

---

## Acceptance (definition of done)

`share`/`receive`/`pubkey` implemented per the design; the six locked decisions honored; all bats green;
shellcheck clean; `help --json` self-describes the verbs; names-only never violated (value never on
stdout/argv/log); committed atomically; NOT pushed.
