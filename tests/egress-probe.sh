#!/usr/bin/env bash
# tests/egress-probe.sh — self-contained egress-proxy probe for egress.bats.
# Starts the CONNECT proxy (optionally a throwaway upstream), sends ONE CONNECT, prints the proxy's
# status line, then tears everything down on EXIT. Runs FOREGROUND under bats `run`, so bats never
# sees a lingering background process (which hangs the suite at EOF). Not shipped (tests/ is export-ignored).
#   usage: egress-probe.sh <allowfile> <target-host:port | localhost:UPPORT> [--upstream]
set -uo pipefail
REPO_ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
allow="$1"; target="$2"; want_up="${3:-}"
proxy_pid=""; up_pid=""
cleanup() {
  [ -n "$up_pid" ] && kill "$up_pid" 2>/dev/null
  if [ -n "$proxy_pid" ]; then pkill -P "$proxy_pid" 2>/dev/null; kill "$proxy_pid" 2>/dev/null; fi
}
trap cleanup EXIT

_wait_port() {  # $1=file → echo the port once written (≤4s)
  local f="$1" p="" n=0
  while [ "$n" -lt 40 ]; do p="$(cat "$f" 2>/dev/null || true)"; [ -n "$p" ] && break; sleep 0.1; n=$((n + 1)); done
  printf '%s' "$p"
}

if [ "$want_up" = "--upstream" ]; then
  upf="$(mktemp)"
  /usr/bin/perl -MIO::Socket::INET -e '
    alarm 10;
    my $s=IO::Socket::INET->new(LocalAddr=>"127.0.0.1",LocalPort=>0,Listen=>5,ReuseAddr=>1) or die;
    open(my $f,">",$ARGV[0]); print $f $s->sockport; close $f;
    my $c=$s->accept; close $c if $c;' "$upf" >/dev/null 2>&1 &
  up_pid=$!
  up_port="$(_wait_port "$upf")"; rm -f "$upf"
  target="${target/UPPORT/$up_port}"
fi

pf="$(mktemp)"
/usr/bin/perl "$REPO_ROOT/lib/egress-proxy.pl" "$pf" "$allow" >/dev/null 2>&1 &
proxy_pid=$!
port="$(_wait_port "$pf")"; rm -f "$pf"
[ -n "$port" ] || { echo "PROXY-START-FAILED"; exit 1; }

/usr/bin/perl -MIO::Socket::INET -e '
  my ($pp,$t)=@ARGV;
  my $s=IO::Socket::INET->new(PeerAddr=>"127.0.0.1",PeerPort=>$pp,Proto=>"tcp",Timeout=>3) or exit 3;
  print $s "CONNECT $t HTTP/1.1\r\nHost: $t\r\n\r\n";
  my $l=<$s>; $l//=""; $l=~s/\r?\n$//; print $l;' "$port" "$target"
