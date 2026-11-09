# shellcheck shell=bash
# lib/help.sh — the single source of truth for CLI help, for HUMANS and AGENTS.
# Renders detailed per-verb help (human) AND a machine-readable manifest (`help --json`) from ONE
# spec, so an agent can fully understand and drive agent-secrets with no human in the loop.
# Sourced after common.sh. Names-only: nothing here handles a secret value.
#
# Spec format (agsec_help_spec): tab-separated `VERB<TAB>FIELD<TAB>A[<TAB>B]`, one row per line.
#   FIELD ∈ synopsis|summary|desc|reads|writes|namesonly (scalar → A)
#          | flag|arg|example|exit|env|seealso        (pair   → A=key/name, B=description)
# VERB "" = top-level (agent-secrets itself). A flag key is `[-x, ]--long[ <HINT>]`: the JSON manifest
# derives each flag's type and value_hint from it. Every example must pass the AGSEC_PARSE_ONLY seam
# (tests/help.bats).

AGSEC_VERBS="setup add list run doctor uninstall share receive pubkey backup"

agsec_help_spec() {
  # NOTE: keep this the ONLY place command facts live; both renderers below read it.
  cat <<'SPEC'
	synopsis	agent-secrets [--plain] [--no-color] [--non-interactive] <command> [args]
	summary	Machine-wide secrets for coding agents — encrypted at rest (sops+age), injected just-in-time, names-only.
	desc	Every command shows NAMES and status only; a secret VALUE is never printed, logged, or written outside the encrypted store. Values move in via STDIN (never argv) and out only into a launched process's environment or the Claude Code apiKeyHelper.
	flag	--plain	force plain output (no colors/box-drawing); also via AGENT_SECRETS_PLAIN=1 or NO_COLOR=1
	flag	--no-color	disable ANSI color only
	flag	--non-interactive	never prompt: a step that needs an answer stops with exit 2 instead (setup runs headless); also via AGENT_SECRETS_NONINTERACTIVE=1 or a non-empty CI
	flag	-h, --help	show help; with --json, the same facts as JSON
	flag	-v, --version	print the version and exit
	flag	--json	with help: emit the full machine-readable command manifest (for agents)
	env	AGENT_SECRETS_HOME	base dir for all state (default $HOME; empty = $HOME); set to an isolated dir for tests/CI
	env	AGENT_SECRETS_PLAIN	1 = plain output (no color/gum), accessibility + scripting
	env	NO_COLOR	standard: any value disables color
	env	FORCE_COLOR	non-empty: color even when piped (0 = never); ignored inside an agent session; NO_COLOR and --plain win
	env	CI	non-empty: non-interactive (same as --non-interactive)
	exit	0	success
	exit	1	runtime error (see the message; names-only)
	exit	2	usage error / unknown command / reserved verb, or input or a confirmation flag is required and nobody can be asked
	exit	130	canceled: a confirmation was declined or the run was interrupted (nothing more was changed)
	seealso	https://github.com/renchris/agent-secrets/blob/v0.1.3/AGENTS.md	agent-facing usage guide (read this first if you are an agent)
	seealso	https://github.com/renchris/agent-secrets/blob/v0.1.3/SECURITY.md	threat model + the honest ceiling
setup	synopsis	agent-secrets setup [--headless] [--import-env <NAME>[,<NAME>…]] [--no-discovery] | --discovery | --keychain | --restore
setup	summary	One-time onboarding: generate your keys, wire your tools. Interactive for a human; HEADLESS (no prompts, no human) in an agent session.
setup	desc	Idempotent — safe to re-run; detects an existing install and never mints a second key. INTERACTIVE (a human at a terminal): preflight → keys (recovery-key save offer) → first secret → wire wrappers → health check → done; the Keychain is populated with no paste. HEADLESS — auto-selected inside a coding-agent session (Claude Code / Cursor), with no attachable terminal, in non-interactive mode, or forced with --headless: the SAME real setup with zero prompts and NO secret on any output — keys are minted to files, recovery.key stays on disk (0600) for a human to save later, the login Keychain takes the key over a pipe (primary custody), a first secret enters ONLY via --import-env from variables already in the environment, machine-wide agent discovery is written by default (announced per file; --no-discovery skips), and the done screen names the absolute binary path plus any optional human follow-up. An AGENT CAN RUN THIS. apiKeyHelper is wired into ~/.claude/settings.json only once ANTHROPIC_API_KEY is in the store (a wired helper with nothing to print breaks Claude Code's auth); `add ANTHROPIC_API_KEY` completes the wiring. --discovery: only write the discovery rules (the later opt-in). --keychain: only the Keychain populate step (works headless). --restore: recover on a new machine — pipe or paste your saved age key to re-establish custody over a restored store copy (never mints a new key). --discovery, --keychain and --restore each run one step: use one at a time.
setup	flag	--headless	prompt-free setup with REAL keys (automatic in an agent session / with no tty): nothing read from a prompt, nothing secret printed
setup	flag	--import-env <NAME>[,<NAME>…]	headless: store each NAME that is set and non-empty in this process's environment (value moves variable → pipe → store; never argv, never shown); absent names are reported and skipped. Implies --headless
setup	flag	--no-discovery	headless: do not write the machine-wide agent rules (written by default; advisory, recorded in the manifest)
setup	flag	--discovery	write ONLY the machine-wide agent rules into every present harness's file (~/.claude/CLAUDE.md, ~/.codex/AGENTS.md, …) — the one-command later opt-in; idempotent
setup	flag	--keychain	restore prompt-free Keychain custody — re-runs just the populate step, over stdin (no paste, no tty; use when doctor reports "file custody")
setup	flag	--restore	recover on a new machine — paste (or pipe) your saved age key to re-establish custody over a restored store copy (never mints a new key)
setup	env	AGENT_SECRETS_UNATTENDED	1 = tests/CI ONLY: non-interactive with a FAKE placeholder first secret (deletes the recovery key). Not the agent mode — agents get real keys via headless
setup	example	agent-secrets setup	a human: the interactive wizard (two answers on the minimum path)
setup	example	agent-secrets setup --headless	an agent / CI: real keys, Keychain custody, wiring, discovery — no prompts, no secret printed
setup	example	OPENROUTER_API_KEY="$(cat ~/.x)" agent-secrets setup --import-env OPENROUTER_API_KEY	headless + seed one secret from a variable the caller already holds (the value never appears in the command)
setup	example	agent-secrets setup --discovery	later: make every coding agent on this Mac aware of agent-secrets
setup	example	agent-secrets setup --restore	recover on a new machine (copy your store copy into place first, then paste your saved key)
setup	example	agent-secrets setup --keychain	re-run only the Keychain populate step (doctor: file custody)
setup	writes	~/.config/secrets/{age.key,age.pub,recovery.key (headless: kept),recovery.pub,age-key-cmd.sh,secrets.env,.sops.yaml,manifest.toml}, ~/bin wrappers, ~/.claude/settings.json (apiKeyHelper, only once ANTHROPIC_API_KEY is stored), discovery blocks (headless default / --discovery)
setup	exit	0	setup completed (or returned early on an existing install)
setup	exit	1	a step failed (see message)
setup	exit	2	usage error (unknown option, a bad --import-env NAME list, or two step options that cannot be combined)
setup	namesonly	never prints the age key or any secret value; interactive input is hidden (read -s); headless reads no secret from any prompt and imports only from named environment variables
add	synopsis	agent-secrets add <NAME>
add	summary	Add or update ONE secret by name. The value is read hidden and never echoed.
add	desc	NAME must match ^[A-Za-z_][A-Za-z0-9_]*$. The value is read from STDIN when piped (scriptable/agent-friendly), otherwise from a hidden prompt. Upserts the encrypted store entry and its manifest.toml row (rotate_by defaults to +180d). Storing ANTHROPIC_API_KEY also wires the Claude Code apiKeyHelper. stdout: the stored NAME only, once everything succeeded; the receipt goes to stderr.
add	arg	NAME	the secret's name (e.g. ANTHROPIC_API_KEY); letters, digits, underscore; starts with a letter or _
add	example	printf '%s' "$ANTHROPIC_API_KEY" | agent-secrets add ANTHROPIC_API_KEY	pipe a value ALREADY set in your shell ($ANTHROPIC_API_KEY must be exported first); never on argv, nothing echoed
add	example	agent-secrets add ANTHROPIC_API_KEY	interactive: hidden prompt for the value — the simplest way, no shell variable to set
add	reads	STDIN (the value, if piped)
add	writes	~/.config/secrets/secrets.env, ~/.config/secrets/manifest.toml, ~/.claude/settings.json (apiKeyHelper, only for ANTHROPIC_API_KEY)
add	exit	0	stored
add	exit	1	no store yet (run setup), the store can't be decrypted, another write holds the store lock, or encrypt failed
add	exit	2	usage error (missing or invalid NAME, an unexpected argument, or an empty or multi-line value)
add	namesonly	the value is never printed, logged, or placed on argv
list	synopsis	agent-secrets list [--json]   (alias: ls)
list	summary	List secret NAMES (and rotation dates). Never values. Alias: `ls`.
list	desc	Prints the names in the store with their manifest.toml rotate_by dates. Use --json for a value-free machine-readable array an agent can parse. A store that can't be decrypted is an error, never an empty list.
list	flag	--json	emit a JSON array of {name, rotate_by}; no values
list	example	agent-secrets list	human-readable names + rotate dates
list	example	agent-secrets list --json	[{"name":"ANTHROPIC_API_KEY","rotate_by":"2027-01-06"}] (compact when piped)
list	reads	~/.config/secrets/secrets.env (names only), manifest.toml
list	exit	0	ok (prints a friendly note if the store is empty/absent)
list	exit	1	the store can't be decrypted
list	exit	2	usage error (unknown option or unexpected argument)
list	namesonly	prints names + metadata only; never a value
run	synopsis	agent-secrets run [--no-egress] -- <cmd> [args...]
run	summary	Run a command with secrets injected just-in-time, process-scoped.
run	desc	Decrypts the store and injects every entry into the child process's environment via `sops exec-env`, then runs <cmd>. The values live only in that process and die with it — never in a config, log, or your shell. The `--` separator is REQUIRED. If you have configured an egress allowlist (~/.config/secrets/egress.allow), run also starts a loopback CONNECT proxy and sets the child's HTTPS_PROXY so proxy-honoring tools can only reach allowlisted hosts (honest ceiling: a bound, not a jail — see SECURITY.md). Use --no-egress to opt a proxy-incompatible tool out.
run	flag	--no-egress	skip the egress-allowlist proxy for this run (for a tool that breaks behind a proxy); also via AGENT_SECRETS_NO_EGRESS=1
run	arg	-- <cmd> [args...]	the command to run with secrets in its environment (everything after -- is the command)
run	env	AGENT_SECRETS_NO_EGRESS	1 = skip the egress allowlist for this run (same as --no-egress)
run	example	agent-secrets run -- printenv ANTHROPIC_API_KEY | wc -c	prove injection without displaying the value (counts bytes)
run	example	agent-secrets run -- node server.js	run any tool with the secrets injected for that process only
run	exit	0	the child's exit code (128+n if it died of a signal)
run	exit	1	no store (run setup)
run	exit	2	usage error (missing `--`, no command, or an unknown option), or command not found
run	namesonly	values enter the child env only; the tool never prints them
doctor	synopsis	agent-secrets doctor [--json] [--redact] [--gates] [--summary] [--fix]
doctor	summary	Health check across custody, toolchain, store, backup, injection, discovery, hygiene, maintenance, supply-chain, onboarding.
doctor	desc	Each check reports ✓/⚠/✗ with NAMES and status only. Exit is 0 when there is no ✗, else 1 — so an agent can gate on it. Non-destructive by default; --fix applies only safe fixes.
doctor	flag	--json	machine-readable object {"checks":[{category,status,check,detail}],"exit":0|1}; exit=1 iff any status is "bad"; parse with jq '.checks[]|select(.status=="bad")' (status ∈ ok|attn|bad); no values
doctor	flag	--redact	replace any sensitive-looking token with a sha256: digest in output
doctor	flag	--gates	also run the execution gates (c: Keychain read, d: sops exec-env, e: egress allowlist + firewall)
doctor	flag	--summary	show only ✗ plus core custody/toolchain/store/injection status; hide optional hardening ⚠ (the quiet post-setup view — bare 'doctor' shows everything)
doctor	flag	--fix	apply SAFE fixes only (never runs without this flag)
doctor	example	agent-secrets doctor	human health report
doctor	example	agent-secrets doctor --json	parse status programmatically
doctor	example	agent-secrets doctor --gates	verify the deployment gates before an unattended run
doctor	exit	0	no ✗ checks
doctor	exit	1	at least one ✗ check
doctor	exit	2	usage error (unknown option)
doctor	namesonly	reports names/status only; verifies values are non-empty via length, never prints them
uninstall	synopsis	agent-secrets uninstall [--dry-run]
uninstall	summary	Remove everything this tool installed (manifest-driven, total). Prompts before touching your secrets.
uninstall	desc	Reverses every recorded change: files, wrappers, the PATH block, the launchd job, the settings.json edit, and the Keychain item (the exact agent-age-key service). Then ASKS whether to keep or delete your encrypted store + keys (a real STOP-ASK, no --force bypass); with nobody to ask it keeps them. --dry-run prints the full plan and changes nothing. If some records can't be rolled back, they stay in the install manifest so a re-run can retry them.
uninstall	flag	--dry-run	print the rollback plan; mutate nothing
uninstall	example	agent-secrets uninstall --dry-run	preview exactly what would be removed
uninstall	example	agent-secrets uninstall	perform the removal (interactive keep-or-purge prompt for your store)
uninstall	writes	removes tool artifacts; store/keys only on explicit purge confirmation
uninstall	exit	0	uninstall completed, dry-run printed, or nothing to roll back
uninstall	exit	1	partial rollback (failed records kept in the install manifest for retry) or error (corrupt manifest, missing jq)
uninstall	exit	2	usage error (unknown option, or any argument — only --dry-run or --help)
uninstall	namesonly	enumerates artifacts by name; never reads a secret value
share	synopsis	agent-secrets share <NAME> --to <age1…|github:user|self> [--singleton] [--verify] [--sign] [--rename <NAME>]
share	summary	Encrypt ONE secret to a colleague's key; ladder-gated, names-only. Refuses in an agent session.
share	desc	The don't-share ladder runs FIRST (offer a scoped/least-privilege alternative before any value moves), then a single [y/N] recipient confirm showing the key fingerprint + NAME. Encrypts the one value with age to the recipient's public key and prints a paste-able v1 envelope (armored ciphertext + NAME + digest). The digest is advisory (an accidental-mismatch readback) unless --verify makes it a required out-of-band step. Never auto-rotates. Refuses inside an agent session (transcripts are secret-bearing) and without an interactive terminal (no flag skips that gate).
share	arg	NAME	the secret to share (must already exist in your store)
share	arg	--to <recipient>	age1… recipient string, github:USER (fetch their key), or self (re-encrypt to your own key)
share	flag	--singleton	assert this is a true singleton (webhook/HMAC/account-only key) to bypass the R2 ladder rung
share	flag	--verify	require the out-of-band digest readback before the envelope is emitted
share	flag	--sign	attach a signature leg so the recipient can authenticate the sender
share	flag	--rename <NAME>	label the envelope so the recipient stores it under this NAME instead of the original
share	env	AGENT_SECRETS_UNATTENDED	1 = auto-answer the y/N confirm (CI); the interactive-terminal, ladder + canary hard-errors still apply
share	example	agent-secrets share ANTHROPIC_API_KEY --to github:dana	encrypt to dana's GitHub age key; prints an envelope to paste
share	reads	~/.config/secrets/secrets.env (the one NAME only), manifest.toml
share	writes	the manifest sharing row for NAME (shared_with/shared_at/direction=sent; values-free)
share	exit	0	envelope emitted
share	exit	1	no such NAME, the store can't be decrypted, a recipient key that can't be used, or refused (agent session / ladder / canary)
share	exit	2	usage error (unknown option, bad NAME or recipient form), or no interactive terminal
share	exit	130	canceled at the y/N confirm or the --verify digest check (nothing shared)
share	namesonly	the value is encrypted to the recipient and never printed; only ciphertext + the NAME leave
receive	synopsis	agent-secrets receive [--rename <NAME>] [--yes-i-reviewed]
receive	summary	Ingest a pasted share envelope on STDIN, decrypt, store — never displayed. tty-gated.
receive	desc	Reads a v1 envelope blob from STDIN and takes every confirm from /dev/tty (hard-refuses when no tty is present, except --yes-i-reviewed for CI which still runs the canary/collision hard errors). Recomputes the digest locally over the base64-decoded ciphertext (advisory) for an out-of-band voice-compare, rejects unknown envelope versions, hard-refuses the in-store canary name, and asks before overwriting an existing NAME (under --yes-i-reviewed it hard-stops; use --rename). The decrypted value is piped straight into the encrypted store. v0.1 stores SINGLE-LINE values only — a multi-line envelope (PEM/JSON blob) is refused (multi-line/file secrets are a v0.2 item). stdout: the stored NAME only.
receive	flag	--rename <NAME>	store the received secret under this NAME (use when the envelope's NAME collides or you prefer a local name)
receive	flag	--yes-i-reviewed	non-interactive ingest for CI; skips the tty prompts but keeps the canary/collision hard errors
receive	env	AGENT_SECRETS_HOME	base dir for all state (default $HOME; empty = $HOME); set to an isolated dir for tests/CI
receive	example	agent-secrets receive	run, then paste the envelope on STDIN and press Ctrl-D
receive	reads	STDIN (the pasted v1 envelope)
receive	writes	~/.config/secrets/secrets.env, manifest.toml (direction=received, source=received:peer)
receive	exit	0	stored
receive	exit	1	bad/unknown-version envelope, canary name, NAME collision under --yes-i-reviewed, no local age key, or the store can't be decrypted
receive	exit	2	usage error, a MULTI-LINE value (v0.1 stores single-line secrets only), or no tty (without --yes-i-reviewed)
receive	exit	130	canceled at the overwrite confirm (the existing NAME is left unchanged)
receive	namesonly	the decrypted value goes straight into the store, never to stdout/argv
pubkey	synopsis	agent-secrets pubkey [--copy]
pubkey	summary	Print your age recipient string + fingerprint — hand it to a sender. Safe (public key).
pubkey	desc	Prints the contents of your age public-key file plus its agsec_digest fingerprint. This is the recipient's on-ramp: give it to whoever will `share` a secret with you so they can encrypt to your key. A PUBLIC key — safe to display, paste, or copy. stdout: the recipient string only; heading and fingerprint on stderr, so `pubkey | pbcopy` copies just the key.
pubkey	flag	--copy	also copy the recipient string to the clipboard (pbcopy)
pubkey	example	agent-secrets pubkey	print your age recipient string + fingerprint
pubkey	reads	~/.config/secrets/age.pub
pubkey	writes	nothing
pubkey	exit	0	printed
pubkey	exit	1	no public key yet (run setup)
pubkey	exit	2	usage error
pubkey	namesonly	a PUBLIC key — safe on stdout/argv/clipboard, unlike every value path
backup	synopsis	agent-secrets backup [--repo <REPO>] [--yes]
backup	summary	Push your ENCRYPTED store (ciphertext only) to a private GitHub repo — an off-machine second copy.
backup	desc	Backs up the sops-encrypted secrets.env plus PUBLIC metadata (.sops.yaml recipients, manifest.toml, age.pub, recovery.pub) to a private GitHub repo via gh. The age PRIVATE key is NEVER included, so the backup is useless to anyone without the key you saved in your password manager — safe even if the repo leaks. Creates the private repo on first run (with a confirm; non-interactive runs need --yes), then snapshots on each call, and records the target so doctor can report the second copy. Recover on a new machine with `setup --restore`. stdout: the repo as owner/name.
backup	flag	--repo <REPO>	the private GitHub repo to back up to, as owner/name (default: <your-login>/agent-secrets-store; saved after first use)
backup	flag	-y, --yes	skip the create-repo confirmation for automation (also implied by AGENT_SECRETS_UNATTENDED)
backup	env	AGENT_SECRETS_BACKUP_REPO	default target repo when --repo is not given and none is saved yet
backup	example	agent-secrets backup	back up to <your-login>/agent-secrets-store (creates it private on first run)
backup	example	agent-secrets backup --repo me/secrets-backup	back up to a specific private repo
backup	reads	~/.config/secrets/{secrets.env,.sops.yaml,manifest.toml,age.pub,recovery.pub} (ciphertext + public only)
backup	writes	a commit to the private GitHub repo; ~/.config/secrets/backup-repo (the saved target)
backup	exit	0	backed up (or already up to date)
backup	exit	1	no store, gh missing or not authenticated, a public repo, couldn't confirm the repo is private or look it up, or push failed
backup	exit	2	usage error, or creating the repo non-interactively without --yes
backup	exit	130	canceled at the create-repo confirm (nothing was created)
backup	namesonly	only ciphertext + public keys leave the Mac; the age private key and every secret value stay put
SPEC
}

# --- onboarding topic (self-contained: docs/ is NOT shipped in the release tarball, so this IS the
# in-product source of truth for post-install service setup; docs/POST_INSTALL.md is the web copy). -----
# gh/az are deliberately NOT vendored by the installer (P2: too heavy, different lifecycle, gh auth is
# interactive) — this documents the brew-less fetch instead. Names-only: no value is handled here.
agsec_help_onboarding() {
  cat <<'ONB'
agent-secrets — post-install onboarding (brew-less macOS)

Prefer a CLI login over a raw token in the store, in this order:
  1. gh auth login     — GitHub  (also enables: agent-secrets backup)
  2. az login          — Azure
  3. agent-secrets add — only for keys that must live in env (e.g. ANTHROPIC_API_KEY)

── GitHub CLI (gh) — no Homebrew needed ────────────────────────────
Download the pinned macOS release into ~/bin (mirrors how agent-secrets vendors its own deps):
  V=2.62.0                                   # latest: github.com/cli/cli/releases
  A=$(uname -m); [ "$A" = x86_64 ] && A=amd64
  curl -fsSL "https://github.com/cli/cli/releases/download/v$V/gh_${V}_macOS_${A}.zip" -o /tmp/gh.zip
  unzip -oq /tmp/gh.zip -d /tmp             # extracts /tmp/gh_${V}_macOS_${A}/
  mkdir -p ~/bin && cp "/tmp/gh_${V}_macOS_${A}/bin/gh" ~/bin/gh
  gh --version && gh auth login             # browser or token; ~/bin is already on PATH
Then `agent-secrets backup` can push your ENCRYPTED store to a private GitHub repo.

── Azure CLI (az) — needs Python 3.9+ (the non-obvious part) ────────
az is Python-based. The cleanest brew-less, no-sudo path is an isolated virtualenv:
  python3 --version                          # need 3.9+ (python.org or pyenv if absent)
  python3 -m venv ~/.azure-cli-venv
  ~/.azure-cli-venv/bin/pip install --upgrade pip azure-cli   # a few minutes; downloads wheels
  mkdir -p ~/bin && ln -sf ~/.azure-cli-venv/bin/az ~/bin/az
  az version && az login                     # opens a browser
Prefer `az login` (your own identity) over storing AZURE_* secrets in the store.

── Anthropic (optional — for Claude Code / cursor-agent) ───────────
They authenticate through the wired apiKeyHelper. Add a key only when you have one,
value via a HIDDEN prompt (never on argv, never a doc placeholder pasted verbatim):
  agent-secrets add ANTHROPIC_API_KEY

Web version of this guide: https://github.com/renchris/agent-secrets  (docs/POST_INSTALL.md)
ONB
}

# --- human renderer -------------------------------------------------------------
# Widths are counted in bytes (LC_ALL=C), which over-counts multibyte text such as "—" or "…", so a
# rendered line is never wider than AGSEC_HELP_WIDTH columns. Color wraps labels only, never padded
# text, so stripping the escapes from a colored render gives the plain render byte for byte.
AGSEC_HELP_WIDTH=80

# Fold TEXT to WIDTH bytes at spaces (a word wider than the line is cut, as `fold -s` does). Not fold
# itself: macOS fold gives a non-ASCII byte zero width under LC_ALL=C, so its lines run long.
_agsec_help_fold() {  # WIDTH TEXT
  printf '%s\n' "$2" | LC_ALL=C awk -v w="$1" '{
    n = split($0, a, " "); line = ""
    for (i = 1; i <= n; i++) {
      word = a[i]
      while (length(word) > w) {
        if (line != "") { print line; line = "" }
        print substr(word, 1, w); word = substr(word, w + 1)
      }
      if (line == "") line = word
      else if (length(line) + 1 + length(word) <= w) line = line " " word
      else { print line; line = word }
    }
    print line
  }'
}

# One key/description row. KEY is padded to WIDTH and DESC folded into the rest of the line. When
# KEY + 2 does not fit WIDTH, DESC goes on the next line, 4 deeper. STYLE (an escape) colors KEY only.
_agsec_help_row() {  # INDENT WIDTH KEY DESC [STYLE]
  local ind="$1" w="$2" k="$3" d="$4" st="${5:-}" klen sp ks line first=1
  klen="$(LC_ALL=C; printf '%s' "${#k}")"
  sp="$(printf '%*s' "$ind" '')"
  ks="$st$k${st:+$C_RESET}"
  if [ -z "$d" ]; then printf '%s%s\n' "$sp" "$ks"; return 0; fi
  if [ $((klen + 2)) -gt "$w" ]; then
    printf '%s%s\n' "$sp" "$ks"
    _agsec_help_fold $((AGSEC_HELP_WIDTH - ind - 4)) "$d" | while IFS= read -r line; do
      printf '%s    %s\n' "$sp" "$line"
    done
    return 0
  fi
  _agsec_help_fold $((AGSEC_HELP_WIDTH - ind - w)) "$d" | while IFS= read -r line; do
    if [ "$first" = 1 ]; then
      printf '%s%s%*s%s\n' "$sp" "$ks" $((w - klen)) '' "$line"; first=0
    else
      printf '%s%*s%s\n' "$sp" "$w" '' "$line"
    fi
  done
}

# A heading LABEL followed by TEXT folded with a hanging indent (the Usage line).
_agsec_help_lead() {  # LABEL TEXT
  local lab="$1" line first=1 n
  n="$(LC_ALL=C; printf '%s' "$(( ${#lab} + 1 ))")"
  _agsec_help_fold $((AGSEC_HELP_WIDTH - n)) "$2" | while IFS= read -r line; do
    if [ "$first" = 1 ]; then printf '%s%s%s %s\n' "$C_BOLD" "$lab" "$C_RESET" "$line"; first=0
    else printf '%*s%s\n' "$n" '' "$line"; fi
  done
}

_agsec_help_heading() { printf '\n%s%s%s\n' "$C_BOLD" "$1" "$C_RESET"; }

# An example: the command indented 4 in the normal weight, its description on the next line. A command
# too wide for the line is continued with ` \` before its `agent-secrets` word (display only: the spec
# and the JSON keep the one-line command).
_agsec_help_example() {  # COMMAND DESC
  local c="$1" clen head
  clen="$(LC_ALL=C; printf '%s' "${#c}")"
  if [ $((clen + 4)) -gt "$AGSEC_HELP_WIDTH" ] && [ "${c#* agent-secrets }" != "$c" ]; then
    head="${c%% agent-secrets *}"
    printf '    %s \\\n      %s\n' "$head" "${c#"$head" }"
  else
    printf '    %s\n' "$c"
  fi
  _agsec_help_fold $((AGSEC_HELP_WIDTH - 6)) "$2" | while IFS= read -r line; do printf '      %s\n' "$line"; done
}

# agsec_help_render [VERB]   (no arg or "top" → top-level; else the verb's detail; "onboarding" → topic)
agsec_help_render() {
  local want="${1:-top}"; [ "$want" = "top" ] && want=""
  local spec; spec="$(agsec_help_spec)"
  _f() { printf '%s\n' "$spec" | awk -F'\t' -v v="$want" -v f="$1" '$1==v && $2==f'; }
  # Emit ONLY the key/description columns (3,4). For top-level rows the verb column ($1) is EMPTY,
  # so reading the full row with `IFS=$'\t' read -r _ _ k d` collapses the leading empty field (TAB
  # is IFS-whitespace) and shifts every column left — silently dropping the flag/env/exit/URL KEY.
  # Projecting to $3"\t"$4 first means the key is never in leading position. `read -r k d` then works.
  _kv() { _f "$1" | awk -F'\t' '{print $3"\t"$4}'; }
  # Global options are the top-level flags, minus --json (only `help` reads it).
  _globals() { printf '%s\n' "$spec" | awk -F'\t' '$1=="" && $2=="flag" && $3!="--json" {print $3"\t"$4}'; }
  local k d

  if [ -z "$want" ]; then
    _agsec_help_fold "$AGSEC_HELP_WIDTH" \
      "agent-secrets $AGENT_SECRETS_VERSION — $(_f summary | cut -f3)" | {
      IFS= read -r k; printf '%s%s%s%s\n' "$C_BOLD" "agent-secrets" "$C_RESET" "${k#agent-secrets}"; cat; }
    printf '\n'
    _agsec_help_lead "Usage:" "$(_f synopsis | cut -f3)"
    _agsec_help_heading "Commands:"
    # Grouped by task; every verb in AGSEC_VERBS appears exactly once (tests/help.bats).
    local grp v s
    for grp in "Get started:setup doctor uninstall" "Secrets:add list run" \
               "Share:share receive pubkey" "Back up:backup"; do
      printf '  %s\n' "${grp%%:*}:"
      for v in ${grp#*:}; do
        s="$(printf '%s\n' "$spec" | awk -F'\t' -v v="$v" '$1==v && $2=="summary"{print $3}')"
        k="$v"; [ "$v" = list ] && k="list, ls"
        _agsec_help_row 4 20 "$k" "$s"
      done
    done
    printf '  %s\n' "Help:"
    _agsec_help_row 4 20 "help (default)" "this overview"
    _agsec_help_row 4 20 "help <command>" "one command in full (same as <command> --help)"
    _agsec_help_row 4 20 "help search <TEXT>" "find commands by keyword, offline; --json for JSON"
    _agsec_help_row 4 20 "help --all --json" "every command as one JSON manifest, for agents (same as help --json)"
    _agsec_help_row 4 20 "help onboarding" "post-install service setup: gh/az install + login (brew-less), the token ladder"
    _agsec_help_heading "Global Options:"
    _kv flag | while IFS=$'\t' read -r k d; do _agsec_help_row 2 20 "$k" "$d"; done
    _agsec_help_heading "Environment:"
    _kv env | while IFS=$'\t' read -r k d; do _agsec_help_row 2 22 "$k" "$d"; done
    _agsec_help_heading "Exit codes:"
    _kv exit | while IFS=$'\t' read -r k d; do _agsec_help_row 2 7 "$k" "$d"; done
    printf '\nReserved for v0.2 (not in %s): rotate, demo\n' "$AGENT_SECRETS_VERSION"
    _agsec_help_heading "See also:"
    _kv seealso | while IFS=$'\t' read -r k d; do _agsec_help_row 2 20 "$k" "$d"; done
    return 0
  fi

  # Topic (not a verb): post-install service setup. Handled before the verb check so it renders instead
  # of dying as "no such command".
  if [ "$want" = onboarding ]; then agsec_help_onboarding; return 0; fi

  # per-verb detail
  [ "$want" = ls ] && want=list      # `help ls` / `ls --help` → the list verb (documented alias)
  case " $AGSEC_VERBS " in *" $want "*) : ;; *) agsec_die "no such command: '$want' (try: agent-secrets help)" 2 ;; esac
  _agsec_help_lead "Usage:" "$(_f synopsis | cut -f3)"
  printf '\n'; _agsec_help_fold "$AGSEC_HELP_WIDTH" "$(_f summary | cut -f3)"
  printf '\n'; _agsec_help_fold 78 "$(_f desc | cut -f3)"
  if _f arg | grep -q .; then
    _agsec_help_heading "Arguments:"
    _kv arg | while IFS=$'\t' read -r k d; do _agsec_help_row 2 20 "$k" "$d"; done
  fi
  if _f flag | grep -q .; then
    _agsec_help_heading "Options:"
    # Sorted by long name: the last comma-separated part of the key, without dashes or a value hint.
    _kv flag | awk -F'\t' '{ n = split($1, p, ", "); l = p[n]; sub(/^-+/, "", l); sub(/[ =].*/, "", l); print l "\t" $0 }' \
      | LC_ALL=C sort -t "$(printf '\t')" -k1,1 | cut -f2- \
      | while IFS=$'\t' read -r k d; do _agsec_help_row 2 20 "$k" "$d"; done
  fi
  _agsec_help_heading "Global Options:"
  _globals | while IFS=$'\t' read -r k d; do _agsec_help_row 2 20 "$k" "$d"; done
  if _f env | grep -q .; then
    _agsec_help_heading "Environment:"
    _kv env | while IFS=$'\t' read -r k d; do _agsec_help_row 2 28 "$k" "$d"; done
  fi
  _agsec_help_heading "Examples:"
  _kv example | while IFS=$'\t' read -r k d; do _agsec_help_example "$k" "$d"; done
  _agsec_help_heading "Notes:"
  printf '  Exit codes:\n'
  _kv exit | while IFS=$'\t' read -r k d; do _agsec_help_row 4 7 "$k" "$d"; done
  local no rd wr; no="$(_f namesonly | cut -f3)"; rd="$(_f reads | cut -f3)"; wr="$(_f writes | cut -f3)"
  [ -z "$no" ] || _agsec_help_row 2 13 "Names-only:" "$no" "$C_BOLD"
  [ -z "$rd" ] || _agsec_help_row 2 13 "Reads:" "$rd"
  [ -z "$wr" ] || _agsec_help_row 2 13 "Writes:" "$wr"
  return 0   # never leak a falsy last-test status to a `set -e` caller
}

# --- JSON manifest (for agents) -------------------------------------------------
# Each flags[] entry carries flag + description (the stable shape) plus type, value_hint, default and
# choices, derived from the key: a key with a value hint takes a string, any other is a boolean switch.
agsec_help_json() {
  agsec_require jq
  local spec; spec="$(agsec_help_spec)"
  # Build one JSON object per verb (and "" = top) from the flat spec, entirely in jq (safe escaping).
  printf '%s\n' "$spec" | jq -R -s --arg version "$AGENT_SECRETS_VERSION" --arg verbs "$AGSEC_VERBS" '
    def flagmeta:
      ((split(", ") | last | capture("^(?<name>-[^ =]+)(?:[ =](?<hint>.+))?$")) // {hint: null}) as $m
      | if $m.hint then {type: "string", value_hint: $m.hint, default: null, choices: null}
        else {type: "boolean", value_hint: null, default: false, choices: null} end;
    [ split("\n")[] | select(length>0) | split("\t")
      | { verb: .[0], field: .[1], a: (.[2] // ""), b: (.[3] // "") } ]
    as $rows
    | ( ["" ] + ($verbs | split(" ")) ) as $order
    | { tool: "agent-secrets", version: $version,
        commands: [ $order[] as $v
          | ($rows | map(select(.verb==$v))) as $r
          | { name: (if $v=="" then "agent-secrets" else $v end),
              synopsis: ($r[] | select(.field=="synopsis") | .a),
              summary:  ($r[] | select(.field=="summary")  | .a),
              description: (($r[] | select(.field=="desc") | .a) // ""),
              args:     [ $r[] | select(.field=="arg")     | {name:.a, description:.b} ],
              flags:    [ $r[] | select(.field=="flag")    | {flag:.a, description:.b} + (.a | flagmeta) ],
              env:      [ $r[] | select(.field=="env")     | {name:.a, description:.b} ],
              examples: [ $r[] | select(.field=="example") | {command:.a, description:.b} ],
              exit_codes:[ $r[] | select(.field=="exit")   | {code:(.a|tonumber?), meaning:.b} ],
              reads:  (($r[] | select(.field=="reads")  | .a) // ""),
              writes: (($r[] | select(.field=="writes") | .a) // ""),
              names_only: (($r[] | select(.field=="namesonly") | .a) // "") }
        ],
        reserved_v0_2: ["rotate","demo"],
        agent_notes: "Every command is names-only: a secret VALUE is never printed. Pipe values into `add` via STDIN. Use `run -- <cmd>` to inject secrets into a process without displaying them. Gate on doctor exit code (0=healthy). See AGENTS.md."
      }'
}
