#!/bin/sh
# Runs cargo with the build-host paths remapped, so that the rlibs of uBit and of every
# dependency (rustls, tokio, ring and the others) hold no home-directory or checkout path.
# Cargo's own `trim-paths` profile option would do this, but it is not stable yet.
# Usage: sdk/cargo.sh build | test | ...   (any cargo arguments)
set -eu
cd "$(dirname "$0")/.."
# A path can reach the compilers in its symlink spelling or its physical one (for example a
# home directory that is a symlink, or /tmp, which is /private/tmp on macOS), so both spellings
# are remapped. rustc and the C compiler use the last matching prefix, so the checkout (inside
# $HOME) goes last.
# gcc before 12 does not pass -ffile-prefix-map to the assembler, so ring's .S objects keep
# their paths unless -fdebug-prefix-map is also given.
PHOME=$(cd "$HOME" && pwd -P)
PPWD=$(pwd -P)
RUSTFLAGS="${RUSTFLAGS:-}"
MAP=""
for pair in "$HOME=~" "$PHOME=~" "$PWD=." "$PPWD=."; do
  RUSTFLAGS="$RUSTFLAGS --remap-path-prefix=$pair"
  MAP="$MAP -ffile-prefix-map=$pair -fdebug-prefix-map=$pair"
done
CFLAGS="${CFLAGS:-}$MAP"
CXXFLAGS="${CXXFLAGS:-}$MAP"
export RUSTFLAGS CFLAGS CXXFLAGS
exec cargo "$@"
