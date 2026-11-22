#!/bin/sh
# Fails when a build artifact holds the home-directory path of the machine that built it, in
# its $HOME spelling or its physical one (they differ when the home directory is a symlink).
# Usage: tests/home-paths.sh FILE...   (pass binaries or rlibs, not compressed archives)
set -eu
[ $# -gt 0 ] || { echo "usage: $0 FILE..." >&2; exit 2; }
case "${HOME:-}" in /?*) ;; *) echo "HOME must be an absolute path other than /" >&2; exit 2 ;; esac
PHOME=$(cd "$HOME" && pwd -P)

bad=0
for f in "$@"; do
  if [ ! -f "$f" ] || [ ! -r "$f" ]; then
    echo "FAIL $f: no such readable file"
    bad=1
    continue
  fi
  n=$(LC_ALL=C grep -a -o -F -e "$HOME" -e "$PHOME" "$f" | wc -l | tr -d ' ')
  if [ "$n" -gt 0 ]; then
    echo "FAIL $f: $n home-directory paths"
    bad=1
  else
    echo "ok   $f"
  fi
done
exit $bad
