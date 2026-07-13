#!/usr/bin/env bats
# tests/egress.bats — the process-scoped egress allowlist (core-Perl CONNECT proxy).
# Load-bearing behavior: an allowlisted host tunnels (200 Connection established); a host NOT in the
# allowlist gets 403 Forbidden. Loopback only (127.0.0.1) — no real network, no CPAN. The proxy
# lifecycle lives in tests/egress-probe.sh (foreground + self-cleaning) so bats never hangs on a
# lingering background process.
load test_helper

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
  [[ "$output" == *"403"* ]]
  rm -f "$allow"
}

@test "proxy ALLOWS an allowlisted hostname and tunnels (200)" {
  [ -x /usr/bin/perl ] || skip "no /usr/bin/perl"
  local allow; allow="$(mktemp)"; printf 'localhost\n' >"$allow"   # localhost → 127.0.0.1: proves name matching
  run PROBE "$allow" "localhost:UPPORT" --upstream
  [ "$status" -eq 0 ]
  [[ "$output" == *"200"* ]]
  rm -f "$allow"
}

@test "a wildcard *.suffix rule does not match an unrelated host (403)" {
  [ -x /usr/bin/perl ] || skip "no /usr/bin/perl"
  local allow; allow="$(mktemp)"; printf '*.anthropic.com\n' >"$allow"
  run PROBE "$allow" "localhost:9999"          # localhost is not *.anthropic.com; denied (no upstream)
  [ "$status" -eq 0 ]
  [[ "$output" == *"403"* ]]
  rm -f "$allow"
}

@test "a host:port rule ALLOWS the matching port (200)" {
  [ -x /usr/bin/perl ] || skip "no /usr/bin/perl"
  local allow; allow="$(mktemp)"; printf 'localhost:UPPORT\n' >"$allow"   # probe substitutes the real port
  run PROBE "$allow" "localhost:UPPORT" --upstream
  [ "$status" -eq 0 ]
  [[ "$output" == *"200"* ]]
  rm -f "$allow"
}

@test "a host:port rule DENIES a different port on the same host (403)" {
  [ -x /usr/bin/perl ] || skip "no /usr/bin/perl"
  local allow; allow="$(mktemp)"; printf 'localhost:1\n' >"$allow"        # allowed host, wrong port
  run PROBE "$allow" "localhost:9999"
  [ "$status" -eq 0 ]
  [[ "$output" == *"403"* ]]
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
  [[ "$output" == *"corp.example:3128"* ]]       # ambient proxy preserved…
  [[ "$output" != *"127.0.0.1"* ]]               # …NOT rewritten to our loopback
}
