#!/usr/bin/env bash
# Scans added lines, files and commit messages for private strings without ever printing them.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/leak-gate.sh [--staged | --range <a>..<b> | --files <path>...] [--message <file>]

Scans for strings that must never reach the public repository. Prints one line
per hit as path:line: <rule>, never the matched text.

Modes (one at most; the default is --staged):
  --staged            Added lines in the staged diff.
  --range <a>..<b>    Added lines and the message of each commit in the range.
  --files <path>...   Every line of the named files.
  --message <file>    Also scan a commit message file.
  -h, --help          Show this help.

Rules:
  Generic, always on: iOS device UDIDs and simulator-style UUIDs that are not
  obviously synthetic, a team ID after "Developer ID", and home paths under
  /Users/<name> or /home/<name> other than the placeholders me, you, user,
  someone, tester, x, runner and ci.
  Private deny-list: the file named by $OFFSIDER_PRIVATE_DENYLIST, else
  ~/.config/offsider/private-denylist.txt when it exists. One case-insensitive
  extended regex per line; '#' lines and blank lines are ignored. A hit names
  the list's line number.

Binary files are skipped. A hit in a file name prints [path withheld] and line 0.

Exit status: 0 clean, 1 hits, 2 usage error.
EOF
}

die_usage() {
  printf 'leak-gate: %s\n' "$1" >&2
  printf 'Run scripts/leak-gate.sh --help for usage.\n' >&2
  exit 2
}

mode=""
range=""
message=""
files=()

set_mode() {
  [ -z "$mode" ] || die_usage "choose one of --staged, --range or --files"
  mode=$1
}

while [ $# -gt 0 ]; do
  case "$1" in
    -h | --help)
      usage
      exit 0
      ;;
    --staged)
      set_mode staged
      shift
      ;;
    --range)
      set_mode range
      [ $# -ge 2 ] || die_usage "--range needs <a>..<b>"
      range=$2
      shift 2
      ;;
    --files)
      set_mode files
      shift
      while [ $# -gt 0 ] && [ "${1#--}" = "$1" ]; do
        files+=("$1")
        shift
      done
      [ "${#files[@]}" -gt 0 ] || die_usage "--files needs at least one path"
      ;;
    --message)
      [ $# -ge 2 ] || die_usage "--message needs a file"
      [ -z "$message" ] || die_usage "--message given twice"
      message=$2
      shift 2
      ;;
    *)
      die_usage "unknown argument: $1"
      ;;
  esac
done

[ -n "$mode" ] || mode=staged

if [ -n "$message" ] && [ ! -f "$message" ]; then
  die_usage "message file not found: $message"
fi

top=""
if [ "$mode" != files ]; then
  top=$(git rev-parse --show-toplevel 2>/dev/null) || die_usage "not inside a git work tree"
fi

from=""
to=""
if [ "$mode" = range ]; then
  case "$range" in
    ?*..?*) ;;
    *) die_usage "--range needs <a>..<b>" ;;
  esac
  from=${range%%..*}
  to=${range#*..}
  for rev in "$from" "$to"; do
    git rev-parse --verify --quiet "$rev^{commit}" >/dev/null || die_usage "not a commit: $rev"
  done
fi

if [ "$mode" = files ]; then
  for f in "${files[@]}"; do
    [ -f "$f" ] || [ -L "$f" ] || die_usage "not a file: $f"
  done
fi

denylist=${OFFSIDER_PRIVATE_DENYLIST:-}
if [ -n "$denylist" ]; then
  if [ ! -f "$denylist" ] || [ ! -r "$denylist" ]; then
    die_usage "cannot read the deny-list that OFFSIDER_PRIVATE_DENYLIST names"
  fi
elif [ -n "${HOME:-}" ] && [ -f "$HOME/.config/offsider/private-denylist.txt" ]; then
  denylist=$HOME/.config/offsider/private-denylist.txt
fi

diff_opts=(--no-color --no-ext-diff --no-textconv --no-renames --diff-filter=d -U0 --src-prefix=a/ --dst-prefix=b/)

emit_jobs() {
  case "$mode" in
    staged)
      printf '\001diff\n'
      git -C "$top" -c core.quotePath=false diff --cached "${diff_opts[@]}"
      ;;
    range)
      git -C "$top" rev-list --reverse "$from..$to" | while read -r commit; do
        printf '\n\001msg %s\n' "$commit"
        git -C "$top" log -1 --no-show-signature --format=%B "$commit"
        printf '\n\001diff %s\n' "$commit"
        git -C "$top" -c core.quotePath=false diff-tree --root --no-commit-id -p "${diff_opts[@]}" "$commit"
      done
      ;;
    files)
      for f in "${files[@]}"; do
        printf '\001file %s\n' "$f"
      done
      ;;
  esac
  if [ -n "$message" ]; then
    printf '\n\001note %s\n' "$message"
  fi
}

scanner() {
  cat <<'PERL'
use strict;
use warnings;

my $denylist = shift @ARGV;
my %placeholder = map { $_ => 1 } qw(me you user someone tester x runner ci);

sub synthetic {
  my ($id) = @_;
  $id = uc $id;
  for my $group (split /-/, $id) {
    return 1 if $group =~ /^0+$/;
  }
  $id =~ tr/-//d;
  return $id =~ /([0-9A-Z])\1{5}|0123|ABCD|DEAD|BEEF|CAFE|E2E0|AAAA|1111/ ? 1 : 0;
}

my @rules = (
  ['device UDID', qr/(?<![0-9A-F])000081[0-9A-F]{2}-([0-9A-F]{16})(?![0-9A-F])/i, sub { !synthetic($_[0]) }],
  ['simulator UUID', qr/(?<![0-9A-F])([0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12})(?![0-9A-F])/i,
    sub { !synthetic($_[0]) }],
  ['team ID', qr/(?i:Developer ID)[^()\n]*\(([A-Z0-9]{10})\)/, sub { !synthetic($_[0]) }],
  ['home path', qr{(?<![\w.~-])/(?:Users|home)/([A-Za-z0-9][\w.-]*)}, sub { !$placeholder{lc $_[0]} }],
);

if (defined $denylist && length $denylist) {
  open(my $fh, '<', $denylist) or do { print STDERR "leak-gate: cannot read the deny-list\n"; exit 2 };
  my $n = 0;
  while (my $pattern = <$fh>) {
    $n++;
    $pattern =~ s/^\s+|\s+$//g;
    next if $pattern eq '' || $pattern =~ /^#/;
    my $re = eval { qr/$pattern/i };
    unless ($re) {
      print STDERR "leak-gate: deny-list line $n is not a valid pattern\n";
      exit 2;
    }
    push @rules, ["deny-list line $n", $re, undef];
  }
  close $fh;
}

sub hits {
  my ($text) = @_;
  my @found;
  for my $rule (@rules) {
    my ($label, $re, $keep) = @$rule;
    if (!$keep) {
      push @found, $label if $text =~ $re;
      next;
    }
    while ($text =~ /$re/g) {
      if ($keep->($1)) {
        push @found, $label;
        last;
      }
    }
  }
  return @found;
}

my %seen;
my $count = 0;

sub report {
  my ($where, $line, $text) = @_;
  for my $label (hits($text)) {
    my $out = "$where:$line: $label";
    next if $seen{$out}++;
    print "$out\n";
    $count++;
  }
}

sub shown_path {
  my ($prefix, $path) = @_;
  my @found = hits($path);
  my $shown = @found ? '[path withheld]' : $path;
  $shown = "$prefix:$shown" if length $prefix;
  report($shown, 0, $path) if @found;
  return $shown;
}

sub scan_file {
  my ($path, $where) = @_;
  if (-l $path) {
    my $target = readlink $path;
    report($where, 1, $target) if defined $target;
    return;
  }
  open(my $fh, '<:raw', $path) or do { print STDERR "leak-gate: cannot read $path\n"; exit 2 };
  my $head = '';
  read($fh, $head, 8000);
  return if index($head, "\0") >= 0;
  seek($fh, 0, 0);
  my $n = 0;
  while (my $line = <$fh>) {
    $n++;
    $line =~ s/\r?\n\z//;
    report($where, $n, $line);
  }
  close $fh;
}

my ($state, $prefix, $where, $n) = ('', '', '', 0);
while (my $line = <STDIN>) {
  $line =~ s/\r?\n\z//;
  if ($line =~ /^\x01(\w+) ?(.*)$/) {
    my ($kind, $arg) = ($1, $2);
    if ($kind eq 'diff') {
      ($state, $prefix, $where) = ('header', length $arg ? substr($arg, 0, 12) : '', '');
    } elsif ($kind eq 'msg') {
      ($state, $where, $n) = ('msg', substr($arg, 0, 12) . ':(message)', 0);
    } elsif ($kind eq 'file') {
      $state = '';
      scan_file($arg, $arg =~ m{^/} ? $arg : shown_path('', $arg));
    } elsif ($kind eq 'note') {
      $state = '';
      scan_file($arg, $arg);
    }
    next;
  }
  if ($state eq 'msg') {
    report($where, ++$n, $line);
  } elsif ($state ne '' && $line =~ /^diff --git (.*)$/) {
    my $pair = $1;
    my $path = $pair =~ m{^("?)a/(.*)\1 \1b/\2\1$} ? $2 : $pair;
    ($state, $where) = ('header', shown_path($prefix, $path));
  } elsif ($state eq 'header' && $line =~ /^@@ -\d+(?:,\d+)? \+(\d+)/) {
    ($state, $n) = ('hunk', $1);
  } elsif ($state eq 'hunk') {
    if ($line =~ /^@@ -\d+(?:,\d+)? \+(\d+)/) {
      $n = $1;
    } elsif ($line =~ /^\+(.*)$/s) {
      report($where, $n++, $1);
    } elsif ($line =~ /^ /) {
      $n++;
    }
  }
}

exit($count ? 1 : 0);
PERL
}

status=0
emit_jobs | perl -e "$(scanner)" "$denylist" || status=$?
exit "$status"
