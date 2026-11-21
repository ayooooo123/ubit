#!/bin/sh
# Runs cargo with the build-host paths remapped, so that the rlibs of uBit and of every
# dependency (rustls, tokio, ring and the others) hold no home-directory or checkout path.
# Cargo's own `trim-paths` profile option would do this, but it is not stable yet.
# Usage: sdk/cargo.sh build | test | ...   (any cargo arguments)
set -eu
cd "$(dirname "$0")/.."
# rustc and the C compiler use the last matching prefix, so the checkout (inside $HOME) goes last.
RUSTFLAGS="${RUSTFLAGS:-} --remap-path-prefix=$HOME=~ --remap-path-prefix=$PWD=."
CFLAGS="${CFLAGS:-} -ffile-prefix-map=$HOME=~ -ffile-prefix-map=$PWD=."
CXXFLAGS="${CXXFLAGS:-} -ffile-prefix-map=$HOME=~ -ffile-prefix-map=$PWD=."
export RUSTFLAGS CFLAGS CXXFLAGS
exec cargo "$@"
