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
# Cargo accepts a unit separator between arguments. Preserve its normal precedence:
# encoded flags, when set, take priority over whitespace-separated RUSTFLAGS.
sep=$(printf '\037')
if [ "${CARGO_ENCODED_RUSTFLAGS+x}" != x ]; then
  CARGO_ENCODED_RUSTFLAGS=
  set -f
  for flag in ${RUSTFLAGS:-}; do
    CARGO_ENCODED_RUSTFLAGS="${CARGO_ENCODED_RUSTFLAGS:+$CARGO_ENCODED_RUSTFLAGS$sep}$flag"
  done
fi
CC_SHELL_ESCAPED_FLAGS=1
for pair in "$HOME=~" "$PHOME=~" "$PWD=." "$PPWD=."; do
  CARGO_ENCODED_RUSTFLAGS="${CARGO_ENCODED_RUSTFLAGS:+$CARGO_ENCODED_RUSTFLAGS$sep}--remap-path-prefix=$pair"
  # cc-rs reads shell-quoted arguments. Escape any quote in the literal path.
  quoted=$(printf '%s' "$pair" | sed "s/'/'\\\\''/g")
  flags="'-ffile-prefix-map=$quoted' '-fdebug-prefix-map=$quoted'"
  CFLAGS="${CFLAGS:+$CFLAGS }$flags"
  CXXFLAGS="${CXXFLAGS:+$CXXFLAGS }$flags"
done
export CARGO_ENCODED_RUSTFLAGS CC_SHELL_ESCAPED_FLAGS CFLAGS CXXFLAGS
exec cargo "$@"
