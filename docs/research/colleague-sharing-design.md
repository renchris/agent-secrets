# Colleague-to-colleague secret sharing — design research

> **STATUS — VALIDATED DESIGN (research complete), 2026-07-11.**
> The recommended `share` / `receive` / `pubkey` design (§3) is decision-complete: an all-Opus
> research wave (axes B–I) with per-axis adversarial verification, a red-team pass (one repair
> round), and a hostile-completeness review now back it. §1 (the problem) and §2 (repo rails)
> stand as first written. New: §4 threat model, §5 option matrix, §6 don't-share ladder, §7
> rejected alternatives, §8 v0.2 implementation notes. §9 records what the original §3 hypothesis
> got wrong; §10 the maintainer-decision open questions; §11 provenance.
>
> **Settled** (design + all six maintainer decisions locked 2026-07-11): the mechanism — a raw
> X25519 age-armored blob in a versioned `AGENT-SECRETS SHARE v1` fence, ladder-gated before any
> value is copied, rotation as the only revocation. The everyday **sender path is a single command
> + one `[y/N]`** (`share NAME --to github:bob`): the recipient confirm (fingerprint + NAME) is the
> one mandatory gate, the digest readback is **advisory** (shown every time, compared over a second
> channel only under `--verify` or for a flagged secret), and there is **no auto-rotate**. Hard
> rules: every receive-side confirm reads from `/dev/tty` (hard-refuse if none, unless the
> documented `--yes-i-reviewed` CI escape); the digest is recomputed **locally** over decoded
> ciphertext bytes; `--sign` (opt-in) is the only substitution defense; `--to github:<user>`
> fetches `.keys` to a `0600` temp file (never `age -R -`); the canary name is refused in both
> verbs; multi-line values survive; decrypt stderr is disciplined.
>
> **Still open (§10):** one empirical test only you can run — does a fenced armored blob survive a
> paste through your real Slack/Teams/email? — plus two build-time verification probes (saltpack/PGP
> prior-art before the `--sign` sidecar; typage/rage PQ interop before PQ is first-class).

---

## 1 · The problem — why the sharing gap defeats the model

agent-secrets keeps a secret **value** out of every place it normally leaks (config files, shell
exports, logs, agent transcripts) and injects it just-in-time. That guarantee ends the moment one
colleague hands a secret to another by the usual paths — each re-introduces exactly the plaintext
sprawl the tool exists to prevent, and often somewhere *more* durable than a local `.env`:

| Transfer path | Where the value leaks |
|---|---|
| Slack / Teams / chat | Server-side retention; compliance / eDiscovery exports; link-unfurl & preview bots; workspace-admin access; message search index |
| Email | Mail-server + backup retention; auto-forwarding; DLP / archival systems |
| Plaintext file (AirDrop, attachment) | Lands on disk at both ends; Time Machine / backups; Spotlight index; iCloud / Dropbox sync |
| Any of the above | Clipboard managers, terminal scrollback, tmux/screen logs, shell history (if echoed) |

The names-only invariant is intact **at rest** and **in use**, but has **no story for transfer** — that
is the gap. Sharing a value over a retained channel is strictly worse than the sprawl the tool
replaced, because the recipient's copy now also lives outside any store, indefinitely.

**Design tenets any solution must honor (from the repo's existing ethos):**
- **Names-only** — a secret *value* never crosses a boundary in plaintext; only ciphertext blobs and
  names do. Values move via STDIN, never argv/stdout/logs.
- **$0, zero-vendor, everything-local** — no server the design depends on to function.
- **Sharing is the last rung** — mirror "lean on provider login first"; prefer minting a per-person
  scoped credential over copying one.

---

## 2 · Repo rails a `share`/`receive` verb pair builds on — COMPLETE (Axis A)

Ground-truth survey of the internal surfaces (file:line). No `share`/`team`/`export`/`send`/`import`/
`receive` infrastructure exists yet — clean slate, no verb conflict.

**Store & value transport — `lib/store.sh`**
- `.sops.yaml creation_rules` are written by `store_init` with `age: "<primary>,<recovery>"` — a
  **comma-joined recipient list, no spaces** (store.sh:40–45). `_store_recipients` combines the primary
  `agsec_age_pub_file` + optional `recovery.pub` (store.sh:15–23). **Multi-recipient is already the
  norm** — a share target is just another recipient.
- `store_add(NAME)` reads the value from **STDIN only**, stages a `0600` temp, encrypts, `_store_shred`s
  it (store.sh:54–73). `store_extract` is the *sole* value-out (JIT). `_store_decrypt` (store.sh:30–33)
  is internal-only, never surfaced.
- Name rule: `^[A-Za-z_][A-Za-z0-9_]*$`.

**Key custody — `lib/keychain.sh`**
- age **private** key: login Keychain (service `agent-age-key`) primary + `0600` file fallback
  (`agsec_age_key_file`); selector at `age_key_cmd_path()` = `$(agsec_config_dir)/age-key-cmd.sh`, body
  `security find-generic-password -s agent-age-key -w || cat <file>`, exported as `SOPS_AGE_KEY_CMD`
  (keychain.sh:25–43). age **public** key: `agsec_age_pub_file`. `recovery.pub` in the config dir.
  `kc_status()` → `primary | degraded (file custody) | missing`.

**The `receive`-ingest pattern already exists — `lib/restore.sh:18–40`**
- Read key material from STDIN (tty ⇒ `ui_read_secret`, else `cat`) → `kc_add` → `kc_write_selector` →
  **verify by decrypting the canary** (`store_extract $AGENT_SECRETS_CANARY_NAME`), return 0 on success.
  A `receive` verb mirrors this: ingest blob on STDIN → decrypt → `store_add` → verify.

**Manifest schema — `lib/store.sh:75–83`** (values-free; header `# agent-secrets credential manifest
(values-free)`)
- `[[credential]]` fields: `name`, `platform`, `source` (=`"sops:secrets.env"`), `scope`, `rotate_by`
  (= now + 180d, `AGENT_SECRETS_ROTATE_DAYS_DEFAULT`), `used_by=[]`, `surface`. Idempotent upsert.
- **Share extension (proposed):** add `shared_with` (recipient label + key fingerprint), `shared_at`,
  `direction` (sent/received); on the receiver, set `source="received:<label>"`; consider **tightening
  `rotate_by`** on share. `doctor` (cmd/doctor.sh:72–91) already scans `rotate_by` ≤14d; smoke.sh:49–66
  alerts weekly.

**New-verb conventions**
- Dispatcher `bin/agent-secrets` routes `$AGENT_SECRETS_CMD/<verb>.sh`; unknown → exit 2; reserved
  `rotate`,`demo` → exit 2 "v0.2" (help.sh:122).
- Register in `AGSEC_VERBS` (help.sh:12) + add help spec rows; `help --json` schema =
  `{tool,version,commands[{name,synopsis,summary,description,args,flags,env,examples,exit_codes,reads,
  writes,names_only}],reserved_v0_2,agent_notes}`.
- `cmd/*.sh` skeleton: shebang, `set -euo pipefail`, source `common.sh`, help-guard
  `case "${1:-}" in -h|--help) … agsec_help_render VERB`, source store/keychain/ui, `agsec_die MSG`
  (exit 1 runtime / 2 usage), `agsec_ok`. Tests: bats under synthetic `AGENT_SECRETS_HOME` + `mocks/`
  (security, pbcopy, gh…), `setup_store` helper.
- Reusable primitives: `lib/ui.sh` `ui_confirm`/`ui_menu`/`ui_read_secret` (hidden input); `lib/common.sh`
  `agsec_digest(VALUE)` → `sha256:<first-12-hex>` — **reuse for a fingerprint/digest readback ceremony**;
  const `AGENT_SECRETS_CANARY_NAME=AWS_BACKUP_ACCESS_KEY_ID`.

---

## 3 · Recommended design — `share`, `receive`, `pubkey`

The §3 hypothesis holds in **shape** — an age-armored ciphertext blob pasted over any channel, decrypted
on receive — but the research overturned three specifics and pinned down every mechanism it left open
(the corrections are catalogued in §9). What follows is decision-complete; each choice is stated as a
DECISION with its one-line why, and only genuine maintainer-calls are deferred to §10.

### 3.1 · The mechanism

`agent-secrets share <NAME> --to <recipient>` runs the don't-share ladder (§6) FIRST, and only at its
terminal rung pipes `store_extract "$NAME"` (store.sh:92, the single-value JIT out) into a fresh **`age -r
<recipient-pubkey> -a`**, wrapping the armor in a versioned fence printed to STDOUT for the sender to paste
into chat. The recipient runs `agent-secrets receive`, pastes the block on STDIN, and the value is
decrypted and written straight into their store — **never displayed**. A prerequisite verb, `agent-secrets
pubkey`, lets the recipient hand the sender their `age1…` recipient string + fingerprint safely.

*Decision: the share primitive is `store_extract | age -r`, NOT `store_add`'s `sops -e`.* `store_add`
re-encrypts the **entire** `secrets.env` to the local recipient list (store.sh:69) — the wrong primitive
for a one-value send. Encrypting a single extracted value to one external recipient scopes the blob to
exactly one NAME and never touches the store's `.sops.yaml`.

### 3.2 · Crypto + blob envelope (versioned)

Confidentiality is native age X25519 — every install already mints an X25519 keypair, and
`_store_recipients` already handles a comma-joined recipient list (store.sh:16-23). age's X25519 stanza
carries only the ephemeral share, no recipient identifier, so a native blob is anonymous/unlinkable and
does not leak which colleague it targets ([C2SP/age.md](https://github.com/C2SP/C2SP/blob/main/age.md)).
The wire payload is age's strict RFC-7468 PEM armor (`-----BEGIN AGE ENCRYPTED FILE-----`, 64-column
base64), targeting the **v1 wire format** so any conformant age (go/rage/typage) decrypts it. *Decision:
no custom crypto container* — the armored blob rides inside a fenced envelope carrying only the metadata
`receive` needs, all outside the armor so a strict PEM parser is unaffected:

```
-----BEGIN AGENT-SECRETS SHARE v1-----
name: ANTHROPIC_API_KEY
direction: sent
digest: sha256:1a2b3c4d5e6f          # HINT ONLY — over base64-DECODED age ciphertext bytes
-----BEGIN AGE ENCRYPTED FILE-----
<age armor>
-----END AGE ENCRYPTED FILE-----
-----END AGENT-SECRETS SHARE v1-----
```

Version constant `AGSEC_SHARE_ENVELOPE_VERSION="v1"`. *Why v1-tagged:* the age format is
frozen-decryptable-forever ([discussion #215](https://github.com/FiloSottile/age/discussions/215)), so the
only thing that can evolve is our envelope; tagging it lets `receive` reject an unknown envelope loudly.
*Why the digest is over decoded bytes:* PEM armor is malleable — a benign reflow (rage/typage re-encode, a
chat client re-wrapping the base64) yields identical plaintext but different armored bytes; hashing the
base64-decoded ciphertext is reflow-stable (empirically confirmed: identical digest after a 40-column
refold). *Why `digest:` is labeled HINT ONLY:* see §3.4 — the receiver **recomputes** it locally; the
embedded value is attacker-controllable envelope text and is never the value compared.

### 3.3 · The `pubkey` verb (the on-ramp)

Before any share, the sender needs the recipient's `age1…` string. *Decision: add `agent-secrets pubkey`*
— prints the local recipient string (contents of `agsec_age_pub_file`) plus its `agsec_digest`
fingerprint, optionally `--copy` to the clipboard. The public key is non-secret, so it is safe on
stdout/argv/clipboard (unlike every value path). *Why a first-party verb rather than "just `cat age.pub`":*
the recipient string is itself subject to the chat-mangling (smart quotes, line-wrap, truncation) the
design worries about for the blob; a dedicated verb emits a labeled, fingerprint-stamped string the sender
can pin, and closes the receiver-side half of key discovery the sender-side story otherwise assumes.

### 3.4 · Sender authentication — the stance

age gives integrity and confidentiality, never authorship, and even bolt-on signing "can't be done
perfectly" ([filippo.io](https://words.filippo.io/age-authentication/)). *Decision (locked 2026-07-11): the
one **mandatory** gate is the recipient confirm (§3.5 — fingerprint + NAME); the out-of-band digest
readback is **advisory by default**.* `receive` always recomputes and displays the checksum, but comparing
it over a second channel is optional for everyday shares and enforced only when the sender opts in
(`--verify`) or the secret is flagged high-value. *Why advisory:* the readback catches only an ACCIDENTAL
wrong-recipient/corruption — a substitution attacker recomputes a matching digest over their own blob
trivially, so it is **never** a substitution defense — and demoting it from mandatory is exactly what lets
the everyday sender path be a single command + one confirm (§3.6) without giving up the real wrong-recipient
defenses (the mandatory fingerprint confirm + the TOFU contacts pin). Authenticity against a chosen-blob
substitution comes only from the opt-in detached signature (`--sign`, Filippo's own recommended zero-vendor
workaround), verified against a local `allowed_signers` with a project-owned namespace
(`share-v1@<owned-domain>`, following [agwa's convention](https://www.agwa.name/blog/post/ssh_signatures))
to block cross-protocol reuse. *Signature stance (locked 2026-07-11): opt-in only — no secret class is
fail-closed.* An **unsigned** `receive` proceeds but prints a loud *"sender unverified — you are trusting
whoever pasted this"* — never a green check we cannot back (mirrors setup.sh:39's honesty norm).

*Decision (red-team fix): the digest is recomputed LOCALLY on receive and displayed for the human
voice-compare.* `receive` base64-decodes the armor body, runs those raw bytes through `agsec_digest`, and
shows **its own** computed value to compare against the sender's spoken value. The envelope's embedded
`digest:` line is a corruption hint at most; comparing the sender's voice value against the *embedded* text
would validate attacker-controlled data and let a wrong-recipient blob (self-consistent embedded digest)
pass even the accidental-mismatch floor. The 48-bit width (`sha256:` + first 12 hex, common.sh:61) is
adequate for a live human readback (a fat-finger cannot usefully collide 48 bits in a voice compare; a
deliberate preimage is ~2⁴⁸ encryptions, impractical on a laptop) but must never be presented as a
content-addressed identifier or a substitution catch.

### 3.5 · Key discovery + trust ceremony (wrong-recipient proofing)

Three discovery paths, one mandatory forcing gate:

- **Primary — pasted native `age1…` recipient** (the recommended crypto path).
- **Convenience — `--to github:<user>`** fetches `https://github.com/<user>.keys` over HTTPS. *Decision
  (red-team fix): write the fetched keys to a `0600` temp FILE and encrypt with `age -R <tmpfile>`, never
  `age -R -`.* `age -R -` reads recipients from STDIN, but the plaintext value also flows on STDIN
  (`store_extract | age`) — empirically the two collide (`age` errors "standard input is used for multiple
  purposes"). Validate the file is non-empty and parses as ≥1 recipient before use; an empty `.keys`
  (auth-key-less user) **fails loudly** and falls back to a pasted `age1…`, never silently encrypting to
  zero recipients. *Caveat, stated in help:* `.keys` returns **all** of a user's authorized keys — often
  several, including rotated-out or attacker-added ones — so `age -R <file>` widens the blob to a
  multi-recipient set decryptable by any holder of any listed key, and SSH-recipient stanzas embed a
  trackable public-key tag. TLS + GitHub-account binding authenticate the *first* fetch (escaping the
  raw-TOFU critique, [agwa](https://www.agwa.name/blog/post/why_tofu_doesnt_work)), but the set-widening is
  real: **prefer native `age1…`**.
- **Trust layer — a local `contacts` roster** (pinned pubkey + label + first-seen date), seeded from the
  authenticated fetch. A subsequent key change is a **hard block-until-confirm**, not a dismissable warning
  (field evidence: users essentially never verify keys out-of-band —
  [Gutmann, ARES 2023](https://arxiv.org/html/2306.04574)).

*Decision: recipient confirmation is mandatory, forcing, and the single load-bearing, polymorphic confirm*
— not a per-share `[y/N]`. Security prompts habituate away fast (visual-processing shutdown after the
**second** exposure to a repeated warning,
[Schneier/Anderson](https://www.schneier.com/blog/archives/2015/03/how_we_become_h.html); ~70% of Chrome
users click through SSL warnings, [Akhawe & Felt, USENIX 2013](https://www.usenix.org/conference/usenixsecurity13)),
so the confirm shows the **varying, decision-relevant payload** — recipient fingerprint + secret NAME — and
cannot be pattern-dismissed. Do **not** rely on human fingerprint comparison as the security boundary:
adversarial fingerprints are accepted 13–44% of the time and longer is worse
([ARES 2023](https://arxiv.org/html/2306.04574)). Rotation is the real revocation; the SSH sidecar is the
real substitution defense.

*SSH-recipient input validation (hostile-review gap):* age accepts only bare SSH **public keys**, not
certificates. A colleague in an SSH-CA org pasting a cert-form key (`ssh-ed25519-cert-v01@…`) is rejected
by age; `--to`/`receive` must detect the cert wrapper and fail with a useful message (or extract the
underlying pubkey), not surface a raw age error. sk-FIDO2 hardware keys are permanently undecryptable as
age recipients (§7) — reject them at input with the reason, don't let the blob silently fail downstream.

### 3.6 · Sender UX

```
$ agent-secrets share ANTHROPIC_API_KEY --to github:dana
# 1. share REFUSES inside an agent session, and requires an interactive tty (§3.10).
# 2. Ladder gate (R0–R4, §6) runs FIRST. On a per-person-mintable name → prints the
#    R2 recipe and refuses unless --singleton (or --self) is given.
# 3. Name check: NAME must exist in the store (a typo'd/non-existent name fails fast).
# 4. Resolves recipient → the ONE mandatory confirm (fingerprint + NAME):
     Share the VALUE of ANTHROPIC_API_KEY → "dana" (sha256:1a2b3c4d5e6f)?  [y/N]
     (checksum shown so you CAN read it back on a call — optional unless --verify)
# 5. store_extract ANTHROPIC_API_KEY | age -r <dana's key> -a  → envelope to STDOUT
# 6. Records the manifest row (direction=sent) + prints paste instructions.  ← no auto-rotate
```

*Decision (locked 2026-07-11): the everyday sender path is a single command + one `[y/N]`* — the same
weight as `add` — because the digest comparison is advisory (§3.4) and there is no auto-rotate (§3.9). The
`--to github:dana` form needs no prior key exchange (it fetches Dana's key from GitHub), so the common case
is genuinely one command.

Flags: `--to <age1…|github:user|self>` (`self` is auto-inferred when the recipient equals your own key —
the flag is optional), `--singleton` (asserts a true singleton; required to bypass R2), `--verify` (force
the aloud checksum comparison), `--sign` (attach the opt-in SSH sidecar). *Decision: emit the blob inside a
triple-backtick code fence with an explicit "paste the whole block including the fences" instruction* — age
armor's `+/=` are exactly the characters Markdown chat clients mangle (Saltpack chose Base62 to dodge this,
[saltpack.org](https://saltpack.org/)); fenced blocks suppress that
([Slack docs](https://docs.slack.dev/messaging/formatting-message-text/)).

*Wrong-secret selection (hostile-review gap).* Every wrong-recipient defense guards WHO receives; the more
frequent human error is fat-fingering WHICH secret. Mitigations: the name must resolve to an existing entry
(fail fast otherwise); the confirm leads with "the VALUE of `<NAME>`"; and `share` with no `--to` (or an
ambiguous name) lists candidate names rather than guessing. A wrong-name share is unrecoverable (the bearer
copy is out), so the NAME is a first-class element of the one confirm, not incidental.

### 3.7 · Receiver UX

```
$ agent-secrets receive          # reads the pasted envelope on STDIN
```

- **`/dev/tty` for every confirm/re-prompt (DECISION — the load-bearing fix).** The blob arrives on STDIN,
  but `ui_confirm` reads its y/N via `read -r ans` from STDIN too (ui.sh:23); with the blob piped in, STDIN
  is exhausted → the confirm reads empty and silently takes its default with no human in the loop.
  `receive` therefore reads the recipient/collision confirms (and every re-prompt) from `</dev/tty`,
  reading the blob from STDIN only *after* the tty gate. **No controlling tty → `receive` hard-refuses**
  rather than auto-defaulting, *unless* the documented `--yes-i-reviewed` escape is passed (DECISION locked
  2026-07-11: it still runs the canary/collision HARD errors, only skipping the human confirm, so CI can
  restore a shared secret). *Why:* the polymorphic recipient gate must stay reachable when the env guard is
  bypassed by a prompt-injected agent; an exhausted STDIN silently defeating it is exactly the failure the
  gate exists to prevent — and the escape is opt-in and explicit, never the default.
- **STDIN ingest, never an echoed line-read** — mirror restore.sh:21-25's tty-vs-`cat` branch (survives
  bracketed-paste corruption and multi-line auto-submit; Claude Code is a named cause of broken paste
  bracketing).
- **Dual byte-length caps (DECISION — red-team fix).** Cap the raw pasted envelope BEFORE base64-decode,
  and cap the decoded ciphertext BEFORE decrypt. A giant base64 body balloons on decode; both bounds are
  needed to close the header-size / stanza-count DoS the age spec does not cap.
- **Local digest recompute + display** (§3.4) — decode the armor body, recompute `agsec_digest` locally,
  show it for an **advisory** voice compare (optional by default; forced only under `--verify` or for a
  flagged secret), treating the embedded `digest:` as a corruption hint only.
- **Sender-auth verify** — if `--sign` was used, `ssh-keygen -Y verify` against `allowed_signers`;
  unsigned → loud "sender unverified" warning, proceed.
- **Canary-name refusal (DECISION — hard error both directions).** Refuse to `share`
  `AWS_BACKUP_ACCESS_KEY_ID` and refuse to let a received blob write it — a hard error *in the verbs*, no
  confirm, so STDIN exhaustion cannot bypass it. *Note:* this is net-new refusal logic; store.sh:58 is only
  a syntax check, and store_add itself seeds the canary at store.sh:109 (so the guard lives in
  share/receive, never in store_add). *Why:* sharing the tripwire poisons whole-store-sweep detection on
  both machines.
- **Name-collision (DECISION — hard-stop, not silent overwrite).** `store_add` clobbers silently
  (store.sh:65). `receive` detects an existing NAME and requires an explicit `ui_confirm` **from
  `/dev/tty`** (or `--rename NEW`) before writing.
- **Multi-line value safety (DECISION).** `store_add`'s `IFS= read -r value` reads a single line
  (store.sh:60) — a PEM key / JSON service-account / cert chain would be truncated at the first newline.
  `receive` uses a `cat`-based, multi-line-safe write path (as `kc_add` already does at keychain.sh:16) or
  base64-round-trips the value before `store_add`.
- **Value never in a shell variable / argv (DECISION).** `receive` pipes `age -d` **directly** into the
  0600-temp store writer (croc's CVE-2023-43621, value-in-argv, is the direct proof this matters). The
  plaintext is held in memory identically to a bare `age -d`; the only difference `receive` claims is that
  it never materializes the value as a sprawled file on disk.
- **Decrypt stderr discipline (DECISION — hostile-review gap).** `receive`'s decrypt/verify steps redirect
  stderr (`2>/dev/null`) and emit a single curated fail-closed message. sops/age diagnostics on a corrupt
  blob can surface fragments, and `receive` runs in a terminal whose scrollback a coding agent may read —
  an un-disciplined error is a last-step names-only breach.
- **No-install recipient path (DECISION — do NOT promise zero-setup; do NOT ship a plaintext escape).** A
  raw age blob requires the recipient to already have age + a keypair; true zero-setup receive is
  impossible serverlessly. First-run `receive` bootstraps the recipient's keypair in one step, and the
  shared block ships **with** a short copy-pasteable `receive` one-liner (Psst!'s self-describing pattern).
  A recipient with bare `age` could `age -d` the blob, but that materializes plaintext to a terminal/file —
  so `receive` guides toward install-then-ingest and never emits a "decrypt to a file" recipe.
- **Multi-machine self-share (DECISION — transport, not Keychain seeding).** `security add-generic-password
  -w` does not read STDIN on Sequoia (it prompts /dev/tty; keychain.sh:8-11), so self-share cannot silently
  seed the Keychain. It reduces to transporting the `AGE-SECRET-KEY` via STDIN into `kc_add` (0600
  fallback) — the restore flow already fits. `--to self` takes the R0 ladder bypass, and (DECISION locked
  2026-07-11) is **auto-inferred** when the resolved recipient equals the local `age.pub` — the explicit
  flag still works but is never required.
- **Group-share stance (DECISION — refuse for the single-value verb).** A `sops updatekeys`-style "add
  recipient to my store" grants standing decrypt of **all** secrets (the gopass team-store model). A
  one-off `share` scopes to one value encrypted to one external recipient. Standing team stores are out of
  scope for v0.2.

### 3.8 · Manifest delta (values-free; new in-place writer)

`_store_manifest_upsert` is skip-if-exists (store.sh:79) and you share an *already-existing* name, so it
would no-op and drop the metadata. *Decision: add a dedicated in-place row updater* (do NOT extend
`_store_manifest_upsert`). New/changed fields on the `[[credential]]` row:

| Field | Value | Note |
|---|---|---|
| `shared_with` | recipient key fingerprint (label optional) | fingerprint primary — minimize the plaintext social graph |
| `shared_at` | ISO date | sender-side fact known at share time |
| `direction` | `sent` \| `received` \| `self` | `self` excluded from the offboarding query |
| `source` | on receive: `received:<label>` | powers "what came from X" |

This is metadata, not a value (SECURITY.md:6-11 scopes names-only to a *value*; `list` already prints
manifest metadata), so it does not breach the invariant. `shared_with` (external recipients) is orthogonal
to the existing `used_by=[]` (local consumers, store.sh:82); the offboarding query reads both. *Decision
(locked 2026-07-11): `shared_with` defaults to the opaque fingerprint (a human label is opt-in), and the
share roster is purged even in uninstall **keep-mode*** — closing the plaintext who-shared-with-whom leak
keep-mode would otherwise retain. The fix targets keep-mode (cmd/uninstall.sh preserves the config dir for
re-onboarding); purge-mode `rm -rf` is already clean.

### 3.9 · Rotation, revocation, delivery-awareness

*Revocation honesty, stated verbatim in help/SECURITY.md: a shared secret cannot be cryptographically
revoked or expired offline; the only revocation is rotating it at its provider so the shared copy stops
authenticating.* A pasted bearer copy persists in the recipient's store and the channel's retention — an
exposure the sender cannot walk back — so rotation is the *lever* available when a shared copy must be
killed (NIST SP 800-63B favors rotate-on-compromise over fixed calendars; the 180-day default at
common.sh:21 is a ceiling, not a NIST figure).

*Decision (locked 2026-07-11): do NOT auto-tighten `rotate_by` on share.* Rotation is the only revocation,
but it is a judgment the operator makes when a copy actually needs killing (a holder leaves, a blob leaks) —
not a routine post-share reflex. Auto-nagging a legitimately-shared singleton is noise, and a config item
that is not a credential (an AWS endpoint/hostname, a non-secret connection string) should not be rotated at
all. `share` records the event in the manifest (`shared_with`/`shared_at`/`direction`) so the offboarding
query can answer *"what did I share with X, and is it still live?"*, and leaves the rotation decision to the
operator. The existing doctor/smoke `≤14d` engine (doctor.sh:84 / smoke.sh:60) still fires on whatever
`rotate_by` the secret already carries — the share simply does not move it.

*Decision (hostile-review gap — the orphaned-copy fix): when you DO rotate to revoke, rotate after CONFIRMED
receipt, not the instant you paste.* The sender gets no delivery signal (serverless = no receipt proof).
Rotating before the recipient ran `receive` hands them dead credentials with no signal — and their `doctor`
reports the stale value as present-and-decryptable, because it checks decryptability, not validity
(doctor.sh). So when revocation-by-rotation is the goal: paste → recipient confirms receipt out-of-band →
*then* rotate.

### 3.10 · AI-agent invocation policy (prompt-injection stance)

*Decision: gate `share` — the exfiltration primitive — behind BOTH `agsec_in_agent_session()`
(common.sh:69-76) and an interactive-tty requirement.* The env guard refuses to run inside a Claude Code /
Cursor session; but it reads agent-controllable env vars (`CLAUDECODE`/`CURSOR_*`) and setup.sh:96 shows
`UNATTENDED=1` already bypasses it, so *the env guard is a speed-bump, not a boundary.* The real boundary
for `share` is the same construction `receive` uses: an interactive-tty confirm (`[ -t 0 ]` / read from
`</dev/tty`, hard-refuse if absent). An injected agent with no controlling tty hits that as a hard refuse
even after `env -u CLAUDECODE …` strips the guard. We never describe the env guard as stopping a determined
injected agent.

*Decision: `receive` is NOT env-gated.* Its protection is the `/dev/tty` recipient/collision gate (an agent
with no tty hits a hard-refuse); a hard env-refusal on `receive` would have no working second line (blob on
STDIN) and would push a real human toward the plaintext `age -d`-to-file path this design exists to
prevent.

*Deliberate exclusion — request-then-fulfill initiation.* v0.2 is **sender-push only**. A receiver-pull "I
need SECRET X from you" request flow is excluded: the request itself becomes a social-engineering /
confused-deputy vector (an injected agent emits a plausible request that drives a human to run `share`),
and the design pins its whole agent defense on gating `share`. A pull flow needs its own threat pass before
it ships; leaving it out is a decision, not an oversight.

### 3.11 · Failure modes handled

| Condition | Behavior |
|---|---|
| Per-person-mintable name, no `--singleton` | ladder refuses with the R2 recipe (§6) |
| Non-existent / typo'd NAME on share | fail fast before any confirm |
| Empty or unparseable `.keys` | fail loud → fall back to pasted `age1…` (never zero-recipient encrypt) |
| SSH cert / sk-FIDO2 recipient | reject at input with the reason |
| Unknown envelope version on receive | reject |
| Mangled / corrupted armor | decrypt fails closed; stderr disciplined (no fragment leak) |
| Oversized blob | rejected before decode AND before decrypt (dual caps) |
| Existing-NAME collision | hard-stop confirm from `/dev/tty` (or `--rename`) |
| Canary NAME either direction | hard refuse (no confirm) |
| Multi-line value | base64 / `cat` round-trip, not truncated |
| `share` in an agent session or with no tty | refuse |
| `receive` with no controlling tty | hard-refuse, unless `--yes-i-reviewed` (runs the hard errors, skips only the human confirm — for CI) |
| Unsigned blob | proceed with loud "sender unverified" |
| Benign armor reflow | local digest stable (decoded bytes) |

---

## 4 · Share-flow threat model

The dominant share-flow threat is **not** in-transit tampering. age's header is HMAC-SHA256-authenticated
and its payload is per-chunk ChaCha20-Poly1305 AEAD ([C2SP/age.md](https://github.com/C2SP/C2SP/blob/main/age.md)),
so a bit-flipped blob fails to decrypt. The threats that survive that AEAD are substitution, agent-driven
exfiltration, and a set of metadata leaks the tool's existing names-only rails already bound. Ranked by
likelihood × impact:

| # | Threat | Likelihood | Impact | Why it is real here |
|---|---|---|---|---|
| 1 | **Blob substitution / wrong-key poisoning** | High | High | age deliberately provides no sender authentication — *"age is in the business of integrity and confidentiality, not authentication"* ([filippo.io](https://words.filippo.io/age-authentication/)). Anyone who knows your public key can hand you a blob **they** authored. The share-specific danger: a colleague-supplied blob could carry the **attacker's** `ANTHROPIC_API_KEY`, so the recipient's agent traffic then authenticates to — and is observable/billable by — the attacker (the classic "surreptitious forwarding" pattern, [Davis, USENIX 2001](https://www.usenix.org/legacy/event/usenix01/full_papers/davis/davis_html/)). Ranked High on structural grounds — age has no sender auth — not on a claimed in-the-wild exploit. **The digest readback does NOT catch this** — a substitution attacker computes a valid digest over their own blob trivially; the readback catches only an accidental mismatch, so the sole offline defense against *substitution* is the opt-in `ssh-keygen -Y sign` sidecar. |
| 2 | **AI-agent-invoked `share`/`receive` under prompt injection** | High | High | `share` is a confused-deputy exfiltration primitive: an injected instruction can drive an agent to run `share <SECRET> --to attacker`. This is a 2026-active, cross-vendor class — Anthropic's Claude Code Security Review action, Google's Gemini CLI action, and GitHub's Copilot agent all failed to sanitize attacker-controlled input, with credential exfiltration via `/proc/self/environ` ([CSA research note](https://labs.cloudsecurityalliance.org/research/csa-research-note-claude-code-github-action-prompt-injection/); the Claude Code instance is CVE-2025-66032 / GHSA-xq4m-mc3c-vvg3). Adaptive prompt-injection bypasses state-of-the-art defenses at >85% ([arxiv 2601.17548](https://arxiv.org/abs/2601.17548)); guardrails reduce but do not eliminate it. |
| 3 | **Destructive overwrite on `receive`** (duplicate-NAME / canary collision) | Medium | High | `store_add` upserts silently: `grep -v "^${name}="` drops any existing entry and appends, with no warning or confirm (store.sh:65). A received blob whose NAME collides with a live secret **silently clobbers it**. The canary name `AWS_BACKUP_ACCESS_KEY_ID` (common.sh:20) is fixed and publicly knowable, so a crafted blob can overwrite the tripwire (disabling breach detection) or shadow a real credential. The digest ceremony does not catch this — the digest is of the blob, not of a name-collision consequence. |
| 4 | **Ciphertext-blob harvest-now-decrypt-later (HNDL)** via retained chat | Medium | Medium | An X25519 blob pasted into Slack/Teams sits in server-side retention indefinitely, harvestable for future CRQC (Shor) decryption. HNDL is technically feasible and affordable, and agencies warn adversaries **may already** be stockpiling ciphertext ([arxiv 2603.01091](https://arxiv.org/html/2603.01091v1)). Bounded for this tool: the ≤180-day rotation window (common.sh:21) means the harvested value is likely rotated out before a CRQC exists. This is also the design's single highest-HNDL-exposure choice (retained ciphertext + classical KEM), so the bound matters — and it is why the tightened-`rotate_by` window (§3.9) is set against the tighter of the offboarding and HNDL horizons. |
| 5 | **Clipboard / Universal Clipboard + scrollback metadata leak of the blob** | Medium | Low | The secret **value** never touches the clipboard or scrollback — `ui_read_secret` uses `IFS= read -rs` (ui.sh:43-51), hidden, value to STDOUT for piping. Residual exposure is (a) the **ciphertext** blob a user consciously pastes with Cmd-V, which lands in scrollback/tmux and, if copied, can propagate to a **nearby** device on the same Apple Account when Handoff + Bluetooth + Wi-Fi are on ([Apple 102430](https://support.apple.com/en-us/102430) — proximity/Handoff-gated, not an unconditional fan-out); and (b) setup.sh:35's existing `pbcopy` of the private key, which cannot set `org.nspasteboard.ConcealedType` ([nspasteboard.org](https://nspasteboard.org/)) so it is already leakier than a native copy. |

**Accepted residual risks (honest ceiling, SECURITY.md style):**

- **No cryptographic ephemerality or revocation, ever, offline.** Every comparable one-time/burn guarantee
  is *custodial* — a server deletes the ciphertext it holds (Vault response-wrapping single-use token,
  [HashiCorp](https://developer.hashicorp.com/vault/docs/concepts/response-wrapping); Bitwarden Send
  *"purged from Bitwarden systems"*, [Bitwarden](https://bitwarden.com/help/send-lifespan/); 1Password
  Psst! server-enforced expiry). agent-secrets hands over a bearer copy over a channel it does not control,
  so there is nothing to purge. **The only revocation is rotation at the source** so the shared copy stops
  authenticating. We do not claim recall, expiry, or burn.
- **No delivery proof and no per-access audit.** The sender gets no signal that the recipient ran
  `receive` (see §3.9's rotate-after-confirmed-receipt doctrine, which exists precisely because of this).
  The $0 design records only *share-event* facts the sender already holds at share time (name, recipient
  fingerprint, timestamp), not per-access reads — consistent with SECURITY.md:33-34. A real per-access
  trail requires the paid path (1Password Business Events API).
- **Sender authentication is opt-in, not mandatory.** The offline defense against threat #1 is an
  out-of-band digest readback (accidental-mismatch only, §3.4) plus an optional detached `ssh-keygen -Y
  sign` sidecar. Only the SSH sidecar closes substitution offline, and it depends on a human maintaining an
  `allowed_signers` roster. An unsigned `receive` is trusting whoever pasted the blob, and we say so loudly.
- **The manifest becomes a plaintext social graph.** Recording `shared_with` makes `manifest.toml` a
  values-free but relationship-revealing map — an offboarding target list and a blast-radius map for anyone
  who reads `~/.config/secrets/manifest.toml`. It is metadata, not a value (does not breach names-only),
  but a new local exposure; the field defaults to the opaque fingerprint, label optional. Its survival
  through uninstall keep-mode is an open decision (§10).
- **Parser DoS on a hostile blob is possible but low.** sops has one advisory ever (GHSA-x5c7-x7m2-rhmf,
  Low, Windows-only, 2021); both sops and age are memory-safe Go with strict parsing. The one gap — no
  header-size/stanza-count limit — is neutralized by the dual byte-length caps on the pasted blob
  (§3.7), enforced before decode and before decrypt.

**Additional documented limits (hostile-review, `document-as-limit`):**

- **Paste-fidelity of the `age1…` recipient string** (distinct from armor mangling): a chat client can
  mangle or truncate the pasted recipient into a different-but-still-valid key — a wrong-recipient source at
  the human layer that the confirm only partly catches (the human compares a fingerprint of whatever
  resolved). Cheap fix worth doing: round-trip/checksum the resolved key into the confirm. The `pubkey`
  verb (§3.3) is the mitigation on the emit side.
- **Armor size / paste-length blow-up:** armor adds ~33% + per-recipient stanzas; a github-keys
  multi-recipient blob or a PQ blob (`age1pq1…`, ML-KEM ciphertexts ~1KB+) can be many KB that some chat
  clients truncate or auto-convert to a file attachment — most acute for the PQ path. Paste-safety has a
  size dimension, not just a corruption one.
- **Accessibility of the voice readback:** the mandatory accidental-mismatch floor assumes a synchronous
  voice channel and hearing/speech parity. An async text-fallback for the readback must be a stated
  alternative, not an implicit assumption, so the security floor is not reachable only through one channel.
- **Benign re-send ("I lost the blob"):** a legitimate idempotent re-share collides with the desire not to
  strew repeated ciphertext through retention, and each re-send re-arms the HNDL clock. Stance: re-send
  warns and does not re-tighten `rotate_by` twice; prefer guiding to a fresh share over re-pasting the old
  blob.

---

## 5 · Option matrix

| Option | E2E? | Infra | Key-mgmt burden | Wrong-recipient proofing | Ephemerality | Audit | Recipient setup cost | Verdict |
|---|---|---|---|---|---|---|---|---|
| **Provider-reference / recipient mints own scoped key** (teller/kamal doctrine — the ladder's top rung) | N/A — no value crosses the wire | $0; recipient's own provider | None — recipient mints their own | N/A — nothing transferred; blast radius is the recipient's own scoped key | Provider-native revocation | Provider-side log | Recipient needs provider access to mint | **Prefer first — this IS the last rung; `share` offers it before copying any value** |
| **Raw X25519 armored blob + mandatory out-of-band digest readback** (STDIN in, STDIN out) | Yes — age X25519; only ciphertext + NAME cross the wire | $0, zero-vendor, local — reuses existing keypair + `store_extract` | Low — recipient supplies their `age1…` pubkey | Weak by default (no sender auth) — closed by the digest-readback ceremony (§3.4) | None cryptographically — advisory metadata + rotation | $0 local: manifest `shared_with`/`shared_at`/`direction` | Recipient needs any conformant age + their keypair | **PRIMARY — the only archetype meeting names-only + $0 + async + last-rung together** |
| **Above + detached `ssh-keygen -Y sign` sender-auth sidecar** | Yes (age) + authenticity (SSH sig vs `allowed_signers`) | $0 — OpenSSH ships on macOS | Adds a second (SSH) key + a receiver roster | **Strong** — namespace blocks cross-protocol reuse | Same (advisory + rotation) | Manifest delta + verified signer recorded | Recipient additionally keeps an `allowed_signers` roster | **RECOMMENDED OPT-IN hardening — closes the substitution gap offline** |
| **ssh-recipient blob** (encrypt to `github:<user>.keys`) | Yes, but SSH-recipient blobs embed a public-key tag → linkable | $0 blob; GitHub is optional discovery, never a dependency | Reuses SSH keys colleagues have, but auth keys are revocable/rotation-fragile | Worse — stale/attacker-added `.keys`, homoglyph handles, no TOFU pin; sk-FIDO2 keys silently undecryptable | None | Same manifest delta | Zero-setup upside if they lack an age identity | **SECONDARY / opt-in behind a TOFU pin** — Filippo cautions *"only when a native key is not available"* |
| **Touch-ID / hardware-gated receiver custody** (age-plugin-se / -yubikey) | Yes — plugin changes only the receiver's decrypt identity | $0 server; needs plugin on PATH + Secure-Enclave Mac (-se) or YubiKey (-yubikey) | High assurance — non-exportable key; slots into `SOPS_AGE_KEY_CMD` | Same as base + per-decrypt presence proof | None additional | $0 local; biometric prompt is per-decrypt presence evidence | Higher — install plugin; -se needs the specific Mac | **OPTIONAL receiver hardening — the natural fail-closed custody, not required for share/receive** |
| **Passphrase (scrypt) blob for keyless recipients** (`age -p -a`) | Partial — value protected, but the passphrase is a second secret needing its own channel | $0 | None — no recipient key | N/A crypto-wise; anyone with the passphrase decrypts | None | No key fingerprint to record | Lowest — recipient needs only age + the passphrase | **LAST-RESORT — merely relocates the transfer problem to the passphrase** |
| **Post-quantum hybrid** (recipient mints `age-keygen -pq` → `age -r age1pq1… -a`) | Yes — native v1 X-Wing / MLKEM768-X25519 stanza | $0 — needs a PQ-capable age (v1.3.0+) on both ends | Same as X25519 | Same as base — no sender auth | Mitigates HNDL, not revocation | Same manifest delta | Recipient needs a v1.3.0+ age + a PQ recipient key | **CONDITIONAL — only when a blob will sit in retained chat beyond the ≤180-day window** |
| **Shared-store recipient add** (`sops updatekeys` / pass / gopass) | Yes — multi-recipient re-encrypt | $0 local, but implies a git-synced shared store | Recipient added to `.sops.yaml`; **all** secrets re-encrypted to them | Same no-sender-auth gap + over-grant risk | Remove-recipient + re-encrypt (leaked values already copied) | Git history of recipient changes | Recipient clones/syncs the store + long-lived identity | **REJECT for one-off send — grants standing access to the WHOLE store** |
| **Interactive PAKE transfer** (magic-wormhole / croc short code) | Yes — SPAKE2 session key | Requires a rendezvous **server** | None persistent — ephemeral per-transfer code | Strong — single-use pronounceable code binds both ends | Strong — one-shot, live-session only | None persistent | Recipient online **simultaneously** + tool installed | **REJECT as core mechanism — relay dependency + synchronous-online break $0 and async-paste; keep only the code UX as the friction bar** |
| **Server-mediated one-time link** (Vault-wrap / Bitwarden Send / 1Password Psst!) | Yes (fragment key never hits server) | Requires a **server** to host ciphertext + enforce burn/expiry | Low | Restricted-recipient email/OTP (server-enforced) | Strong — true single-use, server-enforced | Rich server access logs | Zero-install web view — the one genuine advantage | **REJECT as a dependency; steal the *principles* — split-channel key, advisory expiry, self-describing receive** |

---

## 6 · The don't-share ladder (gates the verb)

The `share` verb's **first action is the ladder, not the encryption.** Sharing a value is the last rung: it
is the industry-and-regulation default. Shared credentials break individual accountability and
non-repudiation — HIPAA 45 CFR 164.312(a)(2)(i) mandates a unique per-person identifier and disallows
shared logins, and individual-accountability requirements also appear in PCI-DSS Req 8, NIST 800-171
3.3.2, and 21 CFR Part 11 §11.10 ([TechID](https://techidmanager.com/the-shared-account-problem-how-to-meet-nist-800-171-3-3-2-and-cmmc-traceability-requirements/)).
The whole secrets-management industry converges on *don't move the value; grant identity-scoped access* —
1Password Credential Broker: *"A machine workload or AI agent shouldn't hold credentials it doesn't
currently need. It should prove who it is, get exactly what policy allows, and lose that access when its
job is done"* ([1Password](https://1password.com/blog/introducing-1password-credential-broker)).
Over-strictness is a real hazard, though: Slack-paste friction is ~zero, so a bare block pushes the user
straight back to the leaky channel. Every rung therefore **educates and redirects with a provider-specific
recipe**, and only the terminal rung permits the blob.

**Rung order (refuse at each until ruled out):**

- **R0 — Self-share bypass.** If the recipient is the sender's own second machine (`--to self`), the ladder
  is moot: there is no third identity to mint for. Skip R1–R3, go straight to transfer, and do **not**
  tighten `rotate_by` or record the offboarding row. *Why: a self-share exposes nothing to a third party.*
- **R1 — Keyless / federated.** *"Can this provider issue short-lived creds so no secret need exist at
  all?"* GitHub Actions OIDC → cloud WIF *"[removes] the need to export a long-lived JSON service account
  key"* ([Google Cloud](https://cloud.google.com/blog/products/identity-security/enabling-keyless-authentication-from-github-actions)).
  AWS: humans federate via IAM Identity Center; workloads use IAM roles — *"there is no need to distribute
  long lived credentials"* ([AWS](https://docs.aws.amazon.com/IAM/latest/UserGuide/best-practices.html)).
- **R2 — Recipient mints their own per-person scoped key.** Every provider the repo names supports this:
  Anthropic Workspace Developer / Limited Developer roles both *"Create and manage API keys"*
  ([Anthropic](https://platform.claude.com/docs/en/manage-claude/workspaces)); OpenAI project-scoped keys;
  GitHub fine-grained PATs; AWS per-user via Identity Center. Probe the *can't-be-invited* branch too — an
  outside contractor can often be added as an
  [outside collaborator](https://docs.github.com/en/organizations/managing-user-access-to-your-organizations-repositories/managing-outside-collaborators/adding-outside-collaborators-to-repositories-in-your-organization)
  before any value is copied. *Hidden precondition (hostile-review):* "recipient mints their own" at
  Anthropic requires an **org admin to invite first**, so R2's real availability to the *sharer* is often
  false — the rung copy must own that, not assume the recipient can self-serve.
- **R3 — True-singleton confirmation.** Sharing is legitimate only for secrets that **cannot** be
  per-person minted: (1) *symmetric-by-construction* — webhook signing / HMAC secrets are *"a single shared
  secret per webhook endpoint"*, per-user keying is cryptographically meaningless
  ([webhooks.fyi](https://webhooks.fyi/security/hmac)); (2) *account-level-only SaaS keys*. **Also route
  intentionally-shared machine/service identities here** (bot users, CI service accounts) — they are
  neither per-person nor account-singletons and must be acknowledged explicitly, not silently allowed.
  *(This sub-rung answers the hostile-review "service-account rung missing" gap.)*
- **R4 — Terminal.** Only after R1–R3 are ruled out (or R3 acknowledged) does `share` produce the blob. If
  R1/R2 are impossible and it is **not** a clean singleton, `share` still proceeds — *legitimate-but-no-
  clean-rung* — with maximal ceremony (mandatory digest readback + tightened rotation), never an infinite
  refuse loop. *(This positive terminal branch answers the hostile-review "all-refusal ladder" gap: the
  dead-end is exactly what would drive users back to Slack-paste.)*

**Provider reality (built-in advisory table, KNOWINGLY-STALE):**

| Provider | Per-person key? | Keyless option | Per-person **revocation** | Ladder verdict |
|---|---|---|---|---|
| Anthropic | Yes (Workspace Developer / Limited Developer) | — | **Only** Claude Code workspace keys stop working when the owner is removed; standard workspace keys persist ([Anthropic FAQ](https://platform.claude.com/docs/en/manage-claude/workspaces)). Coarse kill-switch: archiving a workspace revokes all its keys. | Mint per-person; if revocation matters, use a Claude Code key or a disposable per-share workspace |
| OpenAI | Yes (project-scoped) | — | Delete the project key | Mint per-person |
| AWS | Yes (IAM Identity Center) | Yes (roles / federation) | Deactivate the user's key/role | R1 keyless, else per-person |
| GitHub | Yes (fine-grained PAT) | Yes (Actions OIDC) | Revoke the PAT | R1/R2 |
| Webhook / HMAC secret | **No** — symmetric | — | Rotate the shared secret | **True singleton → R3** |
| Unknown provider | Assume mintable | Assume possible | Unknown | **Do not silently allow — require the operator to confirm they checked** |

Because a $0/zero-vendor design forbids any network dependency, this table can never be an authority — it is
an **advisory prompt** that a hardcoded, knowingly-stale build ships, backed by a mandatory *"confirm you
checked the provider yourself"* human step. That is the constraint-forced ceiling, not a gap to close.

**Exact rung copy (R2 refusal, Anthropic example):**
```
This looks like a per-person key. Before you share a value, the recipient should
mint their own — it's individually attributable and independently revocable.

  Anthropic:  console → Settings → Members → invite them (needs an org admin),
              then they create their own key (Workspace Developer role).

Sharing a value is the last resort. If they truly can't mint their own, re-run:
  agent-secrets share ANTHROPIC_API_KEY --to <recipient> --singleton
```

---

## 7 · Rejected alternatives

- **Shared-store recipient add (`sops updatekeys` / pass / gopass model).** *Killed by scope:* grants the
  recipient standing decrypt access to the **entire** store, not the one shared value — a team-store
  pattern, not a point-to-point send.
- **Interactive PAKE transfer (magic-wormhole / croc).** *Killed by two independent constraints:* requires
  a live rendezvous server (violates $0/zero-vendor) **and** both parties online simultaneously (breaks the
  async paste-to-chat workflow). Only the human-pronounceable-code UX is worth borrowing.
- **Server-mediated one-time link (Vault-wrap / Bitwarden Send / 1Password Psst!).** *Killed by the server
  dependency:* every ephemerality guarantee is custodial. Steal the *principles* (advisory expiry,
  split-channel key, self-describing receive), not the mechanism.
- **Burn-after-read / one-time links as the primary flow.** *Killed twice over:* unenforceable offline
  **and** consumed by chat unfurl bots before the human reads them — Slack server-side crawls (GETs) every
  URL posted ([Slack docs](https://docs.slack.dev/messaging/unfurling-links-in-messages/)), so a one-time
  link is burned by the bot first.
- **sk-FIDO2 hardware SSH keys as recipients.** *Killed by the protocol:* FIDO2 exposes only an
  authentication API, not the scalar-mult age needs — *"likely not possible to ever support these kinds of
  hardware keys"* ([str4d](https://github.com/FiloSottile/age/discussions/360)). Hardware custody comes via
  PIV/Secure-Enclave *plugins* instead.
- **WKD (email → PGP discovery).** *Killed by wrong key type + hosting dependency:* serves PGP, not age,
  and requires email-domain hosting of `.well-known/openpgpkey/` — GitHub `.keys` covers the
  discover-by-identity need at lower cost.
- **Mandatory sender signature (fail-closed on every unsigned blob).** *Killed by adoption friction:*
  blocks users without an SSH key and adds an `allowed_signers`-roster ceremony to every receive. The
  advisory digest readback (accidental-mismatch only) is the cheap default check; the SSH sidecar — the
  actual substitution defense — stays opt-in. *(Locked 2026-07-11: opt-in only, no secret class is
  fail-closed — §3.4, §10.)*
- **Mandatory hybrid PQ on every share.** *Killed by disproportion:* the ≤180-day rotation window already
  bounds HNDL exposure; PQ adds a v1.3.0+ age requirement on both ends for a threat rotation already caps.
  Reserve `-pq` for blobs known to sit in retained chat beyond the window.
- **A network-fetched provider capability table.** *Killed by the zero-network invariant:* any freshness
  mechanism is a network dependency the design forbids. A hardcoded, knowingly-stale table + a "confirm you
  checked" human step is the honest ceiling.
- **Digest readback as a substitution / tamper-evidence check.** *Killed by the adversary model:* the
  envelope digest binds ciphertext the **sender** chose, so a substitution attacker computes a matching
  digest over their own blob trivially. Kept only as the accidental-mismatch floor (over decoded bytes,
  recomputed locally); substitution is closed solely by the opt-in `ssh-keygen -Y sign` sidecar.
- **Reading the receive-side confirm from STDIN (like `store_add`'s value read).** *Killed by STDIN
  exhaustion:* the blob occupies STDIN, so a confirm read via `read -r` gets empty input and silently takes
  its default. The confirm reads from `</dev/tty` instead, hard-refusing when no tty exists.
- **Gating `receive` behind the `agsec_in_agent_session` env guard.** *Killed by no-fallback + a worse
  escape:* the guard is env-only and design-conceded bypassable, and on `receive` (blob on STDIN) there is
  no second line if bypassed; a hard env-refusal would push a human to the plaintext `age -d`-to-file path.
  `receive`'s protection is the `/dev/tty` gate; the env guard stays on `share`.
- **`age -R -` for the github-keys path.** *Killed by a STDIN collision:* `age -R -` reads recipients from
  STDIN, which the piped plaintext also uses. Fetch `.keys` to a `0600` temp file and use `age -R <file>`.
- **`export`/`import` verb names.** *Killed by connotation:* they imply a bulk plaintext dump. `share` /
  `receive` are plain-imperative and match the existing `add`/`list`/`run`/`doctor` idiom (help.sh:12).

---

## 8 · v0.2 implementation notes

**Files to touch (repo conventions from §2):**
- `bin/agent-secrets` (dispatcher) — routes `$AGENT_SECRETS_CMD/<verb>.sh`; `share`/`receive`/`pubkey` are
  new `cmd/*.sh` files, so no dispatcher edit beyond confirming they resolve (unknown → exit 2 already).
- `lib/help.sh` — add `share receive pubkey` to `AGSEC_VERBS` (help.sh:12); add help spec rows so `help
  --json` renders them. The reserved-verb line is `rotate, demo` (help.sh:122).
- **Ladder gate is NET-NEW code.** `R0–R4`, `--singleton`, `--self`, and the provider advisory table exist
  nowhere in `lib/`/`cmd/` (verified: grep hits nothing). Build them in `cmd/share.sh` (+ a shared helper
  if `receive`'s `--self` path needs it). Do not describe it as "mirrors setup's gate" — setup gates on
  `agsec_in_agent_session`, unrelated to R0–R4.
- `cmd/share.sh` — order: `agsec_in_agent_session` refuse **+ interactive-tty requirement** (§3.10) → build
  + run ladder gate (R0–R4) → name-exists check → resolve recipient (`age1…` / `github:.keys` **to a 0600
  temp file, `age -R <file>`, never `-R -`** / `self`) + contacts-roster pin + cert/sk-FIDO2 reject →
  polymorphic confirm from `</dev/tty` → `store_extract "$NAME" | age -r "$recip" -a` → wrap in envelope +
  code fence (digest over base64-DECODED ciphertext) → new in-place manifest writer → tighten `rotate_by`.
  Optional `--sign` → `ssh-keygen -Y sign -n share-v1@<domain>`.
- `cmd/receive.sh` — order: **read every confirm/re-prompt from `</dev/tty`, hard-refuse if no tty — NOT
  the env guard** → STDIN ingest of the blob (mirror restore.sh:21-25's `[ -t 0 ]`→`ui_read_secret` / else
  `cat`) → **dual byte caps** (raw envelope before decode, decoded ciphertext before decrypt) → parse +
  version-check envelope → recompute digest over base64-DECODED ciphertext **locally** + display for voice
  compare (embedded `digest:` is a hint only) → optional `ssh-keygen -Y verify` vs `allowed_signers` (loud
  warn if unsigned) → canary-name refuse (hard error, no confirm) → existing-NAME hard-stop confirm **from
  `/dev/tty`** → pipe `age -d` **directly into** the multi-line-safe 0600-temp store writer (value never in
  a shell var/argv) with **stderr disciplined (`2>/dev/null` + curated fail-closed message)** → record
  `direction=received`, `source=received:<label>`.
- `cmd/pubkey.sh` — NEW verb (hostile-review gap): print `agsec_age_pub_file` contents + `agsec_digest`
  fingerprint (+ `--copy`). Public key, so stdout/argv/clipboard are safe. This is the recipient's on-ramp
  for the empty-`.keys` fallback and the trust-ceremony pin.
- `lib/store.sh` — add a dedicated in-place manifest **row-updater** for
  `shared_with`/`shared_at`/`direction`/`source` (do NOT extend `_store_manifest_upsert`, skip-if-exists at
  store.sh:79). Add a multi-line-safe value path for `receive` that pipes STDIN straight into the 0600-temp
  writer (a `cat`-based variant like `kc_add`'s at keychain.sh:16, or a base64 round-trip), because
  `store_add`'s `IFS= read -r value` (store.sh:60) truncates at the first newline. Keep the value out of any
  shell variable and out of argv.
- `lib/common.sh` — add `AGSEC_SHARE_ENVELOPE_VERSION="v1"`; reuse `agsec_digest` (common.sh:61) for the
  readback but document its 48-bit width and that it is fed the **base64-decoded ciphertext bytes**, not the
  armored text (the caller does the `base64 -D | agsec_digest` decode).

**Test plan (bats under synthetic `AGENT_SECRETS_HOME` + `mocks/`, `setup_store` helper):**
- Mocks: `security`, `pbcopy`, `gh`, plus a `curl` stub for `github.com/<user>.keys` (valid key; empty;
  auth-only/YubiKey key), an `ssh-keygen` stub for `-Y sign`/`-Y verify`, and an argv-inspection assertion
  (the value must never appear in argv — croc's CVE-2023-43621 is the direct proof).
- share: ladder refuses a per-person-mintable name without `--singleton`; `--self` takes R0 (no
  rotate-tighten, no offboarding row); recipient confirm required; blob code-fenced; envelope carries
  `name`/`direction`/`digest`; digest stable across a benign armor reflow; `store_extract | age -r` (not
  `sops -e`); `.keys` written to a temp file + empty-`.keys` fails loud; manifest row via the new updater;
  `rotate_by` tightened; refuses inside a simulated agent session (`CLAUDECODE=1`) **and** with no tty.
- receive: round-trips end-to-end with the blob **piped on STDIN while the confirm is answered on a PTY**
  (assert honored, not defaulted); **hard-refuses with no tty**; **rejects an unknown envelope version**;
  **hard-stops on an existing NAME**; **refuses the canary name** (hard error); **multi-line value survives**
  (PEM/JSON/cert); value never in argv or a logged shell var; **oversized blob rejected before decode AND
  before decrypt**; unsigned blob prints the loud unverified warning; **decrypt-error stderr carries no
  fragment**; locally-recomputed digest is displayed.
- Cross-cutting: `help --json` includes all three verbs; value never reaches stdout/argv/scrollback;
  `pubkey` emits the recipient string + fingerprint and is safe in an agent session.

**Docs wiring:**
- `README.md` — add `share`/`receive`/`pubkey` to the command list; state ladder-first + "sharing is the
  last rung" (extends README:46-49).
- `AGENTS.md` — add `share` to the human-gated (agent-session-refused) set alongside setup/uninstall
  (golden-rule-5); note that `receive` is instead tty-gated (refuses with no controlling terminal) and why.
- `SECURITY.md` — add a "Sharing" subsection in the honest-ceiling voice: no offline
  revocation/ephemerality (rotation is the only revocation), sender-auth opt-in (unsigned = trusting the
  paster; the digest readback catches accidental mismatch only, NOT substitution), no delivery proof, the
  manifest social-graph caveat, and the canary-refusal guarantee.
- FAQ — "How do I send a secret to a colleague?" → ladder first, then the paste-a-fenced-blob flow; "Why
  can't I recall a shared secret?" → rotate it; "The recipient has no agent-secrets" → install-then-
  `receive`, never `age -d` to a file.

---

## 9 · Corrections the research forced on the original §3 hypothesis

The §1 problem framing and the §2 repo-rails survey stand as first written. The prior §3 hypothesis held in
shape but the corpus corrected four specifics — recorded here because the *why* is the learning:

1. **The share mechanic is `store_extract | age -r`, not `sops -e`.** §3 (and §2's proposal note) leaned on
   the store rails, but re-encrypting via `sops -e` re-encrypts the **whole** store (store.sh:69). A
   single-value share encrypts one extracted value to one external recipient and must **not** add the
   recipient to `.sops.yaml`.
2. **The `agsec_digest` readback was under-specified AND mis-scoped as tamper-evidence.** It is a **48-bit**
   truncation (common.sh:61) — fine for an accidental-mismatch human readback, but **not** a
   content-addressed identifier and **not** a substitution defense (a substitution attacker recomputes a
   matching digest over their own blob; only the opt-in `ssh-keygen -Y sign` sidecar closes substitution).
   It must be computed over the **base64-decoded ciphertext bytes** (hashing the armored text false-alarms
   on a benign reflow) and **recomputed locally on receive**, never read from the embedded envelope line.
3. **The post-quantum note misattributed the flag.** PQ is not an `age -pq` share flag; the recipient mints
   `age-keygen -pq` (recipient `age1pq1…`, age v1.3.0+) and the sender uses ordinary `age -r age1pq1… -a`.
4. **"Duplicate-NAME overwrite unresolved" is now resolved, and three defects were new.** `store_add`
   clobbers silently (store.sh:65) → `receive` must hard-stop-confirm on an existing NAME. New: `store_add`'s
   single-line read (store.sh:60) **truncates multi-line values** at the first newline; every receive-side
   confirm must read from `</dev/tty` because the blob **exhausts STDIN** (ui.sh:23) and would silently
   default the gate; the canary-collision resolves to a **hard refuse** both directions (an error, not a
   confirm, so STDIN exhaustion cannot bypass it).

---

## 10 · Open questions (maintainer's call)

**Resolved 2026-07-11 (user decisions — the rationale is folded into §3):**

| Decision | Resolution | Why |
|---|---|---|
| Digest readback | **Advisory by default** (§3.4, §3.6) | Shown every share; compared over a second channel only under `--verify` or for a flagged secret. Unlocks the one-command sender path; the readback only ever caught an *accidental* mismatch. |
| `rotate_by` on share | **No auto-tighten** (§3.9) | Record the share; leave rotation to the operator's judgment (revoke a copy only when it needs killing). No nagging on legitimate long-term shares. |
| Sender signature | **Opt-in only** (§3.4) | `--sign` optional; unsigned `receive` proceeds with a loud "sender unverified" warning. No secret class is fail-closed. |
| No-tty `receive` | **Documented `--yes-i-reviewed` escape** (§3.7, §3.10) | Enables CI/non-interactive receive; still runs the canary/collision hard errors, only skips the human confirm. |
| `--to self` | **Auto-inferred** (§3.7) | Inferred when the resolved recipient equals the local `age.pub`; the explicit flag still works. |
| Manifest social-graph | **Fingerprint-only + purged in keep-mode** (§3.8) | `shared_with` defaults to the opaque fingerprint (label opt-in); the roster is purged even in uninstall keep-mode. |

**Still open:**

- **Fenced-armor survivability across the team's actual channels** — the one test no agent can run. Fenced
  blocks fix Slack; Teams/email/mobile are untested. (The decoded-bytes digest tolerates a *benign* reflow,
  but a channel that drops/rewrites characters still breaks *decryption*.) *Settle by:* an empirical
  paste-round-trip through the real channels; if any corrupts, mandate a `.age` file attachment there or
  fail-loud on receive-decrypt.
- **(Research, at build time — before shipping the `--sign` sidecar)** Review saltpack/PGP signcryption
  prior art. Keybase/saltpack deliberately integrated the sender-authentication age omits, and is
  serverless-paste-friendly; reviewing it (and PGP's armored-message + CRC framing) either validates the
  detached-sidecar choice or shows that an integrated signcryption envelope avoids the "two artifacts,
  verify-order matters" fragility the sidecar carries.
- **(Research, at build time — before presenting PQ as first-class)** Verify typage/rage PQ interop.
  Byte-parity was confirmed for rage classical but not for typage, and PQ (`age1pq1…`) parity across
  rage/typage is unestablished — so offering the PQ path silently narrows "any conformant age decrypts it"
  to v1.3.0+-PQ-capable builds only.

---

## 11 · Provenance & methodology

This document is the INTEGRATE of an all-Opus Dynamic Workflow (2026-07-11): axes B–I fanned out as
frontier-tier research agents, each piped through an independent adversarial verify (default-to-refute),
then synthesis → a red-team pass with one repair round → a hostile-completeness review. 21 agents, all
pinned to Opus; §1–§2 were preserved, §3 replaced the hypothesis, §4–§8 are new.

- **Red-team outcome:** `SURVIVES_WITH_CHANGES`. Two fatals from the first pass were repaired inside the
  workflow (the `/dev/tty` confirm; the decoded-bytes digest). Five recheck required-changes are folded
  into §3/§8 here: local digest recompute-and-display, `.keys`→temp-file recipients (never `age -R -`),
  the share tty-confirm as the real boundary (env guard = speed-bump), the canary refusal living in the
  verbs (not `store_add`, which still seeds it), and dual byte caps before decode and before decrypt.
- **Hostile review outcome:** `GAPS_NAMED`, 17 dimensions. The `design-now` gaps are absorbed into the
  design (the `pubkey` verb; wrong-secret selection; delivery-aware rotation; `.keys` set-widening; SSH-cert
  rejection; decrypt-stderr discipline; the machine-identity R3 sub-rung and R4 terminal branch; uninstall
  keep-mode; HNDL/`rotate_by` unification). The `document-as-limit` gaps are in §4; the two `research` gaps
  are in §10. Two apparent gaps (service-account rung, all-refusal ladder) were **false** — already handled
  in §6, which the reviewer did not see.

**Methodology learnings worth keeping** (why the *first* attempt failed, so the pattern isn't repeated):

1. **Fable 5 safety-block.** The prior lead ran on Fable 5, whose dual-use safety classifier flags
   cybersecurity topics wholesale (*"may flag safe, normal content as well"*). Secret-sharing crypto design
   **is** cybersecurity content, so every Fable lead turn and both Fable-pinned subagents returned `can't
   respond with Fable 5` — a model-level block, not a false positive to reword around. → Run this class of
   work on **Opus 4.8** (or Mythos 5 for approved orgs). Fable stays fine for the *implementation* tasks
   (writing `cmd/share.sh`, tests, help/diagram wiring), which read as ordinary software engineering — how
   the rest of agent-secrets was built.
2. **Mailbox race.** The first attempt spawned research as async teammates; briefs raced the mailbox and
   workers idled empty. → A **Dynamic Workflow** passes prompts inline (no mailbox), pins the model
   per-agent deterministically, and returns schema-validated output — which is how this run completed.
