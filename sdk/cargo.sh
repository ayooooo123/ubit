#!/bin/sh
# Runs cargo with the build-host paths remapped, so that the rlibs of uBit and of every
# dependency (rustls, tokio, ring and the others) hold no home-directory or checkout path.
# Cargo's own `trim-paths` profile option would do this, but it is not stable yet.
# Usage: sdk/cargo.sh build | test | ...   (any cargo arguments)
set -eu
cd "$(dirname "$0")/.."
# rustc and the C compiler use the last matching prefix, so the checkout (inside $HOME) goes last.
# gcc before 12 does not pass -ffile-prefix-map to the assembler, so ring's .S objects keep
# their paths unless -fdebug-prefix-map is also given.
RUSTFLAGS="${RUSTFLAGS:-} --remap-path-prefix=$HOME=~ --remap-path-prefix=$PWD=."
MAP="-ffile-prefix-map=$HOME=~ -fdebug-prefix-map=$HOME=~ -ffile-prefix-map=$PWD=. -fdebug-prefix-map=$PWD=."
CFLAGS="${CFLAGS:-} $MAP"
CXXFLAGS="${CXXFLAGS:-} $MAP"
export RUSTFLAGS CFLAGS CXXFLAGS
exec cargo "$@"
