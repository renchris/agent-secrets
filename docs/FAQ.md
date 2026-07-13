# FAQ

### I don't write code — is this for me?

Yes. If you use Claude Code or Cursor, this keeps your application programming interface (API) keys safe without you ever editing a file
or knowing a format. The setup wizard asks one plain-English question at a time, shows you every
change before it makes it, and can undo everything with one command. You never type or see a secret
value on screen.

### What if I lose my Mac, or the key?

During setup the tool creates a **recovery key** in addition to your main key and encrypts your store
to both. Save the recovery key where you keep important things (a password manager, or a printed
sheet in a safe). To restore on a new machine: install the tool, copy your backed-up encrypted store
into place (`~/.config/secrets/secrets.env`), run `agent-secrets setup --restore`, and paste your
saved key — your store decrypts. (There's a tested "restore drill" for exactly this.)

### Do I need to back up my store?

Yes — keep one off-machine copy. The easy path: **`agent-secrets backup`** pushes your **encrypted**
store (ciphertext only — never your age private key) to a private GitHub repo via `gh`, so a lost or
dead Mac stays recoverable. `agent-secrets doctor` reports whether that off-machine copy is configured.
Prefer to do it by hand? Keep a copy of `~/.config/secrets/` somewhere safe. Either way, restore on a
new machine with `agent-secrets setup --restore` and your password-manager-saved key. Losing **both**
the store and your key means the secrets are unrecoverable — which is the point: no one else can read
them either.

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
| `canarytokens.org` | runtime only, and only if you arm the in-store canary with a token you mint there |

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
egress proxy may already provide a network bound — if so, integrate with it rather than double-building.
agent-secrets also ships its own opt-in, process-scoped bound: add hosts to `~/.config/secrets/egress.allow`
and `run` routes the child's HTTP(S) through a loopback allowlist proxy (core Perl, no extra installs).

### Does Touch ID work?

The login Keychain read is prompt-free for the normal logged-in, screen-locked case, so agents run
without interruption. Touch ID / password prompts appear only in the situations macOS itself gates
(some post-reboot and cross-user cases). If the Keychain path ever fails, custody falls back to the
`0600` key file automatically and `doctor` reports "degraded (file custody)".

### How do I send a secret to a colleague?

**First ask whether you have to.** The best "share" is no share: most services (GitHub, cloud CLIs,
Anthropic) can issue a per-person credential, so your colleague mints their own scoped key that you
can't leak and the provider can revoke. Only when a value genuinely has to travel do you reach for
the last rung: your colleague runs `agent-secrets pubkey` and gives you their `age1…` recipient
string; you run `agent-secrets share <NAME>`, pick their key, and confirm on the terminal; the tool
prints a fenced blob. Send them that whole block (chat, ticket, wherever). They paste it into
`agent-secrets receive`, eyeball the digest read-back against the one you read aloud, and confirm —
the secret lands in their store having never been shown or written to a plaintext file.

### Why can't I recall a shared secret?

You can't — there is no "unshare." Once a colleague has `receive`d the blob they hold a durable,
decryptable copy, and nothing offline can reach into their machine to revoke it. The only real
take-back is to **rotate the secret at the provider**: re-issue the token, and the copy you shared
simply stops authenticating. Treat every share as permanent until you rotate.

### The recipient doesn't have agent-secrets — how do they open it?

They install it (the one-line installer), run `agent-secrets setup` once, then
`agent-secrets receive` and paste your blob. **Do not** talk them through `age -d` into a plaintext
file — that dumps the decrypted secret straight to disk, exactly the leak this tool exists to
prevent. `receive` pipes the decrypted value directly into their encrypted store; it never touches a
temp plaintext file or their scrollback.

### How do I remove everything?

`agent-secrets uninstall` — it reverses every recorded change and then asks whether to keep or delete
your encrypted store and keys. Add `--dry-run` to preview the full plan first.
