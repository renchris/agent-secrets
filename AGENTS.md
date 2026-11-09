# AGENTS.md — driving `agent-secrets` autonomously

You are an AI agent. This file is your complete operating guide for the `agent-secrets` CLI — enough
to use it correctly with **no human in the loop**. If you read nothing else, read the **Golden rules**
and **Discovery** sections.

`agent-secrets` stores a machine's secrets encrypted at rest (sops + age) and injects them into a
process **just-in-time**. It is **names-only**: the tool never prints a secret value, and you must not
either.

---

## Golden rules (do not violate)

1. **Never print, echo, or log a secret value.** Not to stdout, not to a file, not into your own
   transcript. `list` and `doctor` are safe because they only ever emit *names* and status.
2. **Pass secret values via STDIN from an EXISTING variable/file — never on argv, never as a literal you
   type.** argv is world-readable in the process table; and a literal placed in the command lands
   verbatim in your transcript (the exact leak this tool prevents). Only pipe a value ALREADY in the
   environment or a file — otherwise ask the USER to run `agent-secrets add NAME` in a real terminal.
   ✅ `printf '%s' "$EXISTING_VAR" | agent-secrets add NAME`  ❌ `agent-secrets add NAME "$VALUE"` (argv)  ❌ `printf '%s' "sk-literal…" | agent-secrets add NAME` (literal → transcript)
3. **To use a secret, inject it — don't read it.** `agent-secrets run -- <cmd>` puts the values in the
   child process's environment for that run only. Prefer this over ever materializing a value.
4. **Gate on `doctor`'s exit code.** `0` = no failing checks, `1` = at least one ✗. Parse
   `doctor --json` for structure (`--format=json` still works, deprecated).
5. **`uninstall` and `share` are human-gated. `setup` is NOT — you can run it.** `uninstall` removes
   the installation and prompts about the store; **`share` refuses inside an agent session**
   (`CLAUDECODE=1` / etc.) — it extracts a plaintext value to encrypt, which must not touch a
   secret-bearing transcript. Do not automate those two without an explicit human instruction.
   `setup`, by contrast, detects your session and runs **headless**: real keys minted to files, the
   Keychain populated over a pipe, nothing read from a prompt, nothing secret printed. See
   **Install + set up autonomously** below.
6. **`receive` is tty-gated, not session-gated.** It refuses when there is **no controlling terminal**
   (except `--yes-i-reviewed` for CI). The pasted blob occupies STDIN, so every confirm/digest-readback
   must be answered on `/dev/tty` — with no tty there is nowhere to safely confirm, so it hard-refuses.
   `pubkey` is **safe for agents**: it emits only your *public* recipient key, never a secret.

## Install + set up autonomously — zero human-in-the-loop

If `agent-secrets` is not on this machine (`command -v agent-secrets` fails and `~/bin/agent-secrets`
is absent), **install it yourself** — one command, no human step, safe inside your session:

```sh
f="$(mktemp "${TMPDIR:-/tmp}/agent-secrets-install.XXXXXX")" && curl -fsSL https://raw.githubusercontent.com/renchris/agent-secrets/v0.1.3/install.sh -o "$f" && bash "$f"
```

The script stays at `"$f"`, a fresh private file, so parallel sessions never share a path. Inside a
coding-agent session the installer detects that nobody can be prompted, asks for no consent keypress
(the plan it prints is the disclosure), and chains into `agent-secrets setup --headless`
automatically. What that does, and why it is safe in a transcript:

| Step | Headless behaviour | What touches your output |
|---|---|---|
| keys | primary + recovery `age` keys minted **to files** (`~/.config/secrets/`, 0600) | paths only |
| Keychain | the primary key goes file → pipe → `security -i` (**no argv, no clipboard, no tty**) → prompt-free **primary** custody | the word `primary` |
| recovery key | **kept** on disk (0600), never deleted unverified; a human saves it off-machine later with `agent-secrets setup` | its path |
| first secret | **none**, unless you pass `--import-env <NAME>[,<NAME>…]` for variables already set in your environment | names only |
| wiring | wrappers in `~/bin`; `apiKeyHelper` wired into `~/.claude/settings.json` **only once** `ANTHROPIC_API_KEY` is in the store (a wired helper with nothing to print breaks Claude Code's auth) | status |
| discovery | the golden rules written into `~/.claude/CLAUDE.md` (+ each present agent CLI's file), advisory + reversible; `--no-discovery` skips | each file's path |

**Installer flags** (`bash "$f" --help` prints them; it never installs):

| Flag | Effect |
|---|---|
| `--headless[=true\|false]` / `--no-headless` | force headless setup / let setup pick its own mode (the default is automatic) |
| `--import-env <NAME>[,<NAME>…]` | seed the store from variables already set in your environment (names only; an empty list is an error) |
| `--no-discovery[=true\|false]` | skip the machine-wide agent rules |
| `--discovery[=true\|false]` | pre-answer the terminal wizard's discovery offer (headless setup writes the rules anyway) |
| `--dry-run[=true\|false]` / `--no-dry-run` | print the plan and change nothing |
| `--no-color` | no color in setup (sets `NO_COLOR=1`) |
| `--debug` | extra step diagnostics on stderr |
| `-v, --version` | print the version and exit (`--json` with it prints `{"version":"…"}`) |
| `-h, --help` | print help and exit |

The newer flags (`--version`, `--no-color`, `--debug`, the `=true|false` forms, `--discovery`,
`--no-dry-run`, `--no-headless`) arrive with the next release; the pinned v0.1.3 `install.sh` does not
accept them. A flag together with its opposite (`--dry-run --no-dry-run`) is a usage error (exit 2). Two installs
at once take turns: the second waits up to 60 s on a lock, then exits `1` with the command to re-run.

Your shell predates the `PATH` line the installer adds, so **call it by full path until a new
shell**: `~/bin/agent-secrets`. Then gate on `~/bin/agent-secrets doctor` (exit 0).

**Seeding a secret you already hold** — from a variable, a file, or a Keychain item you can read —
without the value ever appearing in a command:

```sh
# value already in an exported variable
OPENROUTER_API_KEY="$OPENROUTER_API_KEY" ~/bin/agent-secrets setup --import-env OPENROUTER_API_KEY
# value in a file / a Keychain item you created earlier
printf '%s' "$(security find-generic-password -s my-item -w)" | ~/bin/agent-secrets add OPENROUTER_API_KEY
```

The command text names a *source*, never a literal, so the transcript records how the value was
found and not the value. Never type the value into the command.

**What is left for a human, and only if they want it:** saving the recovery key off this Mac
(`agent-secrets setup` in a terminal walks them through it; `doctor` reminds meanwhile), arming the
breach canary, and Cursor's User Rules paste. None of them blocks you.

## Discovery — learn the whole surface without a human

```sh
agent-secrets help                 # overview: commands, global flags, env, exit codes
agent-secrets help --json          # FULL machine-readable manifest — parse this (`help --all --json` is the same)
agent-secrets help search <TEXT>   # offline search over command names, summaries and examples (--json too)
agent-secrets <command> --help     # detailed help for one command (safe; no side effects)
agent-secrets help <command>       # same, spelled differently
```

`help --json` returns `{ tool, version, commands[], reserved_v0_2[], agent_notes }` where each command
has `{ name, synopsis, summary, description, args[], flags[], env[], examples[], exit_codes[], reads,
writes, names_only }`. Each `flags[]` entry has `flag` and `description`, plus `type`, `value_hint`,
`default` and `choices` where they apply. **Everything you need to construct a valid invocation is in there.** Every
`<command> --help` is side-effect-free — safe to probe, including `uninstall --help`.

## The commands

| Command | Use it to | Key detail |
|---|---|---|
| `setup [--headless] [--import-env <NAME>[,<NAME>…]] [--no-discovery]` | onboard a machine (once) | **headless in your session** (auto): real keys, no prompts, nothing secret printed; `--discovery` / `--keychain` / `--restore` are single steps |
| `add <NAME>` | store/update one secret | value via **STDIN**; `NAME` = `^[A-Za-z_][A-Za-z0-9_]*$` |
| `list [--json]` | see what exists | **names + rotate dates only**, never values (`--format=json` still works, deprecated) |
| `run [--no-egress] -- <cmd>` | run a tool with secrets | JIT-injected into that process; `--` required; bounds egress to `~/.config/secrets/egress.allow` when set (`--no-egress` opts out) |
| `doctor [--json] [--gates]` | check health / gate | exit `0` healthy, `1` if any ✗ |
| `pubkey [--copy]` | print your recipient key | **safe in an agent session** — public key only, never a secret |
| `share <NAME> --to <age1…\|github:user\|self>` | encrypt a secret to a colleague | **refuses in an agent session** (extracts a plaintext value); `--sign` emits a signature the recipient verifies manually |
| `receive` | ingest a pasted blob | **tty-gated** — refuses with no controlling terminal; blob on STDIN, confirm on `/dev/tty` |
| `backup [--repo owner/name] [--yes]` | push an off-machine copy | **ciphertext only** to a private GitHub repo via `gh`; never the age private key; safe in a session |
| `uninstall [--dry-run]` | remove everything | human-gated; `--dry-run` previews |

Wrappers `claude-agent` / `cursor-agent` are `run` specialized for those tools. `rotate` and `demo`
are reserved for v0.2 and exit `2` if called.

## Recipes (copy these)

```sh
# Add a secret you already hold in an EXPORTED shell variable — value never hits argv or the screen.
# The variable must actually be set: an unset/placeholder var sends an empty value, which `add` refuses.
# (A human at a terminal instead runs `agent-secrets add ANTHROPIC_API_KEY` for a hidden prompt.)
printf '%s' "$ANTHROPIC_API_KEY" | agent-secrets add ANTHROPIC_API_KEY

# Check whether a secret exists (names only; safe)
agent-secrets list --json | jq -e '.[] | select(.name=="ANTHROPIC_API_KEY")' >/dev/null \
  && echo present || echo absent

# Use a secret WITHOUT ever reading its value: inject and run
agent-secrets run -- your-tool --that-needs ANTHROPIC_API_KEY

# Prove injection works without displaying the value (byte count only)
agent-secrets run -- printenv ANTHROPIC_API_KEY | wc -c      # >1 means present

# Health-gate before doing work; branch on exit code
if agent-secrets doctor >/dev/null 2>&1; then echo healthy; else agent-secrets doctor; fi

# Set up THIS machine from inside your session (real keys; see "Install + set up autonomously").
agent-secrets setup --headless --import-env ANTHROPIC_API_KEY      # imports it only if already set in env
agent-secrets setup --discovery                                    # later: teach every agent on this Mac

# Unattended setup (tests/CI ONLY — fake/placeholder values, recovery key deleted): not the agent mode.
printf '%s' "$SEED_VALUE" | AGENT_SECRETS_UNATTENDED=1 agent-secrets setup

# Machine-readable health for decisions — the payload is an OBJECT:
#   {"checks":[{category,status,check,detail}],"exit":0|1}   (status ∈ ok|attn|bad; exit=1 iff any "bad")
# List the failing checks (iterate .checks, match "bad" — NOT .[] / "fail"):
agent-secrets doctor --json | jq '[.checks[] | select(.status=="bad")]'
```

## Environment variables

| Var | Effect |
|---|---|
| `AGENT_SECRETS_HOME` | base dir for all state (default `$HOME`; empty = `$HOME`). **Set to an isolated temp dir to test/CI without touching the real machine.** |
| `AGENT_SECRETS_PLAIN` / `NO_COLOR` | plain output (no color/box-drawing) — use when capturing output |
| `AGENT_SECRETS_UNATTENDED` | tests/CI **only**: `setup` runs with **fake placeholder** values and deletes the recovery key. Not the agent mode — an agent session gets the real headless setup with no variable at all. The seed value comes from `AGENT_SECRETS_SEED_VALUE` if set, else a single piped STDIN line (bounded read, never hangs), else a placeholder; the name from `AGENT_SECRETS_SEED_NAME` (default `ANTHROPIC_API_KEY`). |
| `CLAUDECODE` / `CURSOR_AGENT` / `TERM_PROGRAM=Cursor` | how the tool recognises a coding-agent session: `setup` goes headless, `share` refuses, `add` reminds you to pipe from a variable. You do not set these; your harness does. |

⚠️ The macOS login Keychain is **not** scoped by `AGENT_SECRETS_HOME`. When testing, put a mock
`security` on `PATH` (see `tests/mocks/`) so you never touch the real Keychain.

## Exit codes

`0` success · `1` runtime error (read the message — it is names-only and tells you the fix, e.g.
"run: agent-secrets setup") · `2` usage error / unknown command / reserved verb, or input or a
confirmation flag is required and nobody can be asked (JSON `status` `action_required`) · `130` canceled (a confirm was declined, or the run was
interrupted with Ctrl-C). `doctor` returns `1` specifically when any check is ✗ — use it as
a boolean gate. `uninstall` returns `1` also on a partial rollback (the failed records stay in the
install manifest for a retry). `run` returns the child's own exit code (128+n if it died of
signal n), or `2` if the command is not found.

## What NOT to do

- ❌ Print a value to confirm it — use `list` (names) or `run -- printenv X | wc -c` (length) instead.
- ❌ Put a value on the command line (`add NAME value`) — pipe it via STDIN.
- ❌ Hand the human "open Terminal.app and run `agent-secrets setup`" — you can run it yourself; it goes headless in your session. Only `share` and `uninstall` need a human.
- ❌ Run `uninstall` to "clean up" without explicit human intent — it is a destructive, gated action.
- ❌ Use a Model Context Protocol (MCP) server or command that returns a raw secret value — it lands in the transcript.

## More

`README.md` (human overview + diagrams) · `SECURITY.md` (threat model, honest ceiling) · `agent-secrets help --json` (the authoritative surface).
