#!/bin/sh
# Cross-compiles stripped Linux (amd64, arm64) and Android/Termux (android-arm64) release bundles.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LSRC="$ROOT/linux/src/main.cpp"
DIST="$ROOT/dist"
VERSION="0.3.3"

mkdir -p "$DIST"

build_linux_target() {
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

find_ndk_clangxx() {
  for NDK_ROOT in \
    "${ANDROID_NDK_LATEST_HOME:-}" \
    "${ANDROID_NDK_HOME:-}" \
    "${ANDROID_NDK_ROOT:-}" \
    "$HOME/Library/Android/sdk/ndk"/* \
    "/usr/local/lib/android/sdk/ndk"/*; do
    [ -n "$NDK_ROOT" ] && [ -d "$NDK_ROOT" ] || continue
    for HOST_TAG in linux-x86_64 darwin-x86_64 darwin-arm64; do
      CAND="$NDK_ROOT/toolchains/llvm/prebuilt/$HOST_TAG/bin/aarch64-linux-android29-clang++"
      if [ -x "$CAND" ]; then
        echo "$CAND"
        return 0
      fi
    done
  done
  return 1
}

build_android_arm64() {
  NDK_CXX="$(find_ndk_clangxx || true)"
  if [ -z "$NDK_CXX" ]; then
    echo "▸ Skipping android-arm64 (Android NDK not found)"
    return 0
  fi

  STAGE="$DIST/stage-android-arm64"
  rm -rf "$STAGE"
  mkdir -p "$STAGE"

  echo "▸ Compiling uBit for android-arm64 / Termux Bionic ($NDK_CXX)…"
  "$NDK_CXX" \
    -std=c++20 \
    -Os \
    -flto \
    -static-libstdc++ \
    -ffunction-sections \
    -fdata-sections \
    -Wl,--gc-sections \
    -s \
    -ldl \
    "$LSRC" \
    -o "$STAGE/ubit"

  ARCHIVE="$DIST/ubit-${VERSION}-android-arm64.tar.gz"
  tar -czf "$ARCHIVE" -C "$STAGE" ubit
  ls -lh "$STAGE/ubit" "$ARCHIVE" && wc -c "$STAGE/ubit" "$ARCHIVE"
  rm -rf "$STAGE"
}

if [ "${ONLY_ANDROID:-0}" = "1" ]; then
  build_android_arm64
else
  build_linux_target "amd64" "x86_64-linux-gnu.2.28" "x86_64-linux-gnu-g++"
  build_linux_target "arm64" "aarch64-linux-gnu.2.28" "aarch64-linux-gnu-g++"
  build_android_arm64
fi
