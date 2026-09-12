---
status: complete
---

# One-command setup — the claim, measured and repaired

**Trigger:** operator directive 2026-09-11 — *"dry run our agent-secrets install and setup and
validate that it truly is a 'one command' setup … it was cumbersome, many steps, faulty steps, and
an unresponsive UI when there was window width resizing."*

**Scope (frozen):** make the README's documented one-liner deliver a complete, correct, legible
setup on a first run for a non-technical user, and prove it with a re-runnable PTY harness. Every
existing security invariant holds (names-only, agent-session refusal, fail-closed store writes,
manifest-complete uninstall).

## Phase 0 — Execution locus

**L — lead-inline, single agent, sequential.** Justification (the one line T/L owes): every finding
below lands in the same four files (`lib/ui.sh`, `cmd/setup.sh`, `install.sh`, `cmd/doctor.sh`) and
the `ui.sh` change re-renders the output that every other file's fix is verified against — teammates
in worktrees would serialise on one file and reconcile by hand. This is the same call
`ONBOARDING_UX_REBUILD.md` Phase 0 made and recorded as correct for the same file set. Read-only
verification fans out at the end.

---

## What the dry run measured

Method: the real published one-liner and the real wizard, driven over a PTY at 80×24 by
`expect(1)`, in a synthetic `AGENT_SECRETS_HOME`, with `security`/`pbcopy` mocked so the real
login Keychain and clipboard are never touched. Harness lands as `tests/one_command.exp`.

### B1 — the published one-liner installs the PRE-REBUILD wizard  ⟵ the headline

`v0.1.1` was tagged **2026-07-14**. The entire F1–F7 onboarding rebuild landed on `main`
**2026-08-16** and was never released. So
`bash -c "$(curl … /v0.1.1/install.sh)"` — the command in the README, and the command the operator
ran — installs exactly the software that produced the bad first run. Reproduced live: the v0.1.1
wizard still prints *"Your PRIVATE key is on the clipboard — paste it into your password manager
now"* and still gates the destructive delete on an unverified Yes/No.

**Every other fix in this document is unreachable by a real user until a release is cut.**

### B2 — `AGENT_SECRETS_LIB: unbound variable` on the installer's consent screen

`install.sh` sources `lib/common.sh` without setting `AGENT_SECRETS_LIB`, and runs under `set -u`.
`agsec_version()` (`common.sh:155`) dereferences it. Two consequences, both live:

* a raw bash error prints in the middle of the "may I write to your files?" preview — the single
  most trust-sensitive screen in the install;
* the integrity marker written into every machine-wide rule block reads `version=` **empty**, so
  `doctor`'s staleness comparison can never match.

### B3 — `ui_confirm` silently discards its default under gum

`lib/ui.sh:20` is `gum confirm "$prompt" && return 0 || return 1` — the `$def` argument is dropped.
`gum confirm` defaults to **Yes**. So `_confirm "Arm it now?" n` (`setup.sh:244`, declared default
**no**) answers **YES** on Enter: a user pressing Enter to skip is dropped into
`Paste your canary/tripwire token:`. The plain branch honours the default; the gum branch inverts
it, and the `[y/N]` hint that would have revealed it is never shown.

### B4 — the resize complaint is gum, and it is measured

Driving a resize 80→46 mid-prompt:

* the question **truncates mid-word** — `Populate your login Keychain now for prompt-f` — the user
  loses the end of what they are answering;
* every gum call emits `ESC]11;?ESC\` (OSC-11 background query) + `ESC[6n` (cursor report) and waits
  for the terminal to answer. Those leak as visible `]11;?\` garbage in the transcripts above, and
  against a terminal that does not answer they are an apparent hang — the "unresponsive UI";
* `gum style --border rounded` draws a fixed-width box that can never reflow.

gum is used in exactly three places (`ui_title`, `ui_confirm`, `ui_menu`), is already `optional` in
`deps.sh`, and buys a Yes/No and a four-item list. It is removed.

### B5 — hard-wrapping at 80 defeats terminal reflow

F5 fixed narrow terminals by hard-wrapping prose to 80 columns across multiple `ui_say` calls. A
hard-wrapped line is frozen: it is broken at 46 columns *and* at 120, and no emulator can reflow it.
Emitting one logical line per message and keeping it short is better at every width.

### B6 — `curl … | bash` cannot complete, though the human is at a terminal

`setup` and the installer both gate on `[ -t 0 ]`. Under the universally-known `curl … | bash`
idiom stdin is the pipe, so the ceremony defers even though a real terminal is right there. The
fix is the standard one and removes the "silently stores an empty first secret" hazard entirely:
read the ceremony from `/dev/tty`. The agent-session refusal is a *different* condition and stays
exactly as strict.

### B7 — the deferral screen states two causes and prints a false sentence

It says the ceremony was skipped "(a coding-agent session, **or** a non-interactive install with no
terminal)" — the tool knows which. It then always prints *"this piped install skipped the opt-in
prompt …"*, which is false whenever the prompt ran and the user answered it (reproduced above).

### B8 — first-run noise and homework

`[2/7]` is the first step the user sees; two unlabelled `Public key: age1…` lines print before any
explanation; the done screen ends on two ⚠, an `rm` of a 116-character path wrapped across three
lines, and a manual Cursor paste.

---

## Definition of done

1. The published one-liner installs the current wizard.
2. A first run completes to the done screen with **no bash error, no terminal-query garbage, and no
   line over 72 columns**, at 46, 80 and 120 columns, and across a mid-prompt resize.
3. Every confirm honours its declared default, and the default is visible.
4. `curl … | bash` in a real terminal completes the ceremony; an agent session still refuses.
5. The deferral names the one cause that applies and prints nothing false.
6. `bats tests/` green, `shellcheck` clean, and the PTY harness is committed so the claim cannot rot.

---

## Status log

- **2026-09-11** — Dry run performed against the **published** one-liner and against `main`, over a
  PTY at 80×24, `security`/`pbcopy` mocked, synthetic `AGENT_SECRETS_HOME`. B1–B8 above are all
  from those runs; none is hypothetical.
- **2026-09-11** — **B2–B8 fixed and landed**, five commits:
  `8933250` (B2/B6 foundation: `agsec_root()`, `agsec_have_tty`/`agsec_attach_tty`) ·
  `2a58301` (B3/B4: gum removed from `ui.sh`, `deps.sh`, `doctor.sh`; per-row commands;
  token-safe wrapping) · `6abbdc4` (B5/B6/B7/B8: `/dev/tty` attach, honest deferral, opt-in
  recovery save, 1-based screens, keygen banner, done screen) · `657dbcb` (locks + README +
  version) · `f3e8c57` (the `rm` footgun and a triplicated hint).
  **Gate: 236 bats pass / 0 fail · shellcheck exit 0.**

### The result, measured the same way the defects were

Real `install.sh` against a local release mirror built from `HEAD`, one PTY, 80×24:

| | before | after |
|---|---|---|
| user actions, minimum path | 8 + a password-manager round trip | **7** |
| reaches the done screen | no (v0.1.1 aborts at `[4/7]`) | **yes** |
| shell errors on screen | 2 (`unbound variable`) | **0** |
| terminal-query garbage (`]11;?\`) | on every prompt | **0** |
| lines over 72 columns | 3 | **0** (paths excepted, deliberately whole) |
| resize 80→46 mid-flow | question truncated mid-word | **no damage** |
| defaults that do what they say | canary inverted (Enter armed it) | **all** |

### Durable learnings

1. **A hard wrap is a promise you cannot keep.** F5 fixed narrow terminals by wrapping prose to 80
   columns. That freezes the line: broken at 46 *and* at 120, and no emulator can reflow it. One
   short logical line per message is better at every width, and it is the only form that survives a
   resize. `fold -s` compounds it by splitting an over-long token, which is how a store path became
   unpastable — the one thing a path is for.
2. **A widget that owns the terminal owns every failure mode in it.** gum cost a silently inverted
   default, a truncating resize, two blocking capability queries and a vendored binary — to render a
   Yes/No. The measured cost of an interactive dependency is paid on every prompt, forever; the
   benefit was cosmetic.
3. **`[ -t 0 ]` answers "is stdin a terminal", which is not the question.** The question is "is there
   a human here", and under `curl … | bash` those differ. Conflating them turned the best-known
   install idiom into a two-command flow and risked storing an empty secret from a dead pipe.
   `/dev/tty` is the answer — and it is NOT a loosening, because the agent-session refusal is a
   separate condition checked first.
4. **Shipping is part of the fix.** The F1–F7 rebuild was correct, tested, landed — and unreachable
   for 26 days because no tag was cut. A fix on `main` behind a pinned installer is a fix nobody has.
   The version bump is now covered by a test (`tests/install.bats` derives its TAG from `VERSION`),
   but nothing yet asserts that the pinned tag actually exists. That gap is real and unclosed.

---

## Fresh-macOS verification (2026-09-11)

**Question asked:** does this work on a Mac with no Xcode, no Homebrew, no Python, no Node, no
iTerm2, no oh-my-zsh?

**Method.** The installer was run over a PTY with `PATH=/usr/bin:/bin:/usr/sbin:/sbin` and Homebrew
variables unset — so `brew`, `age`, `sops`, `node` and every Homebrew/fnm/pyenv tool were genuinely
invisible — into an empty synthetic `$HOME`. `security` and `pbcopy` stayed mocked so the real login
Keychain and clipboard were untouched; both were then verified separately against the real binaries.

**Result: the install and the wizard completed, 6 user actions, `[1/6]` → `[6/6]`, no failures.**

| Surface | On a stock Mac | Verdict |
|---|---|---|
| shell | `/bin/bash` **3.2.57** | the entire tool ran under it — no re-exec, no bash 4 idiom |
| `curl` `tar` `awk` `sed` `grep` `stty` `mktemp` `launchctl` `security` `pbcopy` `fdesetup` | present | ✓ |
| `shasum` (the integrity gate) | a **Perl script**; `/usr/bin/perl` is a real binary, not a stub | ✓ (Apple has deprecated Perl — a future macOS removing it breaks the digest check) |
| `age`, `sops` | absent | **downloaded**: arm64, ad-hoc *linker-signed*, **no `com.apple.quarantine`** (curl does not set it), executed — no Gatekeeper prompt, no `killed: 9` |
| `jq` | present from macOS 15 (`jq-1.7.1-apple`); absent ≤ 14 | both paths verified; the fetch returns a signed, quarantine-free arm64 jq 1.8.2 |
| Homebrew / Node / Python / oh-my-zsh / iTerm2 | absent | never consulted |
| `~/.zshenv` | does not exist | created, `0600`, marker-delimited |
| a coding agent to teach | none installed | correctly reports "no writable agent surfaces detected" and skips |
| login Keychain | real `security` | the no-argv `-w` path prompts `password data for new item:` then `retype password for new item:` and writes — **exactly the text the wizard tells the user to expect** (F4). Verified with a throwaway service name, then deleted. |

### The defect this question exposed — `command -v` lies about developer tools

macOS ships **inert stubs** at `/usr/bin` for `git`, `python3`, `clang`, `make`, `swift` and `lldb`.
Measured: all six are the same 118,864-byte binary (`sha256 7f30f076…`) embedding
`com.apple.dt.xcode_select.tool-shim`. On a Mac without Apple's developer tools they still **exist**,
so `command -v git` **succeeds**, and the first real call posts a GUI installer dialog and exits
non-zero.

The install and the wizard never call a shimmed tool — that was checked line by line and is clean.
But `cmd/backup.sh` ran `agsec_require git`, which on a fresh Mac passes and then pops that dialog.
Fixed: `agsec_have_devtool()` probes `xcode-select -p` (a real binary, never a dialog, fails exactly
when no toolchain is installed) and treats any copy outside `/usr/bin` as real by definition.
`backup` now refuses with `xcode-select --install`, and `doctor` reports git as a placeholder rather
than as usable. Five locks in `tests/one_command.bats`, including a precondition asserting that
`agsec_have git` says yes while `agsec_have_devtool git` says no.

### Target platform — Apple silicon (operator ruling, 2026-09-12)

**Intel (`x86_64`) is out of scope, not an open gap.** Asked whether the fresh-macOS affirmation
held, the operator ruled: *"you can presume its mac chip."* The verification above was performed on
arm64, and that is the platform the claim covers.

`deps.sh` keeps its pinned `x86_64` digests and the `deps_arch` mapping — they cost nothing, and
removing them would break an Intel user for no gain — but no Intel Mac has executed a fetched
binary, and this document does not assert that it works. If Intel ever becomes a target, that run is
the thing to do; it is not a defect to chase now.

### v0.1.2 released, and the published one-liner verified against it (2026-09-12)

`v0.1.2` is cut: tag `eebef4474`, release assets uploaded, `install.sh` served at the tag carrying
`EXPECTED_SHA256="84ce52fe…"`, which matches the published tarball byte for byte.

The last unverified hop is now closed. The **exact README one-liner** — no mirror, no
`AGENT_SECRETS_BASE_URL`, no overrides — was run over a PTY on a stock
`PATH=/usr/bin:/bin:/usr/sbin:/sbin`:

```
Downloading v0.1.2…            SHA-256 verified.
age: fetching pinned, SHA-256-verified binary (no sudo)…
sops: fetching pinned, SHA-256-verified binary (no sudo)…
jq: using /usr/bin/jq
[1/6] … [6/6]                  ### ONE-LINER EXIT=0 ###
```

6 user actions, 0 shell errors, 0 terminal-query bytes, `agent-secrets 0.1.2` installed, and the
store it produced decrypts and lists. **The claim in the README is now a measured fact about the
software a stranger downloads.**

### The release script had the same defect the installer did

The first `release.sh v0.1.2` run was launched from a non-interactive shell. Its `[y/N]` read EOF,
`|| a=''` treated the absence of an answer as **no**, the tag move was skipped, the script did all
the remaining work anyway, and it died at the very end with a digest-mismatch error naming the wrong
cause. Fixed the same way as `setup`: attach `/dev/tty` when there is one, refuse on the FIRST screen
when there is not, and treat EOF as a hard stop rather than a silent "no". There is still no
unattended mode, deliberately.

### What is NOT verified

* **macOS versions other than 15.7.9**, and any machine under MDM/managed-policy (the installer
  defers on those by design; the defer path is covered by `tests/discovery.bats`, not by a live run).

### Known limitation, not fixed here

`AGENT_SECRETS_KC_SERVICE` is the fixed string `agent-age-key`, and the login Keychain is not
`$HOME`-scoped. A second install on the same Mac — or a test run that does not mock `security` —
would `-U` (update) over the existing entry. Harmless for one user with one install, which is the
documented model, but it means the Keychain leg cannot be exercised in place without clobbering a
real key. That is why the PTY runs mock `security` and the real prompt was proven separately.
