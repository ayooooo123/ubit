#!/bin/sh
# Cross-compiles stripped Linux x86_64 (amd64) and arm64 (aarch64) release bundles using `zig c++` (or native g++ on Linux).
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LSRC="$ROOT/linux/src/main.cpp"
DIST="$ROOT/dist"
VERSION="0.3.1"

mkdir -p "$DIST"

build_target() {
  ARCH_LABEL="$1"     # amd64 | arm64
  ZIG_TARGET="$2"     # x86_64-linux-gnu.2.28 | aarch64-linux-gnu.2.28
  GCC_BIN="$3"        # x86_64-linux-gnu-g++ | aarch64-linux-gnu-g++

  STAGE="$DIST/stage-linux-$ARCH_LABEL"
  rm -rf "$STAGE"
  mkdir -p "$STAGE"

  echo "▸ Compiling uBit for linux-$ARCH_LABEL (-Os -flto -Wl,--gc-sections -s)…"
  if command -v zig >/dev/null 2>&1; then
    zig c++ \
      -target "$ZIG_TARGET" \
      -std=c++20 \
      -Os \
      -flto \
      -ffunction-sections \
      -fdata-sections \
      -Wl,--gc-sections \
      -Wl,-s \
      -pthread \
      -ldl \
      "$LSRC" \
      -o "$STAGE/ubit"
  else
    if ! command -v "$GCC_BIN" >/dev/null 2>&1; then
      GCC_BIN="g++"
    fi
    "$GCC_BIN" \
      -std=c++20 \
      -Os \
      -flto \
      -static-libstdc++ \
      -static-libgcc \
      -ffunction-sections \
      -fdata-sections \
      -Wl,--gc-sections \
      -s \
      -pthread \
      -ldl \
      "$LSRC" \
      -o "$STAGE/ubit"
  fi

  cat > "$STAGE/ubit.desktop" <<'DESKTOP'
[Desktop Entry]
Type=Application
Name=uBit
Comment=Download video and audio from the web
Exec=ubit %u
Terminal=false
Categories=Network;AudioVideo;FileTransfer;
MimeType=x-scheme-handler/ubit;
DESKTOP

  ARCHIVE="$DIST/ubit-${VERSION}-linux-${ARCH_LABEL}.tar.gz"
  tar -czf "$ARCHIVE" -C "$STAGE" ubit ubit.desktop
  ls -lh "$STAGE/ubit" "$ARCHIVE" && wc -c "$STAGE/ubit" "$ARCHIVE"
  rm -rf "$STAGE"
}

build_target "amd64" "x86_64-linux-gnu.2.28" "x86_64-linux-gnu-g++"
build_target "arm64" "aarch64-linux-gnu.2.28" "aarch64-linux-gnu-g++"
