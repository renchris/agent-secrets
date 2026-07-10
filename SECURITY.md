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

## Custody and recovery

The bootstrap age key is custodied in the login Keychain (primary) with a `0600` FileVault-backed
file fallback, behind one selector script. If a macOS upgrade breaks the Keychain path, custody
degrades to the file automatically — tracked by `doctor`, not an outage. Rotate the key every
180 days (tracked by a `rotate_by` row and the weekly smoke job). Your **recovery key** (a second
age recipient saved offline during setup) is what makes a full-machine restore possible — the setup
wizard's restore branch and the documented restore drill verify it.

## Reporting a vulnerability

Please report privately (open a **draft security advisory** on the repository, or email the
maintainer) rather than a public issue. **Redact first:** never paste a real secret value, secret
name set, username, hostname, or path. Run `agent-secrets doctor --redact` and share that output —
it is designed to be safe to paste.
