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

AGSEC_VERBS="setup add list run doctor uninstall"

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
setup	synopsis	agent-secrets setup
setup	summary	One-time onboarding wizard: generate your key, add your first secret, wire your tools.
setup	desc	Idempotent — safe to re-run; detects an existing install and never mints a second key. Screens: preflight → key ceremony (Keychain + file fallback + recovery leg) → first secret → wire wrappers/apiKeyHelper → health check → done. Refuses to run its key ceremony inside an agent session (transcripts are secret-bearing) unless AGENT_SECRETS_UNATTENDED=1.
setup	env	AGENT_SECRETS_UNATTENDED	1 = non-interactive with FAKE placeholder values (tests/CI); reads the first secret value from STDIN if piped
setup	example	agent-secrets setup	run the interactive wizard (in a normal terminal, not an agent session)
setup	example	printf '%s' "$V" | AGENT_SECRETS_UNATTENDED=1 agent-secrets setup	non-interactive fake-value setup for CI
setup	writes	~/.config/secrets/{secrets.env,manifest.toml,age.key,.sops.yaml}, ~/bin wrappers, ~/.claude/settings.json (apiKeyHelper), launchd smoke job
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
