#!/bin/bash
# Phase 0: AppLock contention between root and a normal user.
#
#   sudo scripts/phase0/lock-contention.sh <DIR>
#
# AppLock is flock(2) on the app bundle directory, opened read-only. The test
# suite shows it excludes other processes of the same user and works without
# write access; tests do not run as root, so this checks the remaining case:
# a root process and a user process locking the same app, in both directions,
# on an app the user owns and on a root-owned app the user can only read (as
# in /Applications).
#
# Creates a root-owned work directory under DIR holding two empty .app
# directories and two marker directories, and removes it afterwards. No app is
# read or written.
#
# Root acts on paths here, so the user must not be able to swap anything on
# them for a symlink while it runs: DIR and every directory above it must be
# root-owned and either not group- or world-writable or sticky (/private/tmp
# qualifies), the work directory stays root-owned, and each process writes
# markers only into a directory it owns.

set -euo pipefail

DIR="${1:-}"
if [ -z "$DIR" ]; then echo "usage: sudo $0 <DIR>   (DIR must be safe from the user, e.g. /private/tmp)" >&2; exit 2; fi
if [ "$(id -u)" -ne 0 ] || [ -z "${SUDO_USER:-}" ] || [ "$SUDO_USER" = root ]; then
  echo "run with sudo from a normal user account" >&2; exit 2
fi
USER_NAME="$SUDO_USER"
DIR="$(cd "$DIR" && pwd -P)"

# A directory the user could write lets them rename the work directory away
# and leave a symlink in its place, redirecting root's chown, chmod, and rm.
d="$DIR"
while :; do
  read -r owner mode < <(stat -f '%u %Lp' "$d")
  if [ "$owner" -ne 0 ] || { [ $(( 8#$mode & 8#022 )) -ne 0 ] && [ ! -k "$d" ]; }; then
    echo "refusing $DIR: $d is writable by someone other than root; use a directory such as /private/tmp" >&2; exit 2
  fi
  [ "$d" = / ] && break
  d="$(dirname "$d")"
done

WORK="$(mktemp -d "$DIR/lock-contention.XXXXXX")"
chmod 755 "$WORK"
HOLDER=""
release() { [ -n "$HOLDER" ] && { kill "$HOLDER" 2>/dev/null || true; wait "$HOLDER" 2>/dev/null || true; }; HOLDER=""; }
cleanup() { release; rm -rf "$WORK"; }
trap cleanup EXIT

USER_APP="$WORK/UserOwned.app"
ROOT_APP="$WORK/RootOwned.app"
ROOT_MARKS="$WORK/markers-root"
USER_MARKS="$WORK/markers-user"
mkdir "$USER_APP" "$ROOT_APP" "$ROOT_MARKS" "$USER_MARKS"
chmod 755 "$ROOT_APP"; chmod 700 "$ROOT_MARKS" "$USER_MARKS"
# Pathname operations on entries the user cannot replace: WORK is root-owned.
chown -h "$USER_NAME" "$USER_APP" "$USER_MARKS"

# as WHO CMD...: run CMD as root or as the user. Always called in a subshell
# (`&` or `$(...)`); exec makes a background holder's $! the process that
# holds the lock (or sudo, which forwards the kill), not a wrapper subshell.
as() { local who="$1"; shift; if [ "$who" = root ]; then exec "$@"; else exec sudo -u "$USER_NAME" "$@"; fi; }

# hold WHO APP MARKER: take the lock the way AppLock does (read-only,
# O_DIRECTORY | O_NOFOLLOW) and keep it until killed.
hold() {
  as "$1" /usr/bin/perl -e '
    use Fcntl qw(:flock :DEFAULT);
    sysopen(my $fh, $ARGV[0], O_RDONLY | O_DIRECTORY | O_NOFOLLOW) or die "open: $!";
    flock($fh, LOCK_EX | LOCK_NB) or die "flock: $!";
    sysopen(my $m, $ARGV[1], O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600) or die "marker: $!"; close($m);
    sleep 60;' "$2" "$3" &
  HOLDER=$!
  for _ in $(seq 50); do [ -e "$3" ] && return 0; sleep 0.1; done
  echo "ERROR: $1 could not lock $2" >&2; return 1
}

# try WHO APP: prints "acquired" or "busy"; fails if the directory cannot be opened.
try() {
  as "$1" /usr/bin/perl -e '
    use Fcntl qw(:flock :DEFAULT);
    sysopen(my $fh, $ARGV[0], O_RDONLY | O_DIRECTORY | O_NOFOLLOW) or die "open: $!";
    print(flock($fh, LOCK_EX | LOCK_NB) ? "acquired" : "busy");' "$2"
}

FAIL=0
check() { # check HOLDER CONTENDER APP LABEL
  local marks="$USER_MARKS"; [ "$1" = root ] && marks="$ROOT_MARKS"
  local marker="$marks/held-$RANDOM"
  [ "$(try "$2" "$3")" = acquired ] || { echo "FAIL $4: $2 could not lock a free app"; FAIL=1; return; }
  hold "$1" "$3" "$marker"
  local held; held="$(try "$2" "$3")"
  release
  local freed; freed="$(try "$2" "$3")"
  if [ "$held" = busy ] && [ "$freed" = acquired ]; then
    echo "PASS $4: $2 sees busy while $1 holds it, acquired after"
  else
    echo "FAIL $4: while held: $held, after release: $freed"; FAIL=1
  fi
}

echo "macOS $(sw_vers -productVersion) ($(sw_vers -buildVersion)), user $USER_NAME"
check "$USER_NAME" root "$USER_APP" "user-owned app, user holds, root contends"
check root "$USER_NAME" "$USER_APP" "user-owned app, root holds, user contends"
check "$USER_NAME" root "$ROOT_APP" "root-owned app, user holds, root contends"
check root "$USER_NAME" "$ROOT_APP" "root-owned app, root holds, user contends"
exit $FAIL
