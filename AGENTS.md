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
2. **Pass secret values via STDIN, never on argv.** argv is world-readable in the process table.
   ✅ `printf '%s' "$VALUE" | agent-secrets add NAME` ❌ `agent-secrets add NAME "$VALUE"`
3. **To use a secret, inject it — don't read it.** `agent-secrets run -- <cmd>` puts the values in the
   child process's environment for that run only. Prefer this over ever materializing a value.
4. **Gate on `doctor`'s exit code.** `0` = no failing checks, `1` = at least one ✗. Parse
   `doctor --format=json` for structure.
5. **`uninstall`, the setup key-ceremony, and `share` are human-gated.** `uninstall` removes the
   installation and prompts about the store; the `setup` wizard refuses its key ceremony inside an
   agent session; **`share` also refuses inside an agent session** (`CLAUDECODE=1` / etc.) — it
   extracts a plaintext value to encrypt, which must not touch a secret-bearing transcript. Do not
   automate these without an explicit human instruction.
6. **`receive` is tty-gated, not session-gated.** It refuses when there is **no controlling terminal**
   (except `--yes-i-reviewed` for CI). The pasted blob occupies STDIN, so every confirm/digest-readback
   must be answered on `/dev/tty` — with no tty there is nowhere to safely confirm, so it hard-refuses.
   `pubkey` is **safe for agents**: it emits only your *public* recipient key, never a secret.

## Discovery — learn the whole surface without a human

```sh
agent-secrets help                 # overview: commands, global flags, env, exit codes
agent-secrets help --json          # FULL machine-readable manifest — parse this
agent-secrets <command> --help     # detailed help for one command (safe; no side effects)
agent-secrets help <command>       # same, spelled differently
```

`help --json` returns `{ tool, version, commands[], reserved_v0_2[], agent_notes }` where each command
has `{ name, synopsis, summary, description, args[], flags[], env[], examples[], exit_codes[], reads,
writes, names_only }`. **Everything you need to construct a valid invocation is in there.** Every
`<command> --help` is side-effect-free — safe to probe, including `uninstall --help`.

## The commands

| Command | Use it to | Key detail |
|---|---|---|
| `setup` | onboard a machine (once) | interactive; refuses key-ceremony in an agent session |
| `add <NAME>` | store/update one secret | value via **STDIN**; `NAME` = `^[A-Za-z_][A-Za-z0-9_]*$` |
| `list [--format=json]` | see what exists | **names + rotate dates only**, never values |
| `run [--no-egress] -- <cmd>` | run a tool with secrets | JIT-injected into that process; `--` required; bounds egress to `~/.config/secrets/egress.allow` when set (`--no-egress` opts out) |
| `doctor [--format=json] [--gates]` | check health / gate | exit `0` healthy, `1` if any ✗ |
| `pubkey [--copy]` | print your recipient key | **safe in an agent session** — public key only, never a secret |
| `share <NAME> --to <age1…\|github:user\|self>` | encrypt a secret to a colleague | **refuses in an agent session** (extracts a plaintext value); `--sign` emits a signature the recipient verifies manually |
| `receive` | ingest a pasted blob | **tty-gated** — refuses with no controlling terminal; blob on STDIN, confirm on `/dev/tty` |
| `backup [--repo owner/name] [--yes]` | push an off-machine copy | **ciphertext only** to a private GitHub repo via `gh`; never the age private key; safe in a session |
| `uninstall [--dry-run]` | remove everything | human-gated; `--dry-run` previews |

Wrappers `claude-agent` / `cursor-agent` are `run` specialized for those tools. `rotate` and `demo`
are reserved for v0.2 and exit `2` if called.

## Recipes (copy these)

```sh
# Add a secret you already hold in a variable — value never hits argv or the screen
printf '%s' "$THE_VALUE" | agent-secrets add ANTHROPIC_API_KEY

# Check whether a secret exists (names only; safe)
agent-secrets list --format=json | jq -e '.[] | select(.name=="ANTHROPIC_API_KEY")' >/dev/null \
  && echo present || echo absent

# Use a secret WITHOUT ever reading its value: inject and run
agent-secrets run -- your-tool --that-needs ANTHROPIC_API_KEY

# Prove injection works without displaying the value (byte count only)
agent-secrets run -- printenv ANTHROPIC_API_KEY | wc -c      # >1 means present

# Health-gate before doing work; branch on exit code
if agent-secrets doctor >/dev/null 2>&1; then echo healthy; else agent-secrets doctor; fi

# Machine-readable health for decisions — the payload is an OBJECT:
#   {"checks":[{category,status,check,detail}],"exit":0|1}   (status ∈ ok|attn|bad; exit=1 iff any "bad")
# List the failing checks (iterate .checks, match "bad" — NOT .[] / "fail"):
agent-secrets doctor --format=json | jq '[.checks[] | select(.status=="bad")]'
```

## Environment variables

| Var | Effect |
|---|---|
| `AGENT_SECRETS_HOME` | base dir for all state (default `$HOME`). **Set to an isolated temp dir to test/CI without touching the real machine.** |
| `AGENT_SECRETS_PLAIN` / `NO_COLOR` | plain output (no color/box-drawing) — use when capturing output |
| `AGENT_SECRETS_UNATTENDED` | `setup` runs non-interactively with **fake placeholder** values (tests only); reads the first value from STDIN |

⚠️ The macOS login Keychain is **not** scoped by `AGENT_SECRETS_HOME`. When testing, put a mock
`security` on `PATH` (see `tests/mocks/`) so you never touch the real Keychain.

## Exit codes

`0` success · `1` runtime error (read the message — it is names-only and tells you the fix, e.g.
"run: agent-secrets setup") · `2` usage error / unknown command / reserved verb. `doctor` returns `1`
specifically when any check is ✗ — use it as a boolean gate.

## What NOT to do

- ❌ Print a value to confirm it — use `list` (names) or `run -- printenv X | wc -c` (length) instead.
- ❌ Put a value on the command line (`add NAME value`) — pipe it via STDIN.
- ❌ Run `setup`'s key ceremony inside your own session — it will refuse; that is correct.
- ❌ Run `uninstall` to "clean up" without explicit human intent — it is a destructive, gated action.
- ❌ Use a Model Context Protocol (MCP) server or command that returns a raw secret value — it lands in the transcript.

## More

`README.md` (human overview + diagrams) · `SECURITY.md` (threat model, honest ceiling) · `agent-secrets help --json` (the authoritative surface).
