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
- **Toolchain provenance (no-Homebrew install).** When neither Homebrew nor an existing copy is
  present, the installer downloads `age`, `sops`, `gum`, and `jq` as static binaries and verifies each
  against a **SHA-256 digest pinned in `lib/deps.sh`** (fail-closed — a mismatch aborts, and a custom
  `AGENT_SECRETS_DEPS_BASE_URL` mirror cannot substitute a different binary because the pin, not the
  mirror's own checksum file, is the check). Honest ceiling: those pins are the maintainer's assertion
  of the correct bytes. `sops`/`gum`/`jq` publish upstream checksums (and cosign/attestation) the pins
  were cross-checked against; **`age` publishes no signed checksums**, so its pin is trust-on-first-pin.
  A downloaded unsigned Go binary runs because `curl` sets no `com.apple.quarantine` xattr (Gatekeeper
  is never consulted); a binary-allowlisting agent (Santa/EDR lockdown) will block it — as it would a
  Homebrew bottle — and the installer fails loud rather than working around it.
- **No free-tier audit trail.** The $0 design has no per-access log. Detection rests on the in-store
  canary, firewall egress logs, and short key-rotation windows. A real audit trail requires the
  paid upgrade path (1Password Business Events API).
- **Exfiltration via an allowed host.** The egress allowlist (below) and any system-wide firewall
  bound where a compromised agent can send data, but cannot stop exfiltration through a host the agent
  legitimately needs — nor a client that ignores `HTTPS_PROXY` and opens a raw socket. This is why
  detection (the canary) is paired with the bound.

## Machine-wide agent discovery — advisory, and why MCP is not shipped

The installer can (opt-in) write a short **advisory** rules block into the machine-wide instruction
files coding agents read (`~/.claude/CLAUDE.md` for Claude Code + VS Code Copilot; the tool's own file
for Codex/Gemini/Zed/Cline). Treat this honestly:

- **It is advisory, never the guarantee.** The rules *make an agent aware* of `agent-secrets`; prose
  adherence is probabilistic, not enforced. The **encrypted store + prompt-locked Keychain custody are
  the sole security invariant** — the discovery file is a defense-in-depth affordance.
- **An instruction file is not inert data.** It is latent instructions a capable agent executes at the
  user's full privilege, and it is **bidirectional** — an attacker who can write as you can also author
  hostile standing orders. Mitigations shipped: every block is **abs-path-pinned** (an agent invokes the
  real binary, not a `PATH` impostor), carries a **self-guard** (inert if synced to a machine without the
  tool), and an invisible **version+integrity marker** so `agent-secrets doctor` flags a **tampered** or
  hidden-Unicode-laced block (a `bad` row that flips the exit code), distinct from a benign version
  **stale**. Writes are opt-in, tty-only (never in a `curl | bash` pipe), per-file consented (each file
  named + previewed), and reversible.
- **Managed fleets:** on an org/MDM-managed machine the installer **defers** and writes nothing — the
  machine-wide invariant belongs in the managed-policy tier your IT deploys. See
  [docs/enterprise-deployment.md](docs/enterprise-deployment.md).

### MCP is intentionally NOT shipped by default

`agent-secrets` ships **no MCP server** in the one-command install — a deliberate security decision, not
an omission:

- **Config-time registration is itself the RCE primitive.** Registering *any* command in an MCP client
  config (`~/.cursor/mcp.json`, VS Code `mcp.json`) maps directly to subprocess execution regardless of
  what the server returns — so a "names-only" server does not shrink the surface that matters. Proven
  live by **CurXecute (CVE-2025-54135)** — prompt-injection writes `mcp.json` and executes before you can
  reject — and **MCPoison (CVE-2025-54136)** — trust is bound to the server *name*, not its contents, so
  an approved entry can be swapped for a malicious payload and silently re-executed. The vendor treats
  the config→exec mapping as *expected*, so it is a permanent architectural property, not a patchable bug.
- **Additional surfaces:** a persistent stdio server is a long-lived process EDR/allowlisting flags; and
  settings-sync/git propagation of the command reference plants a pre-approved, hijackable entry on other
  machines. The gain (file-automated Cursor discovery) is already covered advisorily by the clipboard
  path. The trade is wrong under lockdown.

If an org wants an agent-secrets MCP surface, treat it as a **governed, allowlisted** server deployed
deliberately — never a default.

## Detection: the in-store canary

The store seeds one plausibly-named **decoy** secret. It ships **INERT** — it provides breach
detection only once you **arm** it by replacing the placeholder value with a real tripwire token
(e.g. a [canarytokens.org](https://canarytokens.org) honeytoken bound to your own alert channel):
`setup` offers to arm it, or run `agent-secrets add AWS_BACKUP_ACCESS_KEY_ID` and paste your token.
Once armed, any process that decrypts the whole store and *uses* what it found trips your out-of-band
alert. It is listed in the manifest among the real entries on purpose, so a manifest-guided
exfiltration loop grabs it first. `doctor` reports `attn` while it is still the unarmed placeholder.

## Bounding: the egress allowlist

`run` (and the `claude-agent` / `cursor-agent` wrappers) can bound where the child sends data. Add
hosts to `~/.config/secrets/egress.allow` (one `host`, `host:port` — scoped to that port — or `*.suffix` per line); `run`
then starts a small **CONNECT proxy in core Perl** (`/usr/bin/perl` — always present on macOS, no CPAN,
corporate-safe) on a random loopback port and sets the child's `HTTPS_PROXY`/`HTTP_PROXY` so
proxy-honoring clients can reach **only** allowlisted hosts — everything else gets `403`. It is
**opt-in**: with no allowlist, `run` behaves exactly as before (no bound is invented behind your back),
and `--no-egress` (or `AGENT_SECRETS_NO_EGRESS=1`) skips it for a tool that breaks behind a proxy.

**Honest ceiling.** This is a bound, **not a kernel jail.** It constrains clients that honor
`HTTPS_PROXY` (curl, git, most SDKs); a process that ignores the proxy environment or opens a raw
socket bypasses it entirely. That residual case is *why* the bound is paired with the canary — the
allowlist shrinks the easy egress paths, and the canary detects a sweep that takes another route.
`doctor --gates` reports gate `(e)`: the allowlist (active / rules) plus any system-wide firewall app
(LuLu / Little Snitch) as a defense-in-depth layer.

**Degradation is fail-open at start, fail-closed after.** If the proxy cannot *start* (`/usr/bin/perl`
missing, a loopback bind failure), `run` prints a `WARN` to stderr and runs the child **without** the
bound rather than refusing to run — deliberate: the allowlist is a bound, not an availability gate, and
an agent mid-task should not be bricked by a degraded environment. Once started, a proxy that dies
mid-run leaves proxy-honoring clients pointed at a dead loopback port — they get connection-refused,
not open egress. If you need start-failure to be fatal, gate the run yourself on `doctor --gates`.

## Sharing (`share` / `receive` / `pubkey`)

Sending a secret to a colleague inherits the same honest-ceiling discipline — here is exactly what it
does **not** buy you:

- **No offline revocation or ephemerality.** A `share` blob is `age`-encrypted to the recipient's key;
  once they `receive` it, they hold a durable copy. Nothing in this tool can reach out and unshare it.
  **Rotating the secret at the provider is the only revocation** — the shared copy simply stops
  authenticating. There is no expiry, no "burn after reading."
- **Sender authentication is opt-in — and, in v0.1, emit-only.** A plain blob proves *nothing* about
  who produced it; an unsigned `receive` is trusting whoever pasted the text (it says so loudly:
  "sender unverified"). The digest read-back catches an **accidental** paste/transport mismatch only;
  it can **never** catch substitution — an attacker who swaps the blob swaps the digest with it. When
  the sender's identity matters, `share --sign` attaches a detached `ssh-keygen -Y sign` signature
  block; **`receive` does not auto-verify it in v0.1** — the recipient verifies it **manually** with
  `ssh-keygen -Y verify` against their own `allowed_signers` roster. That opt-in sidecar is the sole
  offline defense against substitution.
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
- **Both verbs require a real controlling terminal.** `share` (which extracts a plaintext value) and
  `receive` (which confirms an import) each demand a genuine tty for their confirm — the gate tests
  `[ -t ]` on the opened fd, not mere file-openability, so a *compliant* agent or an unattended pipe
  with no terminal cannot slip the boundary and print ciphertext into a transcript. The file-based
  `AGSEC_CONFIRM_SRC` seam is honored **only** under `AGSEC_TEST_CONFIRM=1` **and** a synthetic
  `AGENT_SECRETS_HOME` (canonicalized to a directory that is not your real `$HOME`), so it steers a test
  bypass onto a throwaway store rather than your real one. **The honest ceiling still governs and is the
  real story:** an attacker who already runs as you — who can set env vars and invoke the binary — can
  read the whole store directly from the age key, so *no* gate in a "runs-as-you" tool is a boundary
  against them, and this one does not pretend to be. What the tty check actually buys is stopping the
  *accidental / no-tty / compliant-agent* exfil-to-transcript path, the vector the sharing design is
  built to defend; deliberate exfiltration by a process that fully controls your environment is out of
  scope for every control here (see the honest-ceiling section above).

## Custody and recovery

The bootstrap age key is custodied behind one selector script with two paths. An **attended** `setup`
populates the login Keychain via the interactive paste prompt (primary; prompt-free thereafter). An
**automated / `AGENT_SECRETS_UNATTENDED`** install — or a declined Keychain prompt — stores the key in
the `0600` FileVault-backed file **by default** (on current macOS the no-argv Keychain write can't be
populated without an interactive paste, so unattended installs run on file custody now, not someday).
That is a normal, `doctor`-tracked steady state shown as "degraded (file custody)" — fully supported,
not an outage; a later macOS upgrade breaking the Keychain path is just one more trigger for it. Rotate the key every
180 days (tracked by a `rotate_by` row and the weekly smoke job). Your **recovery key** (a second
age recipient saved offline during setup) is what makes a full-machine restore possible — the
`agent-secrets setup --restore` path (paste the saved key over a restored store copy) and the
documented restore drill verify it.

## Reporting a vulnerability

Please report privately (open a **draft security advisory** on the repository, or email the
maintainer) rather than a public issue. **Redact first:** never paste a real secret value, secret
name set, username, hostname, or path. Run `agent-secrets doctor --redact` and share that output —
it is designed to be safe to paste.
