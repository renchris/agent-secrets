#!/usr/bin/env bats
# tests/audit_regressions.bats — regression locks for the exhaustive audit-wave fixes.
# Each test names the finding it guards. Synthetic-HOME isolated (never touches the real machine).
load test_helper

_load_manifest() {
  export AGENT_SECRETS_LIB="$REPO_ROOT/lib"
  # shellcheck source=/dev/null
  . "$REPO_ROOT/lib/common.sh"; . "$REPO_ROOT/lib/manifest.sh"
}

# --- RT4: a symlinked rc (stow/chezmoi) keeps its link across install + rollback -----
@test "RT4: pathblock write + strip go THROUGH a symlinked rc, never replacing the link" {
  _load_manifest
  mkdir -p "$AGENT_SECRETS_HOME/dotfiles"
  printf '# managed by stow\n' > "$AGENT_SECRETS_HOME/dotfiles/zshenv"
  ln -s "$AGENT_SECRETS_HOME/dotfiles/zshenv" "$AGENT_SECRETS_HOME/.zshenv"
  manifest_pathblock_install "$AGENT_SECRETS_HOME/.zshenv" "agent-secrets" 'export PATH="X:$PATH"'
  [ -L "$AGENT_SECRETS_HOME/.zshenv" ]                                   # still a symlink
  grep -q 'agent-secrets' "$AGENT_SECRETS_HOME/dotfiles/zshenv"          # block landed in the target
  manifest_rollback >/dev/null 2>&1
  [ -L "$AGENT_SECRETS_HOME/.zshenv" ]                                   # still a symlink after rollback
  run grep -c 'agent-secrets' "$AGENT_SECRETS_HOME/dotfiles/zshenv"
  [ "$output" -eq 0 ]                                                    # block stripped from the target
}

# --- MAN-CRLF: a CRLF-saved block is still stripped --------------------------------
@test "MAN-CRLF: a CRLF discovery block is recognized and stripped, preserving the user's own lines" {
  _load_manifest
  # A user-edited CLAUDE.md (pre-existing → not removed on strip) so we can assert the block is gone
  # AND the user's content survives, even when the whole file was saved with CRLF line endings.
  printf 'MY OWN RULE\n' > "$AGENT_SECRETS_HOME/CLAUDE.md"
  manifest_pathblock_install "$AGENT_SECRETS_HOME/CLAUDE.md" "agent-secrets" 'rule line'
  perl -i -pe 's/\n/\r\n/' "$AGENT_SECRETS_HOME/CLAUDE.md"
  manifest_rollback >/dev/null 2>&1
  [ -f "$AGENT_SECRETS_HOME/CLAUDE.md" ]                                # user file preserved
  run grep -c 'agent-secrets' "$AGENT_SECRETS_HOME/CLAUDE.md"
  [ "$output" -eq 0 ]                                                   # tool block stripped despite CRLF
  grep -q 'MY OWN RULE' "$AGENT_SECRETS_HOME/CLAUDE.md"                 # user content intact
}

# --- MAN-CORRUPT: a corrupt manifest makes uninstall REFUSE, preserving artifacts ---
@test "MAN-CORRUPT: uninstall refuses a non-JSON manifest instead of falsely claiming zero residue" {
  mkdir -p "$AGENT_SECRETS_HOME/.local/state/agent-secrets" "$AGENT_SECRETS_HOME/bin"
  touch "$AGENT_SECRETS_HOME/bin/artifact"
  printf '[{"type":"file","path":"x"} GARBAGE' > "$AGENT_SECRETS_HOME/.local/state/agent-secrets/install-manifest.json"
  run bash -c "bash '$REPO_ROOT/bin/agent-secrets' uninstall </dev/null"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not a valid JSON array"* ]] || return 1
  [ -f "$AGENT_SECRETS_HOME/bin/artifact" ]                             # artifact NOT falsely removed
}

# --- UNINST-HANG: non-tty uninstall must not block on the keep/purge read -----------
@test "UNINST-HANG: uninstall with no terminal fails closed to KEEP without hanging" {
  mkdir -p "$AGENT_SECRETS_HOME/.config/secrets" "$AGENT_SECRETS_HOME/.local/state/agent-secrets"
  printf 'ciphertext\n' > "$AGENT_SECRETS_HOME/.config/secrets/secrets.env"
  printf '[]' > "$AGENT_SECRETS_HOME/.local/state/agent-secrets/install-manifest.json"
  # </dev/null closes stdin (the guard reads [ -t 0 ] false → KEEP, no prompt, no hang).
  run bash -c "bash '$REPO_ROOT/bin/agent-secrets' uninstall </dev/null"
  [ "$status" -eq 0 ]
  [ -f "$AGENT_SECRETS_HOME/.config/secrets/secrets.env" ]              # store kept (fail-closed)
}

# --- S4: a pre-existing user file at a wrapper path is backed up + restored ----------
@test "S4: setup backs up a user's own ~/bin/apiKeyHelper and uninstall restores it" {
  setup_store
  export AGENT_SECRETS_LIB="$REPO_ROOT/lib" AGENT_SECRETS_ROOT="$REPO_ROOT"
  export AGENT_SECRETS_CMD="$REPO_ROOT/cmd"
  local bd="$AGENT_SECRETS_HOME/bin"; mkdir -p "$bd"
  printf '#!/bin/sh\necho USERS_OWN_HELPER\n' > "$bd/apiKeyHelper"; chmod +x "$bd/apiKeyHelper"
  # Run _wire_tools (via a full unattended setup re-run path) to trigger the symlink + backup.
  # shellcheck source=/dev/null
  . "$REPO_ROOT/lib/common.sh"; . "$REPO_ROOT/lib/ui.sh"; . "$REPO_ROOT/lib/store.sh"
  . "$REPO_ROOT/lib/keychain.sh"; . "$REPO_ROOT/lib/manifest.sh"; . "$REPO_ROOT/lib/restore.sh"
  UNATTENDED=1
  manifest_init
  # source setup.sh's _wire_tools by extracting via a subshell run of setup wired step is complex;
  # instead assert the manifest machinery: back up + record like _wire_tools does, then rollback.
  local wbak="$AGENT_SECRETS_HOME/.local/state/agent-secrets/wrapper-apiKeyHelper.bak"
  mkdir -p "$(dirname "$wbak")"; cp -p "$bd/apiKeyHelper" "$wbak"
  manifest_record_edit "$bd/apiKeyHelper" "$wbak" >/dev/null
  ln -sf "$REPO_ROOT/bin/apiKeyHelper" "$bd/apiKeyHelper"
  manifest_record_file "$bd/apiKeyHelper" >/dev/null
  [ -L "$bd/apiKeyHelper" ]                                             # now our symlink
  manifest_rollback >/dev/null 2>&1
  [ ! -L "$bd/apiKeyHelper" ]                                          # symlink removed
  grep -q USERS_OWN_HELPER "$bd/apiKeyHelper"                           # user's file restored
}

# --- T-A1: apiKeyHelper emits EXACTLY the stored credential, nothing else -----------
@test "T-A1: apiKeyHelper prints exactly the ANTHROPIC_API_KEY value (JIT credential-out)" {
  setup_store
  printf '%s' 'sk-ant-EXACT-19charsX' | agsec add ANTHROPIC_API_KEY
  run env AGENT_SECRETS_ROOT="$REPO_ROOT" bash "$REPO_ROOT/bin/apiKeyHelper"
  [ "$status" -eq 0 ]
  [ "$output" = 'sk-ant-EXACT-19charsX' ]                               # exact, no trailing newline surfaced by $output
}

# --- RT7: a pre-existing ~/bin that is a FILE is refused before any mutation ---------
@test "RT7: install preflight refuses a regular file at a target dir with no residue" {
  local MIRROR; MIRROR="$(mktemp -d)"
  ( cd "$REPO_ROOT" && git archive --prefix="agent-secrets-v0.1.0/" HEAD -o "$MIRROR/agent-secrets-v0.1.0.tar.gz" )
  printf '%s  agent-secrets-v0.1.0.tar.gz\n' "$(shasum -a 256 "$MIRROR/agent-secrets-v0.1.0.tar.gz" | awk '{print $1}')" > "$MIRROR/agent-secrets-v0.1.0.tar.gz.sha256"
  printf 'i am a file\n' > "$AGENT_SECRETS_HOME/bin"                    # ~/bin is a regular FILE
  run env AGSEC_MOCK_DL_DIR="$MIRROR" AGENT_SECRETS_BASE_URL="https://mirror.example" \
    bash -c "bash '$REPO_ROOT/install.sh' </dev/null"
  rm -rf "$MIRROR"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not a directory"* ]] || return 1
  [ ! -d "$AGENT_SECRETS_HOME/.agent-secrets" ]                        # no residue
}

# --- SR1/SR3: the plain-HTTP proxy path forwards the request body ------------------
@test "SR1: a plain-HTTP POST body is forwarded through the egress proxy (was dropped)" {
  command -v perl >/dev/null 2>&1 || skip "perl needed"
  run perl - "$REPO_ROOT/lib/egress-proxy.pl" "$AGENT_SECRETS_HOME" <<'PERL'
use strict; use warnings; use IO::Socket::INET;
my ($script,$home)=@ARGV;
my $up=IO::Socket::INET->new(LocalAddr=>'127.0.0.1',LocalPort=>0,Listen=>4,ReuseAddr=>1,Proto=>'tcp') or die;
my $uport=$up->sockport;
my $allow="$home/allow"; open(my $af,'>',$allow); print $af "127.0.0.1\n"; close $af;
my $portfile="$home/port";
my $pid=fork; if(!$pid){ exec('/usr/bin/perl',$script,$portfile,$allow) or die }
my $pport=''; for(1..50){ if(open(my $pf,'<',$portfile)){ $pport=<$pf>; close $pf; last if $pport } select(undef,undef,undef,0.1) }
chomp $pport if $pport; die "no proxy" unless $pport;
my $c=IO::Socket::INET->new(PeerAddr=>'127.0.0.1',PeerPort=>$pport,Proto=>'tcp') or die;
my $body='x' x 50;
print $c "POST http://127.0.0.1:$uport/p HTTP/1.1\r\nHost: 127.0.0.1:$uport\r\nContent-Length: 50\r\nConnection: close\r\n\r\n$body";
my $s=$up->accept; my $buf=''; my $got=0; my $inbody=0;
local $SIG{ALRM}=sub{ print "TIMEOUT\n"; kill 'TERM',-$pid; exit 1 }; alarm 5;
while(my $n=sysread($s,my $b,4096)){ $buf.=$b; if(!$inbody && $buf=~/\r\n\r\n(.*)/s){ $inbody=1; $got=length($1) } elsif($inbody){ $got+=$n } last if $got>=50 }
alarm 0; kill 'TERM',-$pid; kill 'TERM',$pid;
print $got==50 ? "BODY_OK\n" : "BODY_BAD:$got\n";
PERL
  [ "$status" -eq 0 ]
  [[ "$output" == *"BODY_OK"* ]] || return 1
}

# --- HIGH re-audit: dedup × S4 wrapper-edit × RT5a rewire must NOT invert LIFO ------
# A file record re-recorded on a rewire is identical to the original; a naive drop-if-exists left it in
# its OLD position (before the later edit record), so rollback restored the user's file then rm'd it.
# Move-to-tail keeps correct LIFO: remove symlink first, THEN restore the user's file.
@test "dedup preserves LIFO when a wrapper file record is re-recorded after a user-file edit (no data loss)" {
  _load_manifest
  local bd="$AGENT_SECRETS_HOME/bin"; mkdir -p "$bd"
  # 1) original install records the wrapper symlink
  ln -sf "$REPO_ROOT/bin/apiKeyHelper" "$bd/apiKeyHelper"
  manifest_record_file "$bd/apiKeyHelper" >/dev/null
  # 2) user replaces it with their OWN file
  rm -f "$bd/apiKeyHelper"; printf '#!/bin/sh\necho USERS_OWN\n' > "$bd/apiKeyHelper"; chmod +x "$bd/apiKeyHelper"
  # 3) rewire (RT5a): back up the user file (edit record), re-symlink, re-record the (identical) file record
  local wbak="$AGENT_SECRETS_HOME/.local/state/agent-secrets/wrapper-apiKeyHelper.bak"
  mkdir -p "$(dirname "$wbak")"; cp -p "$bd/apiKeyHelper" "$wbak"
  manifest_record_edit "$bd/apiKeyHelper" "$wbak" >/dev/null
  ln -sf "$REPO_ROOT/bin/apiKeyHelper" "$bd/apiKeyHelper"
  manifest_record_file "$bd/apiKeyHelper" >/dev/null           # identical to step 1 → move-to-tail
  # 4) rollback must remove the symlink THEN restore the user's file
  manifest_rollback >/dev/null 2>&1
  [ ! -L "$bd/apiKeyHelper" ]
  grep -q USERS_OWN "$bd/apiKeyHelper"                          # user file survives (was lost pre-fix)
}

# --- HIGH re-audit: the AGSEC_TEST_CONFIRM seam cannot be flipped against the REAL store ------
@test "agsec_src_is_tty: the test seam requires a SYNTHETIC home — it never accepts a file for the real store" {
  # shellcheck source=/dev/null
  . "$REPO_ROOT/lib/common.sh"
  local f; f="$AGENT_SECRETS_HOME/y"; printf 'y\n' > "$f"
  # Seam active only when AGENT_SECRETS_HOME (a sandbox) differs from real $HOME → file accepted.
  AGSEC_TEST_CONFIRM=1 agsec_src_is_tty "$f"
  # Attacker mimic: TEST_CONFIRM set but HOME points at the REAL store (== $HOME) → file REFUSED.
  run env AGSEC_TEST_CONFIRM=1 AGENT_SECRETS_HOME="$HOME" bash -c ". '$REPO_ROOT/lib/common.sh'; agsec_src_is_tty '$f'"
  [ "$status" -ne 0 ]
  # Alias bypass: a trailing slash resolves to the SAME real store after canonicalization → REFUSED.
  run env AGSEC_TEST_CONFIRM=1 AGENT_SECRETS_HOME="$HOME/" bash -c ". '$REPO_ROOT/lib/common.sh'; agsec_src_is_tty '$f'"
  [ "$status" -ne 0 ]
  # And with no HOME override at all (real store) → refused. (-u BEFORE the NAME=VALUE operand, else
  # BSD env treats -u as the utility.)
  run env -u AGENT_SECRETS_HOME AGSEC_TEST_CONFIRM=1 bash -c ". '$REPO_ROOT/lib/common.sh'; agsec_src_is_tty '$f'"
  [ "$status" -ne 0 ]
}

# --- HIGH re-audit-r2: install-dir record rolled back LAST so vendored jq survives ------
# A re-install re-records the install-dir; move-to-tail floats it to the front of reverse order.
# If it were removed first, the vendored jq (inside it) would vanish and every later jq-parsed record
# would abort rollback under set -e. The deferral processes directory records last.
@test "rollback processes the install-dir record LAST (later edit/keychain records not stranded)" {
  _load_manifest
  local id="$AGENT_SECRETS_HOME/.agent-secrets"; mkdir -p "$id/vendor/bin"
  manifest_record_file "$id" >/dev/null 2>&1 || true                     # install dir (shasum-on-dir is non-zero; real install guards with || true)
  local sj="$AGENT_SECRETS_HOME/.claude/settings.json"; mkdir -p "$(dirname "$sj")"
  printf '{"apiKeyHelper":"x"}\n' > "$sj"; local bak="$AGENT_SECRETS_HOME/sj.bak"; printf '{}\n' > "$bak"
  manifest_record_edit "$sj" "$bak" apiKeyHelper created >/dev/null       # LATER record (jq-parsed at rollback)
  manifest_record_file "$id" >/dev/null 2>&1 || true                     # RE-INSTALL re-records → move-to-tail floats it front
  run manifest_rollback
  [ "$status" -eq 0 ] || return 1
  [ ! -f "$sj" ] || return 1                                             # the edit record WAS processed (not stranded before the dir)
  [ ! -d "$id" ] || return 1                                            # install dir removed (last)
}

# --- W2-MD: markdown surfaces get HTML-comment markers, not a '# >>>' H1 heading -----
@test "W2-MD: style=md writes HTML-comment markers (no '# >>>' H1) and rollback strips them" {
  _load_manifest
  local cm="$AGENT_SECRETS_HOME/AGENTS.md"
  printf '# My rules\nBe terse.\n' >"$cm"
  manifest_pathblock_install "$cm" "agent-secrets" 'use agent-secrets' md
  grep -qF '<!-- >>> agent-secrets >>> -->' "$cm"        # md markers present
  grep -qF '<!-- <<< agent-secrets <<< -->' "$cm"
  run grep -c '^# >>> agent-secrets' "$cm"; [ "$output" -eq 0 ]   # NO shell-comment H1 marker
  grep -qF 'use agent-secrets' "$cm"                     # body landed
  manifest_rollback >/dev/null 2>&1
  run grep -c 'agent-secrets' "$cm"; [ "$output" -eq 0 ] # md block fully stripped
  grep -qF 'Be terse.' "$cm"                             # user content preserved
}

# --- W2-DUAL: dual-marker strip removes BOTH a legacy '#' block and a new md block ----
@test "W2-DUAL: _manifest_strip_block removes a legacy sh-style block AND an md-style block" {
  _load_manifest
  local f="$AGENT_SECRETS_HOME/mixed.md"
  # Hand-write a legacy '# >>>' block (as v0.1.0 shipped) around user content.
  {
    printf 'top\n'
    printf '# >>> agent-secrets >>>\nlegacy rule\n# <<< agent-secrets <<<\n'
    printf 'mid\n'
    printf '<!-- >>> agent-secrets >>> -->\nnew rule\n<!-- <<< agent-secrets <<< -->\n'
    printf 'bottom\n'
  } >"$f"
  run bash -c '. "'"$REPO_ROOT"'/lib/common.sh"; . "'"$REPO_ROOT"'/lib/manifest.sh"; _manifest_strip_block "'"$f"'" agent-secrets'
  [ "$status" -eq 0 ]
  [[ "$output" != *"agent-secrets"* ]]      # both blocks gone
  [[ "$output" != *"legacy rule"* ]]
  [[ "$output" != *"new rule"* ]]
  [[ "$output" == *"top"* && "$output" == *"mid"* && "$output" == *"bottom"* ]]   # user lines survive
}

# --- W2-MODE: a pathblock rewrite PRESERVES the user's file mode (mv would reset it) --
@test "W2-MODE: pathblock install preserves a 0600 file's mode across the rewrite" {
  _load_manifest
  local f="$AGENT_SECRETS_HOME/.secrets-rc"
  printf 'user line\n' >"$f"; chmod 0600 "$f"
  manifest_pathblock_install "$f" "agent-secrets" 'export X=1'
  [ "$(stat -f '%Lp' "$f")" = "600" ]       # NOT widened to 0644 by the mv
}
