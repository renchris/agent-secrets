---
status: complete (release cut pending — operator-gated)
---

# Agent entrypoint — zero-human setup, and fewer touchpoints for the human one

**Trigger:** operator `/goal` 2026-09-17 — *"improve agent-secrets to be fully setup and use
available via agent entrypoint (i.e. Claude Code) WITHOUT any interactive blockers that a human has
to get involved in; zero human-in-the-loop. AND make the setup as close to a one-command setup as
possible, eliminating as many touchpoints as possible if a user wishes to be the entrypoint."*

The failure it names, verbatim from a live session the same day: an agent found the repo, checked
`~/.config/sops/age/keys.txt` (wrong path), read AGENTS.md rule 5 ("the setup key-ceremony is
human-gated"), and handed the human the install one-liner with *"Run it in a terminal, not here"*.
It was right — that is what the software did. The human became the runtime.

**Scope (frozen):** (1) an agent session (Claude Code / Cursor) can install AND fully set up
agent-secrets — real keys, Keychain custody, wrappers, `apiKeyHelper`, machine-wide discovery — with
no human step, and can then `add`/`run` secrets from values it already holds; (2) the human wizard
loses every prompt that does not earn its keystroke; (3) every existing security invariant holds:
names-only (no key or value ever on stdout/stderr/argv/clipboard in headless mode), fail-closed
store writes, manifest-complete uninstall, the agent-session refusal for `share`.

## Phase 0 — Execution locus

**L — lead-inline, single agent, sequential.** The one line T/L owes: every change lands in
`cmd/setup.sh`, `lib/keychain.sh`, `install.sh`, `cmd/doctor.sh` and their tests, and each file's
behaviour is verified against the others' output — the same file set and the same call the two
previous onboarding plans made and recorded as correct. Read-only verification (the full bats
suite, shellcheck, a synthetic-HOME end-to-end) runs after each commit.

---

## What was measured before writing (2026-09-17)

### M1 — the agent path is a deliberate dead end today

`install.sh` in an agent session (`CLAUDECODE=1`) unpacks, wires PATH and wrappers, skips the
discovery opt-in (tty-only), then prints *"Open Terminal.app and run `agent-secrets setup`"* and
exits 0. `setup` in an agent session dies: *"refusing the key ceremony inside an agent session"*.
The only non-interactive mode, `AGENT_SECRETS_UNATTENDED=1`, is a **test** mode: it stores a fake
`ANTHROPIC_API_KEY` placeholder and **deletes** the recovery key. It is not an agent mode.

### M2 — the refusal's premise does not hold for a headless ceremony

The refusal exists because the wizard puts key material on the clipboard and reads a secret from a
hidden prompt, and an agent's pty is transcript-captured. A ceremony that mints keys **to files**,
hands the Keychain its key **over a pipe**, imports a secret **from the agent's own environment**,
and prints only names, paths and status never has a secret near the transcript. Every value path in
headless mode is enumerated in § Design and none reaches a fd the harness records.

### M3 — `security -i` populates the Keychain with no argv and no tty  ⟵ the enabler

Measured on macOS 15 against the real login Keychain with a throwaway service, then deleted:

```
printf 'add-generic-password -U -a "%s" -s "%s" -w "%s"\n' … | security -i   → rc 0
security find-generic-password -s <svc> -w                                     → matches, rc 0
```

`security -i` reads its command language from **stdin**, so the key transits a pipe from an
in-process read of the 0600 file — never `ps`, never the clipboard, never a terminal. This is the
"no-argv Keychain-write flow" `lib/keychain.sh` said was unsettled, and it is what lets headless setup
end on **primary** custody instead of "degraded (file custody)". It also deletes the human wizard's
worst screen: the invisible `password data for new item:` double-paste (F4).

A second finding on the way: the existing interactive populate did `pbcopy <"$kf"` — the **whole**
key file, comment lines included — into a `getpass`-style prompt that reads **one line**. The first
line of an age key file is `# created: …`. That path could not have stored the key; every PTY run on
record answered `n` to it.

### M4 — `apiKeyHelper` wired with no key BREAKS Claude Code for every Max/OAuth user

From the Claude Code authentication docs (`code.claude.com/docs/en/iam`, read 2026-09-17):
`apiKeyHelper` is credential precedence **#4**; the claude.ai `/login` subscription is **#7**. And:
*"when the script exits with an error, times out, or prints nothing, requests fail with `Your
apiKeyHelper script is failing` within three attempts."* Today's wizard wires the helper
unconditionally. Skip the first secret — a documented, supported path — and the next Claude Code
session fails auth. The operator's own machine has the store installed and the helper **unwired**,
which is the workaround a user finds by hand. Headless setup stores no secret by default, so this
would have been its steady state. `doctor` compounds it: "apiKeyHelper — empty output" is a ✗, so the
health gate an agent is told to trust reads red on a correct install.

### M5 — the touchpoints, counted

Human wizard minimum path before: **6–7 actions** (consent Enter, recovery y/n, Keychain y/n + two
invisible pastes, first-secret menu + value, canary y/n). Of those, the Keychain paste is now
mechanical (M3) and the canary is a default-`no` prompt 99% of users press Enter on. The recovery
prompt is kept: it is the one keystroke with a security consequence (the dead-Mac case) and
declining is first-class.

---

## Design

### `agent-secrets setup --headless`

Real keys, no prompts, no secret on any fd. Auto-selected whenever there is no human to prompt — an
agent session, or no attachable tty (ssh without `-t`, cron, CI) — and forceable with the flag. The
agent-session **refusal is replaced** by this mode, because M2 removes its premise; `share` keeps
its refusal (it extracts a plaintext value).

| Screen | Interactive | Headless |
|---|---|---|
| keys | mint primary + recovery; offer the off-machine save | mint both; recovery.key **stays** 0600 on disk (the documented "later" path); `doctor` reminds; a human proves it later with `setup` |
| Keychain | populate over stdin, no prompt | same — ends **primary** |
| first secret | menu + hidden value | `--import-env NAME[,NAME…]`: each NAME present and non-empty in the environment is piped from `${!NAME}` into the store; absent names are reported by name and skipped; nothing else is read (no stdin, no timeout) |
| canary | prompt removed; `doctor` reminds with the exact command | skipped |
| wire | wrappers; `apiKeyHelper` **only if** `ANTHROPIC_API_KEY` is in the store (M4) | same |
| discovery | the installer's interactive, informed opt-in (unchanged) | written by default (advisory, reversible, integrity-marked; the plan is printed); `--no-discovery` skips |
| done | clipboard + Cursor paste | no clipboard; prints the absolute binary path (the agent's shell predates the PATH line) and the two things only a human can do, if any |

`setup --discovery` is a standalone screen (like `--keychain`): the one-command later opt-in that
used to be "re-run the installer". `setup --keychain` now works in an agent session.

`add ANTHROPIC_API_KEY` wires `apiKeyHelper` the moment the key exists, through the same reversible,
manifest-recorded edit — so "add the key later" completes the wiring instead of leaving Claude Code
on its login with a store it never reads.

### `install.sh`

Flags: `--dry-run` (as before), `--headless`, `--import-env NAMES`, `--no-discovery`. In an agent
session or with no tty the installer now **chains straight into `setup --headless`** instead of
deferring; the deferral screen is gone. `AGENT_SECRETS_UNATTENDED=1` (tests) is unchanged.

### `doctor`

`apiKeyHelper` rows distinguish *no `ANTHROPIC_API_KEY` stored* (⚠, optional — Claude Code uses its
own login; the fix is `add`) from *stored but not wired / helper failing* (✗). A correct headless
install exits 0.

---

## Definition of done

1. In a synthetic HOME with `CLAUDECODE=1` and stdin `/dev/null`, the real `install.sh` completes
   setup: keys, primary custody (mock Keychain), store, wrappers, discovery block, `doctor` exit 0.
2. `setup --headless --import-env A,B` with `A` set stores `A`, names `B` as skipped, and the value
   of `A` appears nowhere in the output.
3. No `AGE-SECRET-KEY` and no imported value in any headless output; no clipboard call in headless.
4. The interactive wizard's minimum path is ≤3 actions and the Keychain populate needs no paste.
5. `bats tests/` green, `shellcheck` clean, the PTY harness updated for the removed prompts.
6. AGENTS.md / README / llms.txt / `help --json` tell an agent the truth: setup is autonomous.

## Status log

- **2026-09-17** — M1–M5 measured (all live, none hypothetical); plan written; implementation
  started on `main` at `54ee8dc`.
- **2026-09-17** — **Landed on `main`, five commits:** `8c379c5` (Keychain over stdin via
  `security -i`; mock honours `-i`) · `8a40450` (headless `setup`: auto in an agent session / no tty,
  `--headless`, `--import-env`, `--discovery`, `--no-discovery`; recovery key kept; canary and
  Keychain prompts removed; conditional `apiKeyHelper` wiring in `lib/wire.sh` + `add` completes it;
  `doctor` rows; `install.sh` flags + chaining; install tests archive the working tree; 19 locks in
  `tests/headless.bats`) · `b490357` (docs: AGENTS.md, README, llms.txt, SECURITY.md, FAQ,
  `help --json`) · `c56dacc` (version bump to 0.1.3). **Gate: 260 bats pass / 0 fail · shellcheck exit 0.**
  Not yet cut: the `v0.1.3` tag + release (operator-gated) — until then the README one-liner points
  at a tag that does not exist, exactly as the `0.1.1 → 0.1.2` bump did before its release.

### The result, measured the same way the defects were

| | before | after |
|---|---|---|
| agent session, one command → usable tool | **no** — exit 0 with "open Terminal.app and run setup" | **yes** — keys, primary custody, store, wrappers, discovery, `doctor` 0 |
| secret bytes in a headless transcript | n/a (refused) | **0** (`AGE-SECRET-KEY` and the imported value grep 0; locked) |
| custody after a non-interactive setup | file ("degraded") | **primary** (Keychain over stdin) |
| `doctor` after skipping the first secret | **✗** (helper "empty output") and Claude Code auth broken | ⚠ optional, exit 0, Claude Code on its own login |
| human wizard, minimum path | 6–7 actions | **2** (recovery: `n` · secret: `4`) — PTY-locked |
| invisible Keychain double-paste | present | gone (no paste in any mode) |
| later opt-in to discovery | re-run the installer | `agent-secrets setup --discovery` |

### Durable learnings

1. **A refusal guards a mechanism, not a mode.** "Setup refuses in an agent session" was really
   "the clipboard and the hidden prompt must not meet a transcript". Name the mechanism and the
   mode can be rebuilt without it; name the mode and every agent obeys the refusal forever.
2. **`security -i` is the no-argv, no-tty Keychain write.** `-w` with no value is a tty prompt;
   `-w` with a value is argv; `-i` takes the whole command on stdin. Store only the identity line —
   a one-line Keychain value holding a key file's first (comment) line decrypts nothing, which is
   also why the old whole-file clipboard paste could never have worked.
3. **A credential helper outranks the login it is meant to supplement.** Claude Code tries
   `apiKeyHelper` before `/login` and fails closed when it prints nothing. A helper must be wired
   only when it has something to serve, and the moment it does (`add ANTHROPIC_API_KEY`) is the
   moment to wire it — not setup time.
4. **Tests that archive `HEAD` test the previous commit.** `git archive HEAD` in a harness makes
   every uncommitted change invisible and a new lib file a phantom; build the mirror from the
   working tree with the same `export-ignore` filter the release uses (`git check-attr` matches a
   directory pattern only against the directory path with its trailing slash — check the ancestors).
5. **A default-`no` prompt is a touchpoint that carries no information.** The canary question was
   answered "Enter" on every recorded run; `doctor` already named the command. Delete the prompt,
   keep the command.
