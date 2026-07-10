# FAQ

### I don't write code — is this for me?

Yes. If you use Claude Code or Cursor, this keeps your application programming interface (API) keys safe without you ever editing a file
or knowing a format. The setup wizard asks one plain-English question at a time, shows you every
change before it makes it, and can undo everything with one command. You never type or see a secret
value on screen.

### What if I lose my Mac, or the key?

During setup the tool creates a **recovery key** in addition to your main key and encrypts your store
to both. Save the recovery key where you keep important things (a password manager, or a printed
sheet in a safe). To restore on a new machine: install the tool, run `agent-secrets setup`, choose
the restore option, and paste your saved key — your store decrypts. (There's a tested "restore
drill" for exactly this.)

### Do I need to back up my store?

If you let the tool create a **private GitHub repo** for your store, it's already backed up there. If
you keep the store local-only, keep a second copy of `~/.config/secrets/` somewhere safe —
`agent-secrets doctor` warns you when it has no second copy. Losing both the store and your keys
means the secrets are unrecoverable (which is the point — no one else can read them either).

### Why does my Dock Cursor not have my secrets?

On purpose. Launching Cursor from the Dock (or `open -a`) is the **secret-free** interactive mode.
Agent work that needs secrets goes through the `cursor-agent` command, which injects them just for
that launch. If you run `cursor-agent` while a Dock Cursor is already open, it will tell you to quit
that one first — otherwise the new secrets wouldn't reach the running app.

### Corporate machine, firewall, or air-gapped?

If your network filters egress (Cisco Umbrella, Zscaler, a TLS-inspecting proxy), give IT this
**allowlist** — every host the installer touches:

| Host | Why |
|---|---|
| `raw.githubusercontent.com` | fetches `install.sh` |
| `github.com`, `objects.githubusercontent.com` | the pinned release tarball + `.sha256` |
| `github.com/Homebrew`, `formulae.brew.sh`, `ghcr.io` | Homebrew + bottles for `age`, `sops`, `gum` (skipped if already installed) |
| `canarytokens.org` | runtime only, and only if you enable the in-store canary |

**Proxy + TLS inspection work with no changes:** `install.sh` uses `curl`, which honors
`HTTPS_PROXY` / `HTTP_PROXY` / `NO_PROXY`; and as long as your corporate root CA is trusted (Jamf/MDM
installs it into the System keychain) system `curl` validates the inspected TLS transparently — set
`CURL_CA_BUNDLE=/path/to/corp-ca.pem` only if it is not.

**Internal mirror / air-gapped (no public egress):** mirror the release assets (`install.sh` +
`agent-secrets-v0.1.0.tar.gz` + `.sha256`, under a `releases/download/v0.1.0/` path) onto your
internal Git / Artifactory / Nexus, fetch `install.sh` from there, and point it back at the mirror:

```sh
AGENT_SECRETS_BASE_URL=https://git.internal.example/mirror/agent-secrets sh install.sh
```

Get IT/security approval first; keep your store + manifest on the **internal** git host (names-only
is still internal-sensitive); and note that corporate endpoint detection and response (EDR) or an
egress proxy may already provide the network bound this design asks for — integrate with it rather
than double-building.

### Does Touch ID work?

The login Keychain read is prompt-free for the normal logged-in, screen-locked case, so agents run
without interruption. Touch ID / password prompts appear only in the situations macOS itself gates
(some post-reboot and cross-user cases). If the Keychain path ever fails, custody falls back to the
`0600` key file automatically and `doctor` reports "degraded (file custody)".

### How do I remove everything?

`agent-secrets uninstall` — it reverses every recorded change and then asks whether to keep or delete
your encrypted store and keys. Add `--dry-run` to preview the full plan first.
