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
  # The file goes in on standard input, so that a name such as `--x` is never read as an
  # option. grep exits 0 on a match, 1 on no match and 2 on an error.
  status=0
  n=$(LC_ALL=C grep -a -c -F -e "$HOME" -e "$PHOME" < "$f") || status=$?
  if [ "$status" -gt 1 ]; then
    echo "FAIL $f: grep could not read the file"
    bad=1
  elif [ "$status" -eq 0 ]; then
    echo "FAIL $f: $n lines with a home-directory path"
    bad=1
  else
    echo "ok   $f"
  fi
done
exit $bad
