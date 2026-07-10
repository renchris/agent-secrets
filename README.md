# agent-secrets

Machine-wide secrets for coding agents — **encrypted at rest** (sops + age), **injected
just-in-time** at the process boundary, and **never written** to configs, logs, or agent
transcripts. It's built so a secret *value* is never displayed, logged, or stored in plaintext
anywhere: the tool only ever shows you *names*.

```console
$ agent-secrets add ANTHROPIC_API_KEY
  (you won't see anything as you type or paste — that's on purpose)
Value for ANTHROPIC_API_KEY:
✓ stored ANTHROPIC_API_KEY (value never shown or logged)

$ agent-secrets list
Secrets (names only — values are never shown):
  • ANTHROPIC_API_KEY  (rotate by 2027-01-05)

$ claude-agent          # your agent, with secrets injected just for this process
```

## The one command

```sh
sh -c "$(curl -fsLS https://raw.githubusercontent.com/chrisren/agent-secrets/v0.1.0/install.sh)"
```

**Fully reversible — the uninstall is one line, here it is:**

```sh
agent-secrets uninstall      # removes everything it installed; prompts before touching your secrets
```

- **You don't need to know how to code.** The setup wizard is plain English, one question at a
  time, and previews every change before it makes it.
- **Exactly what this changes on your Mac:**
  1. installs `age` + `sops` (via Homebrew) and the `agent-secrets` command,
  2. creates an encrypted store at `~/.config/secrets/` and a key in your login Keychain,
  3. adds a small `PATH` line to your shell profile (removed cleanly on uninstall).
- **Prefer to read it first?** That's a co-equal path, not a lesser one:
  ```sh
  curl -fsLSO https://raw.githubusercontent.com/chrisren/agent-secrets/v0.1.0/install.sh
  less install.sh        # read every line
  sh install.sh          # then run it
  ```

> **Private beta:** while this repo is private the `curl` URL returns 404. Install from a private
> mirror or local checkout with `AGENT_SECRETS_BASE_URL=<mirror> sh install.sh` (see
> [docs/FAQ.md](docs/FAQ.md) → *corporate / internal-mirror install*).

## What this is

Coding agents (Claude Code, Cursor) need API keys and tokens, and the easy path — `.env` files,
exported shell variables — scatters those secrets in plaintext across your disk and into logs. This
tool keeps the handful of secrets that must exist as raw tokens in **one encrypted file**, hands
them to a tool **only for the moment it runs**, and leaves **nothing** behind in a config or a
transcript. Most services (GitHub, cloud CLIs) don't need a stored token at all — they use their
own login, and this tool leans on that first.

## What it protects you from

- **Plaintext sprawl** — one encrypted store instead of dozens of `.env` files.
- **Secrets in agent transcripts** — values are injected into a process, never echoed, so they
  can't land in `~/.claude` logs.
- **Ambient exposure** — no session-wide environment variables; injection dies with the process.
- **A stolen laptop** — the store is encrypted; the key sits in the Keychain on a FileVault volume.
- **A compromised dependency sweeping your store** — a decoy "canary" secret trips an alert if the
  whole store is ever read at once.

## Commands

| Command | What it does |
|---|---|
| `agent-secrets setup` | one-time onboarding wizard (idempotent — safe to re-run) |
| `agent-secrets add <NAME>` | add or update one secret (value typed hidden, never shown) |
| `agent-secrets list` | list secret **names** (and rotation dates) — never values |
| `agent-secrets run -- <cmd>` | run a command with secrets injected just for that process |
| `agent-secrets doctor` | health check (`--gates`, `--format=json`, `--redact`, `--fix`) |
| `agent-secrets uninstall` | remove everything it installed (prompts about your secrets) |

Wrappers `claude-agent` and `cursor-agent` launch those tools with the store injected.
(`rotate` and `demo` are reserved for v0.2.)

## Security model (the honest ceiling)

The store encrypts to a single [age](https://age-encryption.org) key custodied in your login
Keychain, with a `0600` file fallback on your FileVault volume. **This is all-or-nothing:** anything
that can run as you and read the key can read the whole store — the same ceiling a password-manager
vault has. What this design adds is *keeping secrets out of the places they usually leak* (configs,
logs, transcripts, ambient env) and *bounding + detecting* misuse (network egress limits, an
in-store canary). It does **not** claim a per-secret audit trail on the free tier. The full threat
model, what's in scope, and what isn't are in **[SECURITY.md](SECURITY.md)**; the complete design
rationale is in an internal design study.

## More

- **[SECURITY.md](SECURITY.md)** — threat model, the honest ceiling, reporting a vulnerability
- **[docs/FAQ.md](docs/FAQ.md)** — "I don't code", store backup, the Dock-Cursor rule, corporate installs, Touch ID


## Uninstall (in detail)

`agent-secrets uninstall` reverses every recorded change: removes the installed files and wrappers,
strips the `PATH` line, boots out the weekly health-check job, reverts the `settings.json` edit from
backup, and clears the Keychain items. It then **asks** whether to keep or delete your encrypted
store and keys — keeping them (the default) lets you re-onboard later from your saved recovery key.
Add `--dry-run` to see the full plan without changing anything.

## License

[MIT](LICENSE).
