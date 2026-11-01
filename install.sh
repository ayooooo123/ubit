#!/bin/sh
# Installs uBit.app and the `ubit` CLI on macOS (arm64) without requiring root.
#
#   curl -fsSL https://github.com/ayooooo123/ubit/releases/latest/download/install.sh | sh
set -eu

REPO="ayooooo123/ubit"
VERSION="${UBIT_VERSION:-0.3.0}"
BASE_URL="${UBIT_DOWNLOAD_URL:-https://github.com/$REPO/releases/latest/download}"

[ "$(uname -s)" = "Darwin" ] || { echo "install.sh: uBit requires macOS" >&2; exit 1; }
ARCH="$(uname -m)"
if [ "$ARCH" = "x86_64" ] && [ "$(sysctl -n sysctl.proc_translated 2>/dev/null || echo 0)" = "1" ]; then
  ARCH="arm64"
fi
[ "$ARCH" = "arm64" ] || { echo "install.sh: prebuilt release targets Apple Silicon (arm64); run ./build.sh from source" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

ARCHIVE="ubit-${VERSION}-darwin-arm64.tar.gz"
echo "▸ Downloading uBit ${VERSION}…"
curl -fsSL "${BASE_URL}/${ARCHIVE}" -o "$WORK/$ARCHIVE"

if curl -fsSL "${BASE_URL}/SHA256SUMS" -o "$WORK/SHA256SUMS" 2>/dev/null; then
  EXPECTED="$(awk -v f="$ARCHIVE" '$2 == f { print $1 }' "$WORK/SHA256SUMS")"
  if [ -n "$EXPECTED" ]; then
    ACTUAL="$(shasum -a 256 "$WORK/$ARCHIVE" | awk '{ print $1 }')"
    [ "$EXPECTED" = "$ACTUAL" ] || { echo "install.sh: SHA-256 mismatch for $ARCHIVE" >&2; exit 1; }
  fi
fi

if [ -w "/Applications" ]; then
  APP_DIR="/Applications"
else
  APP_DIR="$HOME/Applications"
  mkdir -p "$APP_DIR"
fi

rm -rf "$APP_DIR/uBit.app"
tar -xzf "$WORK/$ARCHIVE" -C "$APP_DIR"
xattr -dr com.apple.quarantine "$APP_DIR/uBit.app" 2>/dev/null || true

if [ -w "/usr/local/bin" ]; then
  BIN_DIR="/usr/local/bin"
else
  BIN_DIR="$HOME/.local/bin"
  mkdir -p "$BIN_DIR"
fi

ln -sf "$APP_DIR/uBit.app/Contents/MacOS/ubit" "$BIN_DIR/ubit"
echo "✓ Installed $APP_DIR/uBit.app"
echo "✓ Linked CLI at $BIN_DIR/ubit"
echo "  Run 'ubit --llms' for agent docs or 'ubit' to open the app."
