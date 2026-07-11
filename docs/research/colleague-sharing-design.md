# Colleague-to-colleague secret sharing — design research

> **STATUS — IN PROGRESS (scaffold + partial findings), 2026-07-11.**
> Complete and reusable: the problem/threat-model framing (§1) and the repo-rails survey (§2).
> **Not** done: the multi-axis design research and the recommended-design synthesis — §3 is an
> *unvalidated hypothesis*, §4 is the *plan*. The fan-out was blocked before it produced findings
> (§5). Resume on Opus 4.8 per §6. Do not read §3 as a decision.

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

## 3 · Leading candidate — HYPOTHESIS, not yet validated

`agent-secrets share <NAME> --to <age-pubkey | github:user>` → **age-armored ciphertext blob** → paste
over any existing channel → recipient `agent-secrets receive` pastes the blob → decrypts via their
Keychain-custodied age key → value written straight into their store, **never displayed**.

Attractive because it reuses the existing age rails (every install has an X25519 keypair; `.sops.yaml`
already takes multiple recipients) and preserves names-only (only ciphertext + names cross the wire).
This was the candidate **queued for adversarial validation** — the following are **OPEN questions, not
settled findings**:

- **Key discovery / trust:** GitHub `/<user>.keys` (stale or attacker-added keys, homoglyph usernames,
  and a zero-vendor tension) vs a local TOFU `contacts` roster (cached pubkeys + first-seen dates) vs a
  committed `.sops.yaml` team registry. Which minimal ceremony actually prevents wrong-recipient sends?
- **No sender authentication in age** → blob substitution / poisoning: an attacker hands you *their*
  `ANTHROPIC_API_KEY`, so your agent's traffic bills/exfiltrates to their account. Mitigations
  (out-of-band `agsec_digest` readback, an `ssh-keygen -Y sign` sidecar, or a PAKE channel) are
  **usability-unproven**.
- **Ephemerality / revocation are not cryptographically achievable offline** — likely degrade to
  advisory metadata + **rotation** (manifest `shared_with`, tightened `rotate_by`) as the real
  revocation. Confirm against Vault response-wrapping / Bitwarden Send semantics.
- **Post-quantum:** X25519 blobs sitting in retained chat = harvest-now-decrypt-later exposure, to be
  weighed against ≤180-day rotation windows.
- **Don't-share-first ladder** must gate the verb (can the recipient mint their own scoped key at the
  provider?). Sharing is the last rung.
- **Recipient with no agent-secrets installed**, multi-line/PEM values, duplicate-NAME overwrite of an
  existing secret, canary-name collision, and the AI-agent-invocation risk (a coding agent driving
  `share` under prompt injection) are all unresolved.

---

## 4 · Research plan — the 11-axis decomposition (roadmap, not findings)

Critic-reviewed (REVISE applied: merged transfer-channels, promoted post-share-lifecycle + multi-machine
self-share). Axis A (§2) is done. Run B–I as research agents, J–K adversarial. **All on Opus.**

- **B · age crypto mechanics** — X25519 vs ssh-recipients (sk-FIDO2/cert gaps), `-R`, multi-recipient,
  `-a` armor paste-safety, ciphertext-header metadata, scrypt fallback, age-plugin-se/-yubikey
  receive-side Touch-ID gating + `SOPS_AGE_KEY_CMD` composability, rage/typage parity, v1 spec stability.
- **C · key discovery & trust** — GitHub `.keys`, TOFU vs fingerprint ceremony, `.sops.yaml`/contacts
  roster, wrong-recipient proofing (human-comparable fingerprints), **multi-machine self-share**, WKD.
- **D · transfer-channel patterns** — 1Password share links, Vault response-wrapping (tamper-evidence),
  Bitwarden Send `#`-fragment, burn-after-read + the unfurl-consumes-one-time-link failure, PAKE
  (wormhole/croc); what survives serverless.
- **E · post-share lifecycle** — rotation-after-share doctrine, exact manifest delta, revocation honesty,
  $0 local audit trail, canary interplay (refuse canary name?), offboarding query.
- **F · don't-share decision ladder** — per-person minting by provider, true-singleton secrets, ladder copy.
- **G · share-flow threat model** — clipboard/Universal Clipboard, scrollback/tmux, HNDL/PQ, blob
  substitution, parser surface; ranked top-5 + accept-and-document.
- **H · human factors** — friction vs Slack-paste, confirmation fatigue, armor-in-chat formatting,
  request-then-fulfill initiation, zero-setup recipient, verb naming.
- **I · CLI prior art** — pass/gopass, keybase/saltpack, sops updatekeys, gh secret sealed-box,
  croc/wormhole, kamal/chezmoi/teller/dotenvx — steal/avoid table.
- **J · red-team the candidate** (≤500-token verdict). **K · hostile-review the investigation** (≤500).

Deliverable to produce once run: threat model (§1 seeds it) · option matrix (Option | E2E? | Infra |
Key-mgmt burden | Wrong-recipient proofing | Ephemerality | Audit | Recipient setup cost | Verdict) ·
validated `share`/`receive` design · rejected alternatives · v0.2 implementation notes.

---

## 5 · Why the fan-out didn't complete — methodology finding (REAL)

Two compounding failures, both instructive and worth keeping:

1. **Fable 5 safety-block.** The lead session ran on Fable 5, whose dual-use safety classifier flags
   cybersecurity topics wholesale (its own notice: *"may flag safe, normal content as well"*). Every
   lead turn and both Fable-pinned subagents returned `can't respond with Fable 5`. Secret-sharing
   crypto design **is** cybersecurity content, so it trips the filter regardless of the legitimate,
   defensive intent — a model-level block, not configurable, and not a false positive to be reworded
   around. → Run this class of work on **Opus 4.8** (or **Mythos 5** for approved orgs — the "Fable
   model without those measures" path by design). Keep **Fable** for the ordinary-engineering
   implementation tasks (writing `cmd/share.sh`, tests, help/diagram wiring), which read as software
   engineering and don't trip the filter — exactly how the rest of agent-secrets was built.
2. **Mailbox race.** The research agents were spawned as async teammates; briefs raced the mailbox and
   workers idled empty. → Re-run as a **Dynamic Workflow**: `agent()` passes prompts inline (no
   mailbox), pins the model per-agent deterministically, and returns schema-validated output.

Only the two in-process agents survived: Axis A (Explore/Haiku, §2) and the decomposition critic.

---

## 6 · How to resume

- **Approach:** author + run ONE **all-Opus Dynamic Workflow** — fan out axes B–I (Opus, FINDINGS
  schema) → `pipeline()` each through an Opus adversarial verify → synthesize into this file
  (**INTEGRATE**, don't overwrite §1–§2; fill §3 with a *validated* design + the §4 deliverable list).
- **Staged brief** (frozen scope, deliverable spec, full decomposition, repo-rails manifest, Workflow
  shape, constraints): `/tmp/secret-sharing-brief.md` — disposable; regenerate from §2–§4 if pruned.
- **Constraints:** names-only; $0 zero-vendor; sharing is the last rung; **every workflow agent
  `model:'opus'`** (never fable — blocked; never sonnet). Product+Architectural scope only.
