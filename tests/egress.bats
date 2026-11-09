#!/usr/bin/env bats
# tests/egress.bats — the process-scoped egress allowlist (core-Perl CONNECT proxy).
# Load-bearing behavior: an allowlisted host tunnels (200 Connection established); a host NOT in the
# allowlist gets 403 Forbidden. Loopback only (127.0.0.1) — no real network, no CPAN. The proxy
# lifecycle lives in tests/egress-probe.sh (foreground + self-cleaning) so bats never hangs on a
# lingering background process.
load test_helper
load mode_matrix

PROBE() { bash "$BATS_TEST_DIRNAME/egress-probe.sh" "$@"; }

@test "egress_enabled + rule count reflect the allowlist file" {
  export AGENT_SECRETS_LIB="$REPO_ROOT/lib"
  # shellcheck source=/dev/null
  . "$REPO_ROOT/lib/common.sh"; . "$REPO_ROOT/lib/egress.sh"
  local cfg; cfg="$(agsec_config_dir)"; mkdir -p "$cfg"
  ! egress_enabled                         # absent → off
  [ "$(egress_rule_count)" = 0 ]
  printf '# only comments\n\n' >"$cfg/egress.allow"
  ! egress_enabled                         # comment-only → still off
  [ "$(egress_rule_count)" = 0 ]
  printf '# header\napi.anthropic.com\ngithub.com\n' >"$cfg/egress.allow"
  egress_enabled                           # real rules → on
  [ "$(egress_rule_count)" = 2 ]
}

@test "proxy DENIES a host absent from the allowlist (403)" {
  [ -x /usr/bin/perl ] || skip "no /usr/bin/perl"
  local allow; allow="$(mktemp)"; printf 'api.anthropic.com\n' >"$allow"
  run PROBE "$allow" "10.255.255.1:443"        # not allowlisted; denied before any upstream connect
  [ "$status" -eq 0 ]
  [[ "$output" == *"403"* ]] || return 1
  rm -f "$allow"
}

@test "proxy ALLOWS an allowlisted hostname and tunnels (200)" {
  [ -x /usr/bin/perl ] || skip "no /usr/bin/perl"
  local allow; allow="$(mktemp)"; printf 'localhost\n' >"$allow"   # localhost → 127.0.0.1: proves name matching
  run PROBE "$allow" "localhost:UPPORT" --upstream
  [ "$status" -eq 0 ]
  [[ "$output" == *"200"* ]] || return 1
  rm -f "$allow"
}

@test "a wildcard *.suffix rule does not match an unrelated host (403)" {
  [ -x /usr/bin/perl ] || skip "no /usr/bin/perl"
  local allow; allow="$(mktemp)"; printf '*.anthropic.com\n' >"$allow"
  run PROBE "$allow" "localhost:9999"          # localhost is not *.anthropic.com; denied (no upstream)
  [ "$status" -eq 0 ]
  [[ "$output" == *"403"* ]] || return 1
  rm -f "$allow"
}

@test "a host:port rule ALLOWS the matching port (200)" {
  [ -x /usr/bin/perl ] || skip "no /usr/bin/perl"
  local allow; allow="$(mktemp)"; printf 'localhost:UPPORT\n' >"$allow"   # probe substitutes the real port
  run PROBE "$allow" "localhost:UPPORT" --upstream
  [ "$status" -eq 0 ]
  [[ "$output" == *"200"* ]] || return 1
  rm -f "$allow"
}

@test "a host:port rule DENIES a different port on the same host (403)" {
  [ -x /usr/bin/perl ] || skip "no /usr/bin/perl"
  local allow; allow="$(mktemp)"; printf 'localhost:1\n' >"$allow"        # allowed host, wrong port
  run PROBE "$allow" "localhost:9999"
  [ "$status" -eq 0 ]
  [[ "$output" == *"403"* ]] || return 1
  rm -f "$allow"
}

@test "egress_start captures the proxy PID in the caller's scope (no kill-0 bug) and _egress_reap kills it" {
  [ -x /usr/bin/perl ] || skip "no /usr/bin/perl"
  export AGENT_SECRETS_LIB="$REPO_ROOT/lib"
  # shellcheck source=/dev/null
  . "$REPO_ROOT/lib/common.sh"; . "$REPO_ROOT/lib/egress.sh"
  mkdir -p "$(agsec_config_dir)"; printf '127.0.0.1\n' >"$(egress_allow_file)"
  egress_start                                   # DIRECT call (not $()) — the PID MUST reach this shell
  [ -n "$EGRESS_PROXY_PID" ]                     # captured (empty ⇒ the kill-0-on-caller bug)
  [ "$EGRESS_PROXY_PID" -gt 0 ]
  [ -n "$EGRESS_PORT" ]
  kill -0 "$EGRESS_PROXY_PID"                    # alive
  _egress_reap; sleep 0.3
  ! kill -0 "$EGRESS_PROXY_PID" 2>/dev/null      # reaped, no orphan
}

@test "egress DEFERS to a pre-existing HTTPS_PROXY (never overrides a corporate proxy)" {
  setup_store
  printf 'api.example.com\n' >"$(agsec_config_dir)/egress.allow"          # allowlist configured
  run env HTTPS_PROXY="http://corp.example:3128" bash "$REPO_ROOT/bin/agent-secrets" run -- printenv HTTPS_PROXY
  [ "$status" -eq 0 ]
  [[ "$output" == *"corp.example:3128"* ]] || return 1       # ambient proxy preserved…
  [[ "$output" != *"127.0.0.1"* ]] || return 1               # …NOT rewritten to our loopback
}

# ---- the run child contract ---------------------------------------------------------------------
# NOPROXY strips an ambient corporate proxy so the allowlist path is the one under test.
NOPROXY=(env -u HTTPS_PROXY -u https_proxy -u AGENT_SECRETS_NO_EGRESS)

@test "run passes a child's exit 42 through, with and without the egress bound" {
  setup_store
  run "${NOPROXY[@]}" bash "$REPO_ROOT/bin/agent-secrets" run -- sh -c 'exit 42'
  [ "$status" -eq 42 ]
  [ -x /usr/bin/perl ] || skip "no /usr/bin/perl"
  printf '127.0.0.1\n' >"$(agsec_config_dir)/egress.allow"
  run "${NOPROXY[@]}" bash "$REPO_ROOT/bin/agent-secrets" run -- sh -c 'exit 42'
  [ "$status" -eq 42 ]
  [[ "$output" == *"egress allowlist active"* ]] || return 1     # the managed path really ran
}

@test "run keeps argv intact (space, newline, single quote), with and without the egress bound" {
  setup_store
  local want="[a b][x"$'\n'"y][it's]"
  run "${NOPROXY[@]}" bash "$REPO_ROOT/bin/agent-secrets" run -- sh -c 'printf "[%s]" "$@"' sh 'a b' $'x\ny' "it's"
  [ "$status" -eq 0 ]
  [ "$output" = "$want" ]
  [ -x /usr/bin/perl ] || skip "no /usr/bin/perl"
  printf '127.0.0.1\n' >"$(agsec_config_dir)/egress.allow"
  # The managed path prints its note on stderr, so the child writes its argv to a file.
  run "${NOPROXY[@]}" bash "$REPO_ROOT/bin/agent-secrets" run -- sh -c 'printf "[%s]" "$@" >"$0"' "$AGENT_SECRETS_HOME/argv.out" 'a b' $'x\ny' "it's"
  [ "$status" -eq 0 ]
  [ "$(cat "$AGENT_SECRETS_HOME/argv.out")" = "$want" ]
}

@test "run with a missing command exits 2 before launch" {
  setup_store
  run "${NOPROXY[@]}" bash "$REPO_ROOT/bin/agent-secrets" run -- agsec-no-such-command-b1
  [ "$status" -eq 2 ]
  [[ "$output" == *"command not found"* ]] || return 1
}

@test "egress-bound run: SIGTERM to the wrapper exits 143 and leaves no child or proxy" {
  [ -x /usr/bin/perl ] || skip "no /usr/bin/perl"
  setup_store
  printf '127.0.0.1\n' >"$(agsec_config_dir)/egress.allow"
  # A duration no other process on the machine uses, so ps can tell this child apart. It must outlive
  # the 120 s wait below: under load the child can still be sleeping-out before the TERM arrives.
  local dur="600.$$${RANDOM}" w rc=0 deadline
  # ps is read whole before grep: common.sh sets pipefail, so `ps | grep -q` fails when ps takes a
  # SIGPIPE. Whole-line match, so a grep's own argv never counts as the child.
  _child_up() { local all; all="$(ps -axo command=)"; grep -qxF "sleep $dur" <<<"$all"; }
  _proxy_up() { local all; all="$(ps -axo command=)"; [ "$(grep -F egress-proxy.pl <<<"$all" | grep -cF "$AGENT_SECRETS_HOME")" -gt 0 ]; }
  "${NOPROXY[@]}" bash "$REPO_ROOT/bin/agent-secrets" run -- sleep "$dur" 3>&- &
  w=$!
  deadline=$((SECONDS + 120))
  until _child_up; do
    [ "$SECONDS" -lt "$deadline" ] || { kill -KILL "$w"; return 1; }
    sleep 0.2
  done
  # The proxy's argv carries the synthetic HOME's allowlist path, so this is our proxy and the
  # managed path (not the exec fallback, where TERM would hit the child directly) is under test.
  _proxy_up
  kill -TERM "$w"
  wait "$w" || rc=$?
  [ "$rc" -eq 143 ]
  deadline=$((SECONDS + 60))
  while _proxy_up || _child_up; do
    [ "$SECONDS" -lt "$deadline" ] || return 1
    sleep 0.2
  done
}

@test "store_exec -- true still succeeds (doctor gate d)" {
  setup_store
  run bash -c '. "$AGENT_SECRETS_LIB/common.sh"; . "$AGENT_SECRETS_LIB/keychain.sh"; . "$AGENT_SECRETS_LIB/store.sh"; store_exec -- true'
  [ "$status" -eq 0 ]
}

@test "run: an unknown option exits 2 naming it; --no-egress is accepted in any position before --" {
  setup_store
  run bash "$REPO_ROOT/bin/agent-secrets" run --bogus -- true
  [ "$status" -eq 2 ]
  [[ "$output" == *"Unknown option '--bogus' for run."* ]] || return 1
  printf '127.0.0.1\n' >"$(agsec_config_dir)/egress.allow"
  run "${NOPROXY[@]}" bash "$REPO_ROOT/bin/agent-secrets" run --no-egress --no-egress -- printenv HTTPS_PROXY
  [ "$status" -eq 1 ]                                           # opted out: no proxy in the child env
  [[ "$output" != *"egress allowlist active"* ]] || return 1
}

@test "run: AGSEC_PARSE_ONLY exits 0 after parsing, before reading the store" {
  run env AGSEC_PARSE_ONLY=1 bash "$REPO_ROOT/bin/agent-secrets" run --no-egress -- true
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run env AGSEC_PARSE_ONLY=1 bash "$REPO_ROOT/bin/agent-secrets" run --bogus -- true
  [ "$status" -eq 2 ]
}

@test "mode matrix: run with a missing command exits 2 with the error on stderr in every mode" {
  # shellcheck source=/dev/null
  . "$REPO_ROOT/lib/common.sh"
  mkdir -p "$(agsec_config_dir)"; : >"$(agsec_store_file)"   # existence is all run checks before launch
  local m cmd=(bash "$REPO_ROOT/bin/agent-secrets" run -- agsec-no-such-command-b1)
  for m in tty noninteractive-tty ci-tty; do
    mm_run "$m" -- "${cmd[@]}"
    [ "$mm_status" -eq 2 ] || { echo "mode $m: status $mm_status"; return 1; }
    [[ "$mm_pty" == *"command not found"* ]] || { echo "mode $m: $mm_pty"; return 1; }
  done
  mm_run stdout-redirected -- "${cmd[@]}"
  [ "$mm_status" -eq 2 ]
  [ -z "$mm_stdout" ]
  [[ "$mm_pty" == *"command not found"* ]] || return 1
  for m in stdin-piped agent; do
    mm_run "$m" -- "${cmd[@]}"
    [ "$mm_status" -eq 2 ] || { echo "mode $m: status $mm_status"; return 1; }
    [ -z "$mm_stdout" ]
    [[ "$mm_stderr" == *"command not found"* ]] || { echo "mode $m: $mm_stderr"; return 1; }
  done
  # run has no --json, so json-tty is a usage error.
  mm_run json-tty -- bash "$REPO_ROOT/bin/agent-secrets" run --json -- agsec-no-such-command-b1
  [ "$mm_status" -eq 2 ]
  [[ "$mm_pty" == *"Unknown option '--json' for run."* ]] || return 1
}
