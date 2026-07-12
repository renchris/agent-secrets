# Security model

This document states plainly what `agent-secrets` protects, what it does **not**, and how to report
a problem.

## The names-only guarantee

The tool is built so a secret **value** is never displayed, logged, or written in plaintext outside
the encrypted store. `list` and `doctor` print only names and status. A value crosses a boundary in
exactly two sanctioned places — injected into a launched process's environment (`run`, the wrappers)
and returned to Claude Code's `apiKeyHelper` on demand — and never to a terminal or a log.

## What it protects you from

- **Plaintext sprawl** — one sops+age–encrypted store instead of scattered `.env` files.
- **Secrets in transcripts** — `~/.claude/projects/**/*.jsonl` is treated as secret-bearing; values
  are injected into processes, never echoed, so they don't land there. Retention is kept short.
- **Ambient exposure** — no `launchctl setenv`, no session-wide exports. Injection is per-launch,
  process-scoped, and dies with the process tree.
- **At-rest theft** — the store is encrypted; the age key sits in the login Keychain on a FileVault
  volume, with a `0600` file fallback for resilience against Keychain regressions.

## The honest ceiling (what it does NOT do)

- **All-or-nothing blast radius.** Anything running as your user that can read the age key can
  decrypt the entire store — the same ceiling a password-manager vault has. Per-secret isolation is
  not provided.
- **Same-machine supply chain.** A malicious `postinstall` script in a dependency runs *as you*,
  inside the trust boundary. The design mandates `ignore-scripts` and sandboxed installs to bound
  this, and the canary to detect a whole-store sweep — but a package that survives to runtime still
  executes with the injected environment. This is bounded and detected, not eliminated.
- **No free-tier audit trail.** The $0 design has no per-access log. Detection rests on the in-store
  canary, firewall egress logs, and short key-rotation windows. A real audit trail requires the
  paid upgrade path (1Password Business Events API).
- **Exfiltration via an allowed host.** Network-egress limits bound where a compromised agent can
  send data, but cannot stop exfiltration through a host the agent legitimately needs. This is why
  detection (the canary) is paired with the bound.

## Detection: the in-store canary

The store includes one plausibly-named decoy secret (a [canarytokens.org](https://canarytokens.org)
honeytoken). Any process that decrypts the whole store and *uses* what it found trips an
out-of-band alert. It is listed in the manifest among the real entries on purpose, so a
manifest-guided exfiltration loop grabs it first.

## Sharing (`share` / `receive` / `pubkey`)

Sending a secret to a colleague inherits the same honest-ceiling discipline — here is exactly what it
does **not** buy you:

- **No offline revocation or ephemerality.** A `share` blob is `age`-encrypted to the recipient's key;
  once they `receive` it, they hold a durable copy. Nothing in this tool can reach out and unshare it.
  **Rotating the secret at the provider is the only revocation** — the shared copy simply stops
  authenticating. There is no expiry, no "burn after reading."
- **Sender authentication is opt-in.** A plain blob proves *nothing* about who produced it — an
  unsigned `receive` is trusting whoever pasted the text. The digest read-back you confirm on
  `receive` catches an **accidental** paste/transport mismatch only; it can **never** catch
  substitution — an attacker who swaps the blob swaps the digest with it. Use `share --sign` (and
  verify against `allowed_signers`) when the sender's identity actually matters.
- **No delivery proof.** The tool cannot tell you the blob arrived, was received once, or was received
  by the intended person. Delivery and its confidentiality in transit are the paste channel's problem.
- **The manifest becomes a values-free social graph.** `share`/`receive` record a `shared_with` /
  `source` **fingerprint** (never a value) plus a direction and timestamp. That leaks *relationships* —
  who you shared which named secret with — even though it never leaks the secret. It is purged with the
  rest of the manifest on `uninstall`, **including keep-mode** (the store may be kept; the relationship
  graph is not).
- **The canary is hard-refused in both verbs.** You cannot `share` the decoy honeytoken and a `receive`
  cannot overwrite or import it — a hard error, never a confirm-through — so the detection guarantee
  can't be defeated or defused through the sharing path.

## Custody and recovery

The bootstrap age key is custodied in the login Keychain (primary) with a `0600` FileVault-backed
file fallback, behind one selector script. If a macOS upgrade breaks the Keychain path, custody
degrades to the file automatically — tracked by `doctor`, not an outage. Rotate the key every
180 days (tracked by a `rotate_by` row and the weekly smoke job). Your **recovery key** (a second
age recipient saved offline during setup) is what makes a full-machine restore possible — the
`agent-secrets setup --restore` path (paste the saved key over a restored store copy) and the
documented restore drill verify it.

## Reporting a vulnerability

Please report privately (open a **draft security advisory** on the repository, or email the
maintainer) rather than a public issue. **Redact first:** never paste a real secret value, secret
name set, username, hostname, or path. Run `agent-secrets doctor --redact` and share that output —
it is designed to be safe to paste.
