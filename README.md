<div align="center">

<img src="assets/hero.svg" alt="agent-secrets — machine-wide secrets for coding agents, encrypted at rest, injected just-in-time, names-only" width="100%">

<br><br>

[![CI](https://github.com/renchris/agent-secrets/actions/workflows/ci.yml/badge.svg)](https://github.com/renchris/agent-secrets/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-d4af37?style=flat-square)](LICENSE)
[![Version](https://img.shields.io/badge/version-0.1.1-58a6ff?style=flat-square)](VERSION)
[![Tests](https://img.shields.io/badge/bats-passing-3fb950?style=flat-square)](tests)
[![Security](https://img.shields.io/badge/values-names--only-3fb950?style=flat-square)](SECURITY.md)
[![Crypto](https://img.shields.io/badge/crypto-sops%20%2B%20age-d4af37?style=flat-square)](https://github.com/getsops/sops)
[![Agent-ready](https://img.shields.io/badge/agent--ready-AGENTS.md%20%C2%B7%20help%20--json-bc8cff?style=flat-square)](AGENTS.md)
[![Cost](https://img.shields.io/badge/cost-%240%20%C2%B7%20zero%20vendor-8b949e?style=flat-square)](#the-honest-ceiling)

**Encrypted at rest · injected just-in-time · never in a config, log, or transcript.**

[Why](#why-this-exists) · [Install](#install--setup) · [How it works](#how-it-works) · [Commands](#commands) · [Security](#the-honest-ceiling) · [Uninstall](#uninstall)

</div>

<div align="center">

<img src="assets/demo.gif" alt="agent-secrets demo: list shows names only, run injects a value but only its byte count is shown, doctor is green" width="90%">

</div>

> **Everything stays on your machine.** The store, the keys, and every command run locally.
> The tool is built so a secret **value** is never displayed, logged, or written in plaintext
> outside the encrypted store — `list` and `doctor` only ever show you *names*.

---

## Why this exists

Coding agents (Claude Code, Cursor) need application programming interface (API) keys and tokens, and the easy path — `.env` files,
exported shell variables — scatters those secrets in plaintext across your disk and into logs and
agent transcripts.

| The problem today | The cost |
|---|---|
| `.env` files in every repo | Plaintext secrets sprawled across your disk |
| `export ANTHROPIC_API_KEY=…` in your shell | Every child process, forever, can read it |
| An agent echoes a value into its output | It lands in `~/.claude/**/*.jsonl` in plaintext |

**agent-secrets keeps the handful of secrets that must exist as raw tokens in one encrypted file,
hands them to a tool only for the moment it runs, and leaves nothing behind.** Most services
(GitHub, cloud CLIs) don't need a stored token at all — they use their own login, and this tool
leans on that first.

## Install + setup

Two commands, honestly. **Install** puts everything in place and can run from anywhere — even from
inside a coding-agent session. **Setup** is the human key ceremony — it mints your encryption key
and takes your first secret, so it runs in a real terminal (Terminal.app / iTerm), never in an
agent transcript.

```sh
# 1 · install — from anywhere (no sudo, no Homebrew; a coding-agent session is fine)
bash -c "$(curl -fsLS https://raw.githubusercontent.com/renchris/agent-secrets/v0.1.1/install.sh)"

# 2 · setup — in Terminal.app: mint your key, add your first secret, wire your tools
agent-secrets setup
```

In a normal terminal the installer chains straight into setup, so it feels like one command; from
inside an agent session it installs everything, then defers setup on purpose (see the callout below).

<table>
<tr>
<td width="50%" valign="top">

**Fully reversible** — the uninstall is one line:

```sh
agent-secrets uninstall
```

Every change is recorded to an install-manifest and rolled back completely; it *asks* before
touching your store.

</td>
<td width="50%" valign="top">

**Prefer to read it first?** A co-equal path:

```sh
curl -fsLSO …/v0.1.1/install.sh
less install.sh     # read every line
bash install.sh
```

The installer is function-guarded and pins a SHA-256–verified release.

</td>
</tr>
</table>

**Exactly what it changes on your Mac:** ensures `age`, `sops`, `gum`, `jq` **without `sudo` and
without requiring Homebrew** — it reuses any you already have, uses Homebrew only if it's already
installed, and otherwise downloads pinned, SHA-256-verified static binaries into
`~/.agent-secrets/vendor/` (~70 MB for all four — the price of the no-`sudo` guarantee; removed by
uninstall); the `agent-secrets` command plus the `claude-agent`, `cursor-agent`, and
`apiKeyHelper` wrappers in `~/bin`; an encrypted store at `~/.config/secrets/`; your age key in the
login Keychain (with a `0600` file fallback); one `PATH` line in `~/.zshenv`; a weekly `launchd`
smoke job; and the `apiKeyHelper` line in `~/.claude/settings.json`. It also *offers* (opt-in) to write
a short agent-discovery block into `~/.claude/CLAUDE.md` (read by Claude Code + VS Code Copilot, plus a
per-tool file for any other agent CLI present). Every change is recorded in
`install-manifest.json` and reversed by `agent-secrets uninstall` — all removable in one command.

> **Running this from inside a coding agent (Cursor / Claude Code)?** The installer finishes the file
> setup (exit 0) and then **defers step 2** — minting your key and taking your first secret would land
> them in the agent's transcript. It prints one instruction: open **Terminal.app** and run
> `agent-secrets setup`. Everything else is already done.

> **Behind a corporate firewall or air-gapped?** No Homebrew and no `sudo` are needed — the toolchain
> comes from pinned GitHub-release binaries. If `raw.githubusercontent.com` is blocked, install from an
> internal mirror: `AGENT_SECRETS_BASE_URL=<mirror> bash install.sh`, and mirror the dependency binaries
> too with `AGENT_SECRETS_DEPS_BASE_URL=<mirror>` (see [FAQ](docs/FAQ.md) → corporate install).

## How it works

### 1 · Names-only, just-in-time injection

The store is encrypted at rest. A secret is decrypted **only at the moment a tool launches**,
injected into that one process's environment, and gone when it exits. It never touches a config
file, a shell export, a log, or an agent transcript.

<!-- Diagram source: assets/diagrams/injection.mmd — edit it, run `npm run diagrams`, commit the regenerated SVGs. -->
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="assets/diagrams/injection-dark.svg">
  <img src="assets/diagrams/injection-light.svg" alt="Just-in-time injection: secrets.env (sops + age — names plaintext, values encrypted) is decrypted only at launch by the claude-agent / cursor-agent wrappers and injected into the launched process's environment; when the process exits the value is gone — never written to config files, shell exports, ~/.claude transcripts, or terminal logs">
</picture>

<details>
<summary>Interactive Diagram</summary>

<!-- mermaid-fence: assets/diagrams/injection.mmd (auto-synced by `npm run diagrams`) -->
```mermaid
flowchart LR
    subgraph rest["🔒 at rest · encrypted"]
        S["secrets.env<br/>sops + age<br/><i>names plaintext · values ENC［…］</i>"]
    end
    subgraph jit["⚡ just-in-time · process-scoped"]
        W["claude-agent / cursor-agent<br/>run -- &lt;cmd&gt;"]
        P(["launched process<br/><b>value in env only</b>"])
    end
    S -->|"sops exec-env<br/>decrypt at launch"| W
    W -->|"inject"| P
    P -.->|"process exits →<br/>value gone"| X["∅ nothing persists"]

    S -.->|"✗ never written"| LEAK["❌ config files<br/>❌ shell exports<br/>❌ ~/.claude transcripts<br/>❌ terminal / logs"]

    classDef enc fill:#1a2b1a,stroke:#3fb950,color:#e6edf3
    classDef jit fill:#2b2410,stroke:#d4af37,color:#e6edf3
    classDef leak fill:#2b1618,stroke:#ff6b6b,color:#ff9b9b
    classDef gone fill:#161b22,stroke:#6e7681,color:#8b949e
    class S enc
    class W,P jit
    class LEAK leak
    class X gone
```

<sup><a href="assets/diagrams/injection-dark.svg?raw=true">full-screen dark</a> · <a href="assets/diagrams/injection-light.svg?raw=true">light</a> · <a href="assets/diagrams/injection.mmd">source</a></sup>

</details>

### 2 · One key, custodied three ways

A single `age` key unlocks the store. It lives in your login Keychain (prompt-free), with a `0600`
file fallback so a macOS upgrade can't lock you out, and a **recovery recipient** kept off-machine
so you can restore after losing the Mac entirely.

<!-- Diagram source: assets/diagrams/custody.mmd — edit it, run `npm run diagrams`, commit the regenerated SVGs. -->
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="assets/diagrams/custody-dark.svg">
  <img src="assets/diagrams/custody-light.svg" alt="Key custody: one age keypair generated once on-device, held three ways — login Keychain (primary, prompt-free), 0600 file on the FileVault volume (fallback), and an off-machine recovery recipient in your password manager; the age-key-cmd selector feeds SOPS_AGE_KEY_CMD to decrypt secrets.env; a macOS upgrade degrades gracefully to file custody (doctor tracks it), and losing the Mac entirely is covered by the restore drill">
</picture>

<details>
<summary>Interactive Diagram</summary>

<!-- mermaid-fence: assets/diagrams/custody.mmd (auto-synced by `npm run diagrams`) -->
```mermaid
flowchart TB
    K["🔑 age keypair<br/>generated once, on-device"]
    K --> PRIM["login Keychain<br/><b>primary</b> · prompt-free"]
    K --> FALL["0600 file · FileVault vol<br/><b>fallback</b>"]
    K --> REC["recovery recipient<br/><b>off-machine leg</b> → your password manager"]

    SEL{"age-key-cmd<br/>selector"}
    PRIM --> SEL
    FALL --> SEL
    SEL -->|"SOPS_AGE_KEY_CMD"| DEC["decrypt secrets.env"]

    PRIM -. "macOS upgrade breaks Keychain?" .-> DEG["doctor: degraded<br/>(file custody) — tracked, not an outage"]
    FALL -.-> DEG
    REC -. "lost your Mac?" .-> RES["restore drill →<br/>store decrypts from the saved key alone"]

    classDef key fill:#2b2410,stroke:#d4af37,color:#f0f6fc
    classDef sink fill:#161b22,stroke:#58a6ff,color:#e6edf3
    classDef ok fill:#1a2b1a,stroke:#3fb950,color:#e6edf3
    classDef warn fill:#2b2410,stroke:#e3b341,color:#e6edf3
    class K key
    class PRIM,FALL,REC sink
    class SEL,DEC ok
    class DEG,RES warn
```

<sup><a href="assets/diagrams/custody-dark.svg?raw=true">full-screen dark</a> · <a href="assets/diagrams/custody-light.svg?raw=true">light</a> · <a href="assets/diagrams/custody.mmd">source</a></sup>

</details>

### 3 · One command in, one command out

Every install action is recorded so uninstall is total — no orphaned launchd jobs, PATH lines, or
Keychain items.

<!-- Diagram source: assets/diagrams/reversible.mmd — edit it, run `npm run diagrams`, commit the regenerated SVGs. -->
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="assets/diagrams/reversible-dark.svg">
  <img src="assets/diagrams/reversible-light.svg" alt="Reversible install: one command ensures the age/sops/gum/jq toolchain (no sudo, vendored if needed), the tool and wrappers on PATH, a weekly launchd smoke job, and the settings.json apiKeyHelper — every change recorded in install-manifest.json (path, sha256, mode, edit, launchd); agent-secrets uninstall performs a total rollback — files, PATH block, launchd bootout, settings.json reverted, Keychain item purged (exact service) — to zero residue, with a keep-or-purge prompt for your store">
</picture>

<details>
<summary>Interactive Diagram</summary>

<!-- mermaid-fence: assets/diagrams/reversible.mmd (auto-synced by `npm run diagrams`) -->
```mermaid
flowchart LR
    subgraph install["one command · every change recorded"]
        direction TB
        I1["toolchain: age · sops · gum · jq<br/><i>no sudo · vendored if needed</i>"]
        I2["tool + wrappers → PATH"]
        I3["weekly launchd smoke job"]
        I4["settings.json apiKeyHelper"]
    end
    M[("install-manifest.json<br/><i>path · sha256 · mode · edit · launchd</i>")]
    I1 --> M
    I2 --> M
    I3 --> M
    I4 --> M
    M ==>|"agent-secrets uninstall"| U["↩ total rollback<br/>files · PATH block · launchd bootout<br/>settings.json reverted · Keychain item purged (exact service)"]
    U --> Z["✓ zero residue<br/><i>keep-or-purge prompt for your store</i>"]

    classDef step fill:#161b22,stroke:#58a6ff,color:#e6edf3
    classDef man fill:#2b2410,stroke:#d4af37,color:#f0f6fc
    classDef undo fill:#1a2b1a,stroke:#3fb950,color:#e6edf3
    class I1,I2,I3,I4 step
    class M man
    class U,Z undo
```

<sup><a href="assets/diagrams/reversible-dark.svg?raw=true">full-screen dark</a> · <a href="assets/diagrams/reversible-light.svg?raw=true">light</a> · <a href="assets/diagrams/reversible.mmd">source</a></sup>

</details>

## Commands

| Command | What it does |
|---|---|
| `agent-secrets setup` | one-time onboarding wizard (idempotent — safe to re-run) |
| `agent-secrets add <NAME>` | add or update one secret (value typed hidden, never shown) |
| `agent-secrets list` | list secret **names** + rotation dates — never values |
| `agent-secrets run -- <cmd>` | run a command with secrets injected just for that process |
| `agent-secrets doctor` | health check — `--gates`, `--summary`, `--format=json`, `--redact`, `--fix` |
| `agent-secrets pubkey` | print your `age` recipient string + fingerprint — hand it to a sender (`--copy`) |
| `agent-secrets share <NAME> --to <recipient>` | encrypt one secret to a colleague's key as a paste-able blob (last-rung — prefer the ladder) |
| `agent-secrets receive` | decrypt a colleague's pasted blob into your store (confirms on the terminal) |
| `agent-secrets backup` | push your **encrypted** store (ciphertext only, never the age key) to a private GitHub repo |
| `agent-secrets uninstall` | remove everything it installed (prompts about your secrets) |

Wrappers `claude-agent` and `cursor-agent` launch those tools with the store injected.
(`rotate` and `demo` are reserved for v0.2.)

### Sharing a secret with a colleague

**Sharing a value is the last rung — prefer having them mint their own scoped key.** Most services
(GitHub, cloud CLIs, Anthropic) can re-issue a credential per person, which gives *them* a token
*you* can't leak and the provider can revoke. Reach for `share` only when a value genuinely has to
travel: your colleague runs `agent-secrets pubkey` and hands you their `age1…` recipient, you
`agent-secrets share <NAME>` to encrypt to it, they paste the fenced blob into `agent-secrets receive`.
Nothing offline can revoke a shared copy — rotating the secret at the provider is the only take-back.
Full stance → **[SECURITY.md](SECURITY.md)** → *Sharing*.

## The honest ceiling

The store encrypts to a single `age` key. **This is all-or-nothing:** anything that runs as you and
reads the key can read the whole store — the same ceiling a password-manager vault has. What this
design adds is *keeping secrets out of the places they usually leak* and *bounding + detecting*
misuse: an in-store **canary** — which you arm with a tripwire token (`setup` offers to; `doctor`
reminds you until you do) — trips an alert on any whole-store sweep, and an opt-in, process-scoped
**egress allowlist** — a loopback CONNECT proxy `run` starts from `~/.config/secrets/egress.allow` —
bounds where a compromised agent can send data. That bound is **honest about its ceiling**: it
constrains proxy-honoring clients (curl/git/most SDKs via `HTTPS_PROXY`), not a process that opens a
raw socket — which is exactly why it is *paired* with the canary. It does **not** claim a per-secret
audit trail on the free tier. Full threat model → **[SECURITY.md](SECURITY.md)**.

## For AI agents

Driving this tool autonomously? Start with **[AGENTS.md](AGENTS.md)** — golden rules, discovery,
copy-paste recipes, and exit codes. The command-line interface (CLI) is fully self-describing with no human needed:

```sh
agent-secrets help --json          # authoritative machine-readable command manifest
agent-secrets <command> --help     # detailed per-command help (side-effect-free, even `uninstall --help`)
```

**Machine-wide discovery — how agents in *other* repos find out.** This repo's `AGENTS.md` is
repo-scoped, and the `apiKeyHelper` only auths Claude Code's own key, so by default an agent working
in some *other* project has no idea this Mac has `agent-secrets`. To close that gap the installer
*offers* (opt-in, and reversed by `uninstall`) to write a short, reversible marker block into
`~/.claude/CLAUDE.md` — carrying the golden rules (no plaintext `.env`; `agent-secrets run -- <cmd>`;
add secrets in a real terminal, never a value in a command; `agent-secrets help --json`). **One file,
two readers:** Claude Code loads `~/.claude/CLAUDE.md` in every repo, *and* VS Code Copilot reads it by
default (`chat.useClaudeMdFile`) — so the same file covers both. (User-home `~/.claude/rules` is **not**
read by Copilot by default on stable VS Code, so `CLAUDE.md` is the version-robust surface.) The
installer also writes the rules into any **other** agent CLI present on this Mac (Codex, Gemini, Zed,
Cline — each in its own instruction file). Every block is **abs-path-pinned** (an agent invokes the real
binary, not a PATH impostor), carries a **self-guard** (it goes inert if the file is synced to a machine
without the tool), and an invisible **integrity marker** (`doctor` flags tampering). Discovery is
**advisory** (it makes agents *aware* of the tool; it is not an enforced guarantee), everything is
recorded for total rollback, and nothing is written unless you say yes on an interactive install (a
piped `curl | bash` never silently edits a global file, and the prompt **names each file** it would
write + previews the block first). On an **org/MDM-managed** machine the installer **defers entirely** —
it writes nothing machine-wide and leaves that tier to your IT (see
**[docs/enterprise-deployment.md](docs/enterprise-deployment.md)**). `agent-secrets doctor` reports each
surface's status (and flags a tampered block).

#### Who reads what

Different agents discover the golden rules through different surfaces — there is **no single global
config every IDE honors**. Here's the honest picture:

| Surface | How it learns the rules | Automated? |
|---|---|---|
| **Claude Code** (global) | The opt-in block in `~/.claude/CLAUDE.md`, loaded in every session in every repo | ✅ installer opt-in; `doctor` verifies it |
| **VS Code Copilot** (global) | The **same** `~/.claude/CLAUDE.md` block — Copilot reads it by default (`chat.useClaudeMdFile`) | ✅ covered free by the Claude file; `doctor` reports it |
| **Cursor** (global) | **Settings → Rules → User Rules** — paste the four golden rules once | ⚠️ semi-automated: `setup` prints them **and copies them to your clipboard** (Cursor has no stable file-based path to write) |
| **Codex / Gemini / Zed / Cline** (global) | Each tool's own file (`~/.codex/AGENTS.md`, `~/.gemini/GEMINI.md`, `~/.config/zed/AGENTS.md`, `~/.agents/AGENTS.md`) | ✅ installer opt-in when the tool is present on this Mac |
| **Any repo** (`AGENTS.md`) | A repo's own `AGENTS.md`, which Claude Code, Cursor, and others read | 📄 add per repo (this project ships one you can copy as a template) |

Cursor also reads a repo's `AGENTS.md`, so per-project guidance carries over even without the global
User Rules. For the brew-less `gh` / `az` setup recipes and the token ladder, see
**[docs/POST_INSTALL.md](docs/POST_INSTALL.md)** or run `agent-secrets help onboarding`.

## More

- **[AGENTS.md](AGENTS.md)** · **[llms.txt](llms.txt)** — agent-facing usage guide + large language model (LLM) link index
- **[SECURITY.md](SECURITY.md)** — threat model, the honest ceiling, the discovery/MCP posture, reporting a vulnerability
- **[docs/enterprise-deployment.md](docs/enterprise-deployment.md)** — managed-fleet (Jamf/Intune) deployment: the installer defers to org policy; the managed-settings fragment IT deploys
- **[docs/POST_INSTALL.md](docs/POST_INSTALL.md)** — brew-less `gh` / `az` setup + the token ladder (also `agent-secrets help onboarding`)
- **[docs/FAQ.md](docs/FAQ.md)** — "I don't code", store backup, the Dock-Cursor rule, corporate installs, Touch ID
- Regenerate the demo: `scripts/record-demo.sh` (Charm [VHS](https://github.com/charmbracelet/vhs))

## Uninstall

`agent-secrets uninstall` reverses every recorded change — files, wrappers, the `PATH` line, the
launchd job, the `settings.json` edit, the machine-wide discovery files/blocks (if you opted in),
and the Keychain items — then **asks** whether to keep or delete your encrypted store and keys. Add
`--dry-run` to preview the plan without changing anything.

## Development

Notes for maintaining this. Driving the CLI itself → [AGENTS.md](AGENTS.md).

**Setup:** `brew install age sops shellcheck bats-core` (add `node` only to work on the diagrams).

- **Test:** `bats tests/` — the behavior suite runs under a synthetic `AGENT_SECRETS_HOME`; the real Keychain and store are never touched.
- **Lint:** `shellcheck bin/* cmd/*.sh lib/*.sh scripts/*.sh install.sh` — CI runs this plus a zero-telemetry gate and the bats suite.
- **Diagrams:** edit `assets/diagrams/*.mmd`, then `npm install && npm run diagrams`, and commit the regenerated SVGs (CI fails on stale ones).
- **Commits:** lowercase [Conventional Commits](https://www.conventionalcommits.org).
- **Cut a release:** `scripts/release.sh vX.Y.Z` (maintainer-only). It `git archive`s the tag with a pinned `--prefix` (`.gitattributes` trims it to runtime and excludes `install.sh`), **bakes the tarball's own sha256 into `install.sh`'s `EXPECTED_SHA256`** — the integrity anchor travels the git-ref channel, distinct from the swappable release asset — re-tags, writes the sibling `.sha256` (transport convenience), and `gh release create`s the release (enable **immutable releases** in repo settings so published assets can't be swapped). Baking is non-circular precisely because `install.sh` is export-ignored from the archive.
- **The one rule:** *names-only* — a secret **value** is never printed, logged, or written outside the encrypted store (→ [SECURITY.md](SECURITY.md)).

Layout: `bin/` verb dispatcher · `lib/` shared helpers · `cmd/` one file per verb.

## License

[MIT](LICENSE) · © 2026 Chris Ren
