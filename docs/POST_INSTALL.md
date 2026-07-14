# Post-install onboarding — configure your services (brew-less macOS)

You've installed `agent-secrets` and run `agent-secrets setup`. This guide takes you the rest of
the way: GitHub, Azure, and API keys — **without Homebrew, without `sudo`**.

> The same content is available in your terminal, offline:
> ```sh
> agent-secrets help onboarding
> ```

## First: prefer a CLI login over a stored token

Most services authenticate with their **own per-user login**, which is safer than a long-lived token
sitting in any store — it's individually attributable and the provider can revoke it. Reach for
`agent-secrets add` **last**, only for keys that must exist as raw tokens in a process's environment.

| Order | Do this | Why |
|------:|---------|-----|
| 1 | `gh auth login` | GitHub — also enables `agent-secrets backup` |
| 2 | `az login` | Azure |
| 3 | `agent-secrets add NAME` | only for keys that must live in env (e.g. `ANTHROPIC_API_KEY`) |

The installer vendors `agent-secrets`' own toolchain (`age`, `sops`, `gum`, `jq`). It does **not**
vendor `gh` or `az` — they're heavier, have their own release cadence, and `gh auth login` is
interactive. Install them yourself with the recipes below (this is a deliberate *document-not-bundle*
choice).

## GitHub CLI (`gh`) — no Homebrew needed

Download the pinned macOS release straight into `~/bin` (already on your `PATH` after install):

```sh
V=2.62.0                                    # latest: https://github.com/cli/cli/releases
A=$(uname -m); [ "$A" = x86_64 ] && A=amd64
curl -fsSL "https://github.com/cli/cli/releases/download/v$V/gh_${V}_macOS_${A}.zip" -o /tmp/gh.zip
unzip -oq /tmp/gh.zip -d /tmp               # extracts /tmp/gh_${V}_macOS_${A}/
mkdir -p ~/bin && cp "/tmp/gh_${V}_macOS_${A}/bin/gh" ~/bin/gh
gh --version && gh auth login               # browser or a token; pick HTTPS + your preferred method
```

Once authenticated, `agent-secrets backup` can push your **encrypted** store (ciphertext only — never
your age private key) to a private GitHub repo, so a lost or dead Mac stays recoverable.

## Azure CLI (`az`) — needs Python 3.9+ (the non-obvious part)

`az` is a Python application — this is the step that trips people up. The cleanest brew-less, no-`sudo`
path is an **isolated virtualenv**, so nothing pollutes your global Python:

```sh
python3 --version                           # need 3.9+ (install from python.org or via pyenv if absent)
python3 -m venv ~/.azure-cli-venv
~/.azure-cli-venv/bin/pip install --upgrade pip azure-cli   # a few minutes; downloads wheels
mkdir -p ~/bin && ln -sf ~/.azure-cli-venv/bin/az ~/bin/az
az version && az login                      # opens a browser
```

Prefer `az login` (your own identity, MFA-backed) over storing `AZURE_*` secrets. To remove `az`
later: `rm -rf ~/.azure-cli-venv ~/bin/az`.

## Anthropic (optional — for Claude Code / `cursor-agent`)

Claude Code and `cursor-agent` authenticate through the `apiKeyHelper` that `setup` wired into
`~/.claude/settings.json` — so you only need to add a key when you actually have one. Add it with the
value on a **hidden prompt** (never on the command line, never a doc placeholder pasted verbatim):

```sh
agent-secrets add ANTHROPIC_API_KEY         # interactive: prompts for the value, echoes nothing
```

If you already hold the value in an **exported** shell variable, you can pipe it instead (the variable
must actually be set — an unset one sends an empty value and `add` will refuse it):

```sh
printf '%s' "$ANTHROPIC_API_KEY" | agent-secrets add ANTHROPIC_API_KEY
```

## Where each agent reads its rules

See the **[README → "Who reads what"](../README.md#who-reads-what)** table for how discovery works
across Claude Code, Cursor, VS Code Copilot, and a repo's `AGENTS.md`.

## Verify

```sh
agent-secrets doctor            # full health check
gh auth status                  # GitHub authenticated?
az account show                 # Azure authenticated?
```
