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

sub load_rules {
  my @rules;
  open(my $fh, '<', $allowfile) or return @rules;
  while (my $l = <$fh>) {
    $l =~ s/\r?\n$//;
    $l =~ s/^\s+|\s+$//g;
    next if $l eq '' || $l =~ /^#/;
    push @rules, lc $l;
  }
  close $fh;
  return @rules;
}

# A host is allowed if it equals a rule's host part, or matches a `*.suffix` wildcard rule.
sub host_allowed {
  my ($host) = @_;
  $host = lc $host;
  for my $r (load_rules()) {
    (my $rh = $r) =~ s/:\d+$//;                     # a :port in the rule does not constrain the host match
    if ($rh =~ /^\*\.(.+)$/) {
      my $suf = $1;
      return 1 if $host eq $suf || $host =~ /\.\Q$suf\E$/;
    } elsif ($host eq $rh) {
      return 1;
    }
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

sub handle {
  my ($client) = @_;
  $client->autoflush(1);
  my $line = <$client>;
  return unless defined $line;

  # HTTPS tunnel: CONNECT host:port HTTP/x
  if ($line =~ m{^CONNECT\s+([^:\s]+):(\d+)\s+HTTP/}i) {
    my ($host, $rport) = ($1, $2);
    while (my $h = <$client>) { last if $h =~ /^\r?\n$/; }      # drain request headers
    return refuse($client, 403, 'Forbidden') unless host_allowed($host);
    my $remote = IO::Socket::INET->new(PeerAddr => $host, PeerPort => $rport, Proto => 'tcp')
      or return refuse($client, 502, 'Bad Gateway');
    print $client "HTTP/1.1 200 Connection established\r\n\r\n";
    return relay($client, $remote);
  }

  # Plain HTTP proxy: METHOD http://host[:port]/path HTTP/x  (rewritten to origin-form upstream)
  if ($line =~ m{^(\S+)\s+http://([^/:\s]+)(?::(\d+))?(\S*)\s+HTTP/(\S+)}i) {
    my ($method, $host, $hport, $path, $ver) = ($1, $2, ($3 || 80), ($4 || '/'), $5);
    return refuse($client, 403, 'Forbidden') unless host_allowed($host);
    my $remote = IO::Socket::INET->new(PeerAddr => $host, PeerPort => $hport, Proto => 'tcp')
      or return refuse($client, 502, 'Bad Gateway');
    $remote->autoflush(1);
    print $remote "$method $path HTTP/$ver\r\n";
    while (my $h = <$client>) { print $remote $h; last if $h =~ /^\r?\n$/; }
    return relay($client, $remote);
  }

  refuse($client, 405, 'Method Not Allowed');   # not a proxy request
}

while (my $client = $server->accept) {
  my $pid = fork;
  next if $pid;            # parent keeps accepting
  $server->close;          # child
  handle($client);
  exit 0;
}
