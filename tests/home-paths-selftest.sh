#!/bin/sh
# Proves that tests/home-paths.sh rejects a known hit and passes a clean file, also when the
# file name starts with a dash. The test makes its own home directory and a symlink to it, so
# the two home spellings always differ, whatever HOME the caller has.
# Usage: tests/home-paths-selftest.sh
set -eu
scan="$(cd "$(dirname "$0")" && pwd)/home-paths.sh"
dir=$(mktemp -d)
trap 'rm -rf "$dir"' EXIT
cd "$dir"
mkdir real-home
ln -s "$dir/real-home" link-home
HOME="$dir/link-home"
export HOME
PHOME=$(cd "$HOME" && pwd -P)
[ "$PHOME" != "$HOME" ] || { echo "FAIL the self-test could not make two home spellings"; exit 1; }
printf 'x\000%s/build/a.o\000y' "$HOME" > ./--hit.bin
printf 'x\000%s/build/a.o\000y' "$PHOME" > ./--physical-hit.bin
printf 'x\000/build/a.o\000y' > ./--clean.bin
fail=0
for hit in --hit.bin --physical-hit.bin; do
  if "$scan" "$hit"; then echo "FAIL the scan passed $hit, which holds a home path"; fail=1; fi
done
"$scan" --clean.bin || { echo "FAIL the scan rejected a clean file"; fail=1; }
[ "$fail" -eq 0 ] && echo "ok   the scan rejects both home spellings and passes a clean file"
exit $fail
