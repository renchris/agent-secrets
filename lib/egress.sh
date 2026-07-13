# shellcheck shell=bash
# lib/egress.sh — process-scoped egress allowlist for `run` and the claude/cursor wrappers.
# Starts the core-Perl CONNECT allowlist proxy (lib/egress-proxy.pl) on an ephemeral loopback port and
# exports HTTPS_PROXY/HTTP_PROXY/ALL_PROXY so proxy-HONORING children (curl/git/most SDKs) can reach
# ONLY allowlisted hosts. Sourced after common.sh + store.sh.
#
# Default: OFF. With no allowlist (or an all-comment one) `run` behaves exactly as before — no bound is
# invented behind the user's back. The user opts in by adding hosts to $(agsec_config_dir)/egress.allow.
# HONEST CEILING: a bound for proxy-honoring clients, NOT a kernel jail — a child that ignores the proxy
# env or opens a raw socket bypasses it (which is why this is paired with the in-store canary).

egress_allow_file() { printf '%s\n' "$(agsec_config_dir)/egress.allow"; }
# egress-proxy.pl is egress.sh's sibling in lib/. Resolve via AGENT_SECRETS_LIB when set (dispatcher),
# else from this file's own directory (the wrappers set only AGENT_SECRETS_ROOT).
egress_proxy_script() {
  local lib="${AGENT_SECRETS_LIB:-}"
  [ -n "$lib" ] || lib="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
  printf '%s\n' "$lib/egress-proxy.pl"
}

# True iff an allowlist exists AND carries at least one real rule (non-blank, non-comment).
egress_enabled() {
  local f; f="$(egress_allow_file)"
  [ -f "$f" ] || return 1
  grep -qE '^[[:space:]]*[^[:space:]#]' "$f" 2>/dev/null
}

# Count of real rules (0 if none / no file). Names-only: rules are hostnames, never secrets.
egress_rule_count() {
  local f n; f="$(egress_allow_file)"
  [ -f "$f" ] || { printf '0'; return 0; }
  n="$(grep -cE '^[[:space:]]*[^[:space:]#]' "$f" 2>/dev/null || true)"
  printf '%s' "${n:-0}"
}

# Start the proxy in the background. On success echoes the bound port and sets EGRESS_PROXY_PID; on any
# failure warns and returns non-zero (caller falls back to running WITHOUT the bound — honest, not fatal).
# On success sets globals EGRESS_PORT + EGRESS_PROXY_PID and returns 0; on any failure warns, clears
# both, and returns non-zero. MUST be called DIRECTLY (never via $(...)): a command-substitution subshell
# would strand EGRESS_PROXY_PID, and a later `kill $EGRESS_PROXY_PID` on an EMPTY value degenerates to
# `kill 0` — SIGTERM to the CALLER'S WHOLE PROCESS GROUP (the orchestrating shell). It echoes nothing.
egress_start() {
  EGRESS_PORT=""; EGRESS_PROXY_PID=""
  [ -x /usr/bin/perl ] || { agsec_warn "egress: /usr/bin/perl not found — running WITHOUT the allowlist"; return 1; }
  local script; script="$(egress_proxy_script)"
  [ -f "$script" ] || { agsec_warn "egress: proxy script missing ($script) — running WITHOUT the allowlist"; return 1; }
  local portfile; portfile="$(mktemp "${TMPDIR:-/tmp}/agsec-egress.XXXXXX")"
  # Daemon fd hygiene: detach stdin + close inherited fd 3 so the long-lived proxy holds none of the
  # parent's fds (a backgrounded child inheriting fd 3 also hangs bats at suite end).
  /usr/bin/perl "$script" "$portfile" "$(egress_allow_file)" </dev/null >/dev/null 2>&1 3>&- &
  EGRESS_PROXY_PID=$!
  local port="" waited=0
  while [ "$waited" -lt 30 ]; do
    port="$(cat "$portfile" 2>/dev/null || true)"
    [ -n "$port" ] && break
    kill -0 "$EGRESS_PROXY_PID" 2>/dev/null || break   # proxy died (e.g. bind failed)
    sleep 0.1; waited=$((waited + 1))
  done
  rm -f "$portfile"
  if [ -z "$port" ]; then
    agsec_warn "egress: proxy did not start — running WITHOUT the allowlist"
    [ -n "$EGRESS_PROXY_PID" ] && kill "$EGRESS_PROXY_PID" 2>/dev/null || true
    EGRESS_PROXY_PID=""; return 1
  fi
  EGRESS_PORT="$port"
}

# _egress_reap — kill the proxy iff we hold a real PID. NEVER `kill 0`/`kill ""` (SIGTERMs the group).
_egress_reap() { case "${EGRESS_PROXY_PID:-}" in ''|0|*[!0-9]*) : ;; *) kill "$EGRESS_PROXY_PID" 2>/dev/null || true ;; esac; }

# The single entry point for `run` and the wrappers: inject secrets AND, when an allowlist is configured
# (and not opted out via AGENT_SECRETS_NO_EGRESS), route the child's HTTP(S) through the loopback bound.
# Execs (process-replace) when there is no proxy to tear down; otherwise stays alive to reap the proxy
# and forwards the child's exit code.  Usage: egress_run -- <cmd> [args...]
egress_run() {
  [ "${1:-}" = "--" ] && shift
  [ "$#" -ge 1 ] || agsec_die "egress_run: usage: egress_run -- <cmd> [args...]"
  if [ -n "${AGENT_SECRETS_NO_EGRESS:-}" ] || ! egress_enabled; then
    store_exec -- "$@"                       # exec; unchanged behavior when no bound is configured / opted out
  fi
  # A pre-existing HTTPS_PROXY (e.g. a mandated corporate proxy) IS the authoritative egress bound —
  # DEFER to it. Overriding it would route the child AROUND the corporate control (and can brick the
  # agent in exactly the locked-down environment the docs point at).
  if [ -n "${HTTPS_PROXY:-}${https_proxy:-}" ]; then
    agsec_note "egress: an existing HTTPS_PROXY is set — deferring to it (agent-secrets never overrides a corporate proxy)"
    store_exec -- "$@"
  fi
  egress_start || store_exec -- "$@"         # start failed (warned) → honest fallback (execs; no proxy to reap)
  export HTTPS_PROXY="http://127.0.0.1:$EGRESS_PORT" HTTP_PROXY="http://127.0.0.1:$EGRESS_PORT" ALL_PROXY="http://127.0.0.1:$EGRESS_PORT"
  export https_proxy="$HTTPS_PROXY" http_proxy="$HTTP_PROXY" all_proxy="$ALL_PROXY"
  export NO_PROXY="127.0.0.1,localhost" no_proxy="127.0.0.1,localhost"   # keep the proxy hop + local services direct
  agsec_note "egress allowlist active (proxy 127.0.0.1:$EGRESS_PORT; $(egress_rule_count) rule(s)) — non-allowlisted hosts refused"
  trap '_egress_reap' EXIT INT TERM
  store_exec_managed -- "$@"
  local rc=$?
  _egress_reap
  exit "$rc"
}
