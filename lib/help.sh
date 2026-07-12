# shellcheck shell=bash
# lib/help.sh — the single source of truth for CLI help, for HUMANS and AGENTS.
# Renders detailed per-verb help (human) AND a machine-readable manifest (`help --json`) from ONE
# spec, so an agent can fully understand and drive agent-secrets with no human in the loop.
# Sourced after common.sh. Names-only: nothing here handles a secret value.
#
# Spec format (agsec_help_spec): tab-separated `VERB<TAB>FIELD<TAB>A[<TAB>B]`, one row per line.
#   FIELD ∈ synopsis|summary|desc|reads|writes|namesonly (scalar → A)
#          | flag|arg|example|exit|env|seealso        (pair   → A=key/name, B=description)
# VERB "" = top-level (agent-secrets itself).

AGSEC_VERBS="setup add list run doctor uninstall share receive pubkey"

agsec_help_spec() {
  # NOTE: keep this the ONLY place command facts live; both renderers below read it.
  cat <<'SPEC'
	synopsis	agent-secrets [--plain|--no-color] <command> [args]
	summary	Machine-wide secrets for coding agents — encrypted at rest (sops+age), injected just-in-time, names-only.
	desc	Every command shows NAMES and status only; a secret VALUE is never printed, logged, or written outside the encrypted store. Values move in via STDIN (never argv) and out only into a launched process's environment or the Claude Code apiKeyHelper.
	flag	--plain	force plain output (no colors/box-drawing); also via AGENT_SECRETS_PLAIN=1 or NO_COLOR=1
	flag	--no-color	disable ANSI color only
	flag	-V, --version	print version and exit
	flag	-h, --help	show help; `help <command>` or `<command> --help` for a specific command
	flag	--json	with `help`: emit the full machine-readable command manifest (for agents)
	env	AGENT_SECRETS_HOME	base dir for all state (default $HOME); set to an isolated dir for tests/CI
	env	AGENT_SECRETS_PLAIN	1 = plain output (no color/gum), accessibility + scripting
	env	NO_COLOR	standard: any value disables color
	exit	0	success
	exit	1	runtime error (see the message; names-only)
	exit	2	usage error / unknown command / reserved verb
	seealso	AGENTS.md	agent-facing usage guide (read this first if you are an agent)
	seealso	SECURITY.md	threat model + the honest ceiling
setup	synopsis	agent-secrets setup [--restore]
setup	summary	One-time onboarding wizard: generate your key, add your first secret, wire your tools.
setup	desc	Idempotent — safe to re-run; detects an existing install and never mints a second key. Screens: preflight → key ceremony (Keychain + file fallback + recovery leg) → first secret → wire wrappers/apiKeyHelper → health check → done. --restore recovers on a new machine: paste your saved age key to re-establish custody over a restored store copy (verifies decryption; never mints a new key). Refuses to run its key ceremony inside an agent session (transcripts are secret-bearing) unless AGENT_SECRETS_UNATTENDED=1.
setup	flag	--restore	recover on a new machine — paste your saved age key to re-establish custody over a restored store copy (never mints a new key)
setup	env	AGENT_SECRETS_UNATTENDED	1 = non-interactive with FAKE placeholder values (tests/CI); reads the first secret value from STDIN if piped
setup	example	agent-secrets setup	run the interactive wizard (in a normal terminal, not an agent session)
setup	example	agent-secrets setup --restore	recover on a new machine (copy your store copy into place first, then paste your saved key)
setup	writes	~/.config/secrets/{secrets.env,manifest.toml,age.key,.sops.yaml}, ~/bin wrappers, ~/.claude/settings.json (apiKeyHelper)
setup	exit	0	wizard completed (or returned early on an existing install)
setup	exit	1	a step failed (see message)
setup	namesonly	never prints the age key or any secret value; hidden input via read -s
add	synopsis	agent-secrets add <NAME>
add	summary	Add or update ONE secret by name. The value is read hidden and never echoed.
add	desc	NAME must match ^[A-Za-z_][A-Za-z0-9_]*$. The value is read from STDIN when piped (scriptable/agent-friendly), otherwise from a hidden prompt. Upserts the encrypted store entry and its manifest.toml row (rotate_by defaults to +180d).
add	arg	NAME	the secret's name (e.g. ANTHROPIC_API_KEY); letters, digits, underscore; starts with a letter or _
add	example	printf '%s' "$SECRET" | agent-secrets add ANTHROPIC_API_KEY	pipe the value in (never on argv); nothing is echoed
add	example	agent-secrets add OPENAI_API_KEY	interactive hidden prompt for the value
add	reads	STDIN (the value, if piped)
add	writes	~/.config/secrets/secrets.env, ~/.config/secrets/manifest.toml
add	exit	0	stored
add	exit	1	invalid NAME, no store yet (run setup), or encrypt failed
add	namesonly	the value is never printed, logged, or placed on argv
list	synopsis	agent-secrets list [--format=json]
list	summary	List secret NAMES (and rotation dates). Never values.
list	desc	Prints the names in the store with their manifest.toml rotate_by dates. Use --format=json for a value-free machine-readable array an agent can parse.
list	flag	--format=json	emit a JSON array of {name, rotate_by}; no values
list	example	agent-secrets list	human-readable names + rotate dates
list	example	agent-secrets list --format=json	[{"name":"ANTHROPIC_API_KEY","rotate_by":"2027-01-06"}, ...]
list	reads	~/.config/secrets/secrets.env (names only), manifest.toml
list	exit	0	ok (prints a friendly note if the store is empty/absent)
list	namesonly	prints names + metadata only; never a value
run	synopsis	agent-secrets run -- <cmd> [args...]
run	summary	Run a command with secrets injected just-in-time, process-scoped.
run	desc	Decrypts the store and injects every entry into the child process's environment via `sops exec-env`, then execs <cmd>. The values live only in that process and die with it — never in a config, log, or your shell. The `--` separator is REQUIRED.
run	arg	-- <cmd> [args...]	the command to run with secrets in its environment (everything after -- is the command)
run	example	agent-secrets run -- printenv ANTHROPIC_API_KEY | wc -c	prove injection without displaying the value (counts bytes)
run	example	agent-secrets run -- node server.js	run any tool with the secrets injected for that process only
run	exit	0	the child command's exit code (exec)
run	exit	1	missing `--`, or no store (run setup)
run	namesonly	values enter the child env only; the tool never prints them
doctor	synopsis	agent-secrets doctor [--format=json] [--redact] [--gates] [--fix]
doctor	summary	Health check across custody, store, injection, hygiene, maintenance, supply-chain.
doctor	desc	Each check reports ✓/⚠/✗ with NAMES and status only. Exit is 0 when there is no ✗, else 1 — so an agent can gate on it. Non-destructive by default; --fix applies only safe fixes.
doctor	flag	--format=json	machine-readable results (array of {category, status, detail}); no values
doctor	flag	--redact	replace any sensitive-looking token with a sha256: digest in output
doctor	flag	--gates	also run the execution gates (c: Keychain read, d: sops exec-env, e: egress profile)
doctor	flag	--fix	apply SAFE fixes only (never runs without this flag)
doctor	example	agent-secrets doctor	human health report
doctor	example	agent-secrets doctor --format=json	parse status programmatically
doctor	example	agent-secrets doctor --gates	verify the deployment gates before an unattended run
doctor	exit	0	no ✗ checks
doctor	exit	1	at least one ✗ check
doctor	namesonly	reports names/status only; verifies values are non-empty via length, never prints them
uninstall	synopsis	agent-secrets uninstall [--dry-run]
uninstall	summary	Remove everything this tool installed (manifest-driven, total). Prompts before touching your secrets.
uninstall	desc	Reverses every recorded change: files, wrappers, the PATH block, the launchd job, the settings.json edit, and Keychain agent-* items. Then ASKS whether to keep or delete your encrypted store + keys (a real STOP-ASK, no --force bypass). --dry-run prints the full plan and changes nothing.
uninstall	flag	--dry-run	print the rollback plan; mutate nothing
uninstall	example	agent-secrets uninstall --dry-run	preview exactly what would be removed
uninstall	example	agent-secrets uninstall	perform the removal (interactive keep-or-purge prompt for your store)
uninstall	writes	removes tool artifacts; store/keys only on explicit purge confirmation
uninstall	exit	0	uninstall completed (or dry-run printed)
uninstall	exit	1	nothing to roll back / error
uninstall	namesonly	enumerates artifacts by name; never reads a secret value
share	synopsis	agent-secrets share <NAME> --to <age1…|github:user|self> [--singleton] [--verify] [--sign] [--rename NEW]
share	summary	Encrypt ONE secret to a colleague's key; ladder-gated, names-only. Refuses in an agent session.
share	desc	The don't-share ladder runs FIRST (offer a scoped/least-privilege alternative before any value moves), then a single [y/N] recipient confirm showing the key fingerprint + NAME. Encrypts the one value with age to the recipient's public key and prints a paste-able v1 envelope (armored ciphertext + NAME + digest). The digest is advisory (an accidental-mismatch readback) unless --verify makes it a required out-of-band step. Never auto-rotates. Refuses inside an agent session (transcripts are secret-bearing).
share	arg	NAME	the secret to share (must already exist in your store)
share	arg	--to <recipient>	age1… recipient string, github:USER (fetch their key), or self (re-encrypt to your own key)
share	flag	--singleton	assert this is a true singleton (webhook/HMAC/account-only key) to bypass the R2 ladder rung
share	flag	--verify	require the out-of-band digest readback before the envelope is emitted
share	flag	--sign	attach a signature leg so the recipient can authenticate the sender
share	flag	--rename NEW	label the envelope so the recipient stores it under NEW instead of NAME
share	env	AGENT_SECRETS_UNATTENDED	1 = auto-answer the y/N confirm (CI); the interactive-terminal, ladder + canary hard-errors still apply
share	example	agent-secrets share ANTHROPIC_API_KEY --to github:dana	encrypt to dana's GitHub age key; prints an envelope to paste
share	reads	~/.config/secrets/secrets.env (the one NAME only), manifest.toml
share	writes	the manifest sharing row for NAME (shared_with/shared_at/direction=sent; values-free)
share	exit	0	envelope emitted
share	exit	1	no such NAME, bad recipient, or refused (agent session / canary)
share	exit	2	usage error
share	namesonly	the value is encrypted to the recipient and never printed; only ciphertext + the NAME leave
receive	synopsis	agent-secrets receive [--rename NEW] [--yes-i-reviewed]
receive	summary	Ingest a pasted share envelope on STDIN, decrypt, store — never displayed. tty-gated.
receive	desc	Reads a v1 envelope blob from STDIN and takes every confirm from /dev/tty (hard-refuses when no tty is present, except --yes-i-reviewed for CI which still runs the canary/collision hard errors). Recomputes the digest locally over the base64-decoded ciphertext (advisory) for an out-of-band voice-compare, rejects unknown envelope versions, hard-refuses the in-store canary name, and hard-stops if NAME already exists (use --rename). The decrypted value is piped straight into the encrypted store.
receive	flag	--rename NEW	store the received secret under NEW (use when the envelope's NAME collides or you prefer a local name)
receive	flag	--yes-i-reviewed	non-interactive ingest for CI; skips the tty prompts but keeps the canary/collision hard errors
receive	env	AGENT_SECRETS_HOME	base dir for all state (default $HOME); set to an isolated dir for tests/CI
receive	example	agent-secrets receive	run, then paste the envelope on STDIN and press Ctrl-D
receive	reads	STDIN (the pasted v1 envelope)
receive	writes	~/.config/secrets/secrets.env, manifest.toml (direction=received, source=received:peer)
receive	exit	0	stored
receive	exit	1	bad/unknown-version envelope, canary name, NAME collision, or no tty
receive	exit	2	usage error
receive	namesonly	the decrypted value goes straight into the store, never to stdout/argv
pubkey	synopsis	agent-secrets pubkey [--copy]
pubkey	summary	Print your age recipient string + fingerprint — hand it to a sender. Safe (public key).
pubkey	desc	Prints the contents of your age public-key file plus its agsec_digest fingerprint. This is the recipient's on-ramp: give it to whoever will `share` a secret with you so they can encrypt to your key. A PUBLIC key — safe to display, paste, or copy.
pubkey	flag	--copy	also copy the recipient string to the clipboard (pbcopy)
pubkey	example	agent-secrets pubkey	print your age recipient string + fingerprint
pubkey	reads	~/.config/secrets/age.pub
pubkey	writes	nothing
pubkey	exit	0	printed
pubkey	exit	1	no public key yet (run setup)
pubkey	exit	2	usage error
pubkey	namesonly	a PUBLIC key — safe on stdout/argv/clipboard, unlike every value path
SPEC
}

# --- human renderer -------------------------------------------------------------
# agsec_help_render [VERB]   (no arg or "top" → top-level; else the verb's detail)
agsec_help_render() {
  local want="${1:-top}"; [ "$want" = "top" ] && want=""
  local spec; spec="$(agsec_help_spec)"
  _f() { printf '%s\n' "$spec" | awk -F'\t' -v v="$want" -v f="$1" '$1==v && $2==f'; }

  if [ -z "$want" ]; then
    printf '%s%s%s %s — %s\n\n' "$C_BOLD" "agent-secrets" "$C_RESET" "$AGENT_SECRETS_VERSION" \
      "$(_f summary | cut -f3)"
    printf '%sUsage:%s %s\n\n' "$C_BOLD" "$C_RESET" "$(_f synopsis | cut -f3)"
    printf '%sCommands:%s\n' "$C_BOLD" "$C_RESET"
    local v s
    for v in $AGSEC_VERBS; do
      s="$(printf '%s\n' "$spec" | awk -F'\t' -v v="$v" '$1==v && $2=="summary"{print $3}')"
      printf '  %-10s %s\n' "$v" "$s"
    done
    printf '  %-10s %s\n' "help" "show help; 'help <cmd>' or '<cmd> --help' for one command; 'help --json' for the manifest"
    printf '\n%sGlobal flags:%s\n' "$C_BOLD" "$C_RESET"
    _f flag | while IFS=$'\t' read -r _ _ k d; do printf '  %-14s %s\n' "$k" "$d"; done
    printf '\n%sEnvironment:%s\n' "$C_BOLD" "$C_RESET"
    _f env | while IFS=$'\t' read -r _ _ k d; do printf '  %-24s %s\n' "$k" "$d"; done
    printf '\n%sExit codes:%s ' "$C_BOLD" "$C_RESET"
    _f exit | while IFS=$'\t' read -r _ _ k d; do printf '%s=%s · ' "$k" "$d"; done; printf '\n'
    printf '\nReserved for v0.2 (not in %s): rotate, demo\n' "$AGENT_SECRETS_VERSION"
    _f seealso | while IFS=$'\t' read -r _ _ k d; do printf 'See: %-12s %s\n' "$k" "$d"; done
    return 0
  fi

  # per-verb detail
  case " $AGSEC_VERBS " in *" $want "*) : ;; *) agsec_die "no such command: '$want' (try: agent-secrets help)" 2 ;; esac
  printf '%s%s%s — %s\n\n' "$C_BOLD" "agent-secrets $want" "$C_RESET" "$(_f summary | cut -f3)"
  printf '%sUsage:%s %s\n\n' "$C_BOLD" "$C_RESET" "$(_f synopsis | cut -f3)"
  printf '%s\n' "$(_f desc | cut -f3 | fold -s -w 78)"
  if _f arg | grep -q .; then printf '\n%sArguments:%s\n' "$C_BOLD" "$C_RESET"; _f arg | while IFS=$'\t' read -r _ _ k d; do printf '  %-20s %s\n' "$k" "$d"; done; fi
  if _f flag | grep -q .; then printf '\n%sFlags:%s\n' "$C_BOLD" "$C_RESET"; _f flag | while IFS=$'\t' read -r _ _ k d; do printf '  %-16s %s\n' "$k" "$d"; done; fi
  if _f env | grep -q .; then printf '\n%sEnvironment:%s\n' "$C_BOLD" "$C_RESET"; _f env | while IFS=$'\t' read -r _ _ k d; do printf '  %-26s %s\n' "$k" "$d"; done; fi
  printf '\n%sExamples:%s\n' "$C_BOLD" "$C_RESET"; _f example | while IFS=$'\t' read -r _ _ k d; do printf '  %s%s%s\n      %s\n' "$C_DIM" "$k" "$C_RESET" "$d"; done
  printf '\n%sExit codes:%s\n' "$C_BOLD" "$C_RESET"; _f exit | while IFS=$'\t' read -r _ _ k d; do printf '  %-3s %s\n' "$k" "$d"; done
  local no; no="$(_f namesonly | cut -f3)"; [ -n "$no" ] && printf '\n%sNames-only:%s %s\n' "$C_GREEN" "$C_RESET" "$no"
  local rd wr; rd="$(_f reads | cut -f3)"; wr="$(_f writes | cut -f3)"
  [ -n "$rd" ] && printf 'Reads:  %s\n' "$rd"
  [ -n "$wr" ] && printf 'Writes: %s\n' "$wr"
  return 0   # never leak a falsy last-test status to a `set -e` caller
}

# --- JSON manifest (for agents) -------------------------------------------------
agsec_help_json() {
  agsec_require jq
  local spec; spec="$(agsec_help_spec)"
  # Build one JSON object per verb (and "" = top) from the flat spec, entirely in jq (safe escaping).
  printf '%s\n' "$spec" | jq -R -s --arg version "$AGENT_SECRETS_VERSION" --arg verbs "$AGSEC_VERBS" '
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
              flags:    [ $r[] | select(.field=="flag")    | {flag:.a, description:.b} ],
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
