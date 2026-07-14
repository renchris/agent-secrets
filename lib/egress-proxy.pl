#!/usr/bin/perl
# lib/egress-proxy.pl — minimal allowlist HTTP CONNECT proxy in CORE Perl (no CPAN, corporate-safe,
# long-horizon-stable). Started by lib/egress.sh for `agent-secrets run`; binds an ephemeral loopback
# port and permits an outbound connection ONLY to hosts in the allowfile — everything else gets 403.
#
#   perl egress-proxy.pl <portfile> <allowfile>
#     <portfile>  : the bound port is written here (the parent reads it; race-free vs pre-picking).
#     <allowfile> : one rule per line — `host`, `host:port`, or `*.suffix`; blank / #comment ignored.
#
# HONEST CEILING (documented in SECURITY.md): this bounds proxy-HONORING clients (curl/git/most SDKs
# via HTTPS_PROXY). It is NOT a kernel jail — a process that ignores the proxy env or opens a raw
# socket bypasses it. agent-secrets pairs it with the in-store canary precisely for that residual case.
use strict;
use warnings;
use IO::Socket::INET;
use IO::Select;

my ($portfile, $allowfile) = @ARGV;
die "usage: egress-proxy.pl <portfile> <allowfile>\n" unless defined $portfile && defined $allowfile;
$SIG{CHLD} = 'IGNORE';   # auto-reap forked per-connection children
$SIG{PIPE} = 'IGNORE';

my $server = IO::Socket::INET->new(
  LocalAddr => '127.0.0.1', LocalPort => 0, Listen => 64, ReuseAddr => 1, Proto => 'tcp',
) or die "egress-proxy: cannot bind 127.0.0.1: $!\n";

# Publish the chosen port for the parent, then serve (the socket is already listening, so any
# connection the parent triggers after reading the port is queued, not refused).
open(my $pf, '>', $portfile) or die "egress-proxy: cannot write portfile $portfile: $!\n";
print $pf $server->sockport;
close $pf;

# Become our own process-group leader so the parent's reap (`kill -TERM -PID`) sweeps every forked
# per-connection child too, leaving no orphaned relay processes after `run` exits.
eval { setpgrp(0, 0); 1 } or do { };   # best-effort; harmless where setpgrp is unavailable

sub load_rules {
  my @rules;
  open(my $fh, '<', $allowfile) or return @rules;
  while (my $l = <$fh>) {
    $l =~ s/\r?\n$//;
    $l =~ s/#.*//;                 # strip a whole-line OR inline comment (hostnames never contain #)
    $l =~ s/^\s+|\s+$//g;
    next if $l eq '';
    push @rules, lc $l;
  }
  close $fh;
  return @rules;
}

# A (host, port) is allowed if the host equals a rule's host part (or matches a `*.suffix` wildcard)
# AND the port matches: a rule WITH a `:port` constrains to that port; a rule without one allows any port.
sub host_allowed {
  my ($host, $port) = @_;
  $host = lc $host;
  for my $r (load_rules()) {
    my ($rh, $rp);
    if ($r =~ /^(.+):(\d+)$/) { ($rh, $rp) = ($1, $2); } else { ($rh, $rp) = ($r, undef); }
    my $host_ok;
    if ($rh =~ /^\*\.(.+)$/) {
      my $suf = $1;
      $host_ok = ($host eq $suf || $host =~ /\.\Q$suf\E$/);
    } else {
      $host_ok = ($host eq $rh);
    }
    next unless $host_ok;
    return 1 if !defined($rp) || !defined($port) || $rp == $port;
  }
  return 0;
}

sub refuse { my ($c, $code, $msg) = @_; print $c "HTTP/1.1 $code $msg\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"; }

sub relay {
  my ($a, $b) = @_;
  my $sel = IO::Select->new($a, $b);
  OUTER: while (my @ready = $sel->can_read) {
    for my $s (@ready) {
      my $other = ($s == $a) ? $b : $a;
      my $n = sysread($s, my $buf, 65536);
      last OUTER if !defined $n || $n == 0;
      my $off = 0;
      while ($off < $n) {
        my $w = syswrite($other, $buf, $n - $off, $off);
        last OUTER if !defined $w;
        $off += $w;
      }
    }
  }
  close $a; close $b;
}

# Write ALL of $data to $sock (syswrite may short-write), matching relay()'s write loop.
sub _write_all {
  my ($sock, $data) = @_;
  my ($off, $len) = (0, length $data);
  while ($off < $len) {
    my $w = syswrite($sock, $data, $len - $off, $off);
    return if !defined $w;
    $off += $w;
  }
}

# Read the FULL request head (request line + headers up to the blank-line terminator) via sysread
# ONLY, returning (head, leftover-bytes). Mixing buffered `<$client>` readline with relay()'s sysread
# strands any body bytes that arrived coalesced with the head in the PerlIO buffer — relay() reads the
# raw fd and never sees them, so a plain-HTTP POST/PUT body is silently dropped and the upstream hangs
# awaiting Content-Length bytes. Returns () on EOF before a complete head, or on a runaway (>64KB) head.
sub read_head {
  my ($client) = @_;
  my $buf = '';
  while ($buf !~ /\r?\n\r?\n/) {
    my $n = sysread($client, $buf, 8192, length $buf);
    return () if !defined $n || $n == 0;
    return () if length($buf) > 65536;
  }
  $buf =~ /^(.*?\r?\n\r?\n)(.*)\z/s;
  return ($1, $2);
}

sub handle {
  my ($client) = @_;
  $client->autoflush(1);
  my ($head, $rest) = read_head($client);
  return unless defined $head;
  my ($line) = split /\r?\n/, $head, 2;      # the request line

  # HTTPS tunnel: CONNECT host:port HTTP/x
  if ($line =~ m{^CONNECT\s+([^:\s]+):(\d+)\s+HTTP/}i) {
    my ($host, $rport) = ($1, $2);
    return refuse($client, 403, 'Forbidden') unless host_allowed($host, $rport);
    my $remote = IO::Socket::INET->new(PeerAddr => $host, PeerPort => $rport, Proto => 'tcp')
      or return refuse($client, 502, 'Bad Gateway');
    print $client "HTTP/1.1 200 Connection established\r\n\r\n";
    _write_all($remote, $rest) if length $rest;   # forward any early client data (compliant clients wait for the 200)
    return relay($client, $remote);
  }

  # Plain HTTP proxy: METHOD http://host[:port]/path HTTP/x  (rewritten to origin-form upstream)
  if ($line =~ m{^(\S+)\s+http://([^/:\s]+)(?::(\d+))?(\S*)\s+HTTP/(\S+)}i) {
    my ($method, $host, $hport, $path, $ver) = ($1, $2, ($3 || 80), ($4 || '/'), $5);
    return refuse($client, 403, 'Forbidden') unless host_allowed($host, $hport);
    my $remote = IO::Socket::INET->new(PeerAddr => $host, PeerPort => $hport, Proto => 'tcp')
      or return refuse($client, 502, 'Bad Gateway');
    $remote->autoflush(1);
    # Origin-form request line + the ORIGINAL headers (everything after the request line in $head),
    # then the coalesced body prefix ($rest), then relay the remaining body/response.
    my $headers = $head; $headers =~ s/^.*?\r?\n//s;   # drop the request line; keep headers + blank line
    _write_all($remote, "$method $path HTTP/$ver\r\n");
    _write_all($remote, $headers);
    _write_all($remote, $rest) if length $rest;
    return relay($client, $remote);
  }

  refuse($client, 405, 'Method Not Allowed');   # not a proxy request
}

while (my $client = $server->accept) {
  my $pid = fork;
  if (!defined $pid) { close $client; next; }   # fork failed → drop THIS connection, keep the proxy alive
  next if $pid;            # parent keeps accepting
  $server->close;          # child
  handle($client);
  exit 0;
}
