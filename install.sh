#!/bin/sh
# Installs uBit on macOS (arm64), Linux (x86_64 & arm64), and Android / Termux (arm64) without requiring root.
#
#   curl -fsSL https://github.com/ayooooo123/ubit/releases/latest/download/install.sh | sh
set -eu

REPO="ayooooo123/ubit"
if [ -n "${UBIT_VERSION:-}" ]; then
  VERSION="${UBIT_VERSION#v}"
else
  RESOLVED_URL="$(curl -fsSLI -o /dev/null -w '%{url_effective}' "https://github.com/$REPO/releases/latest" 2>/dev/null || true)"
  RESOLVED_TAG="${RESOLVED_URL##*/}"
  VERSION="${RESOLVED_TAG#v}"
  [ -n "$VERSION" ] && [ "$VERSION" != "latest" ] || VERSION="0.3.3"
fi
BASE_URL="${UBIT_DOWNLOAD_URL:-https://github.com/$REPO/releases/download/v${VERSION}}"
OS="$(uname -s)"
ARCH_RAW="$(uname -m)"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/ubit-install.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

verify_sha256() {
  FILE_NAME="$1"
  if curl -fsSL "${BASE_URL}/SHA256SUMS" -o "$WORK/SHA256SUMS" 2>/dev/null; then
    EXPECTED="$(awk -v f="$FILE_NAME" '$2 == f { print $1 }' "$WORK/SHA256SUMS")"
    if [ -n "$EXPECTED" ]; then
      if command -v sha256sum >/dev/null 2>&1; then
        ACTUAL="$(sha256sum "$WORK/$FILE_NAME" | awk '{ print $1 }')"
      else
        ACTUAL="$(shasum -a 256 "$WORK/$FILE_NAME" | awk '{ print $1 }')"
      fi
      [ "$EXPECTED" = "$ACTUAL" ] || { echo "install.sh: SHA-256 mismatch for $FILE_NAME" >&2; exit 1; }
    fi
  fi
}

# 1. Android / Termux (Bionic arm64)
if [ -n "${TERMUX_VERSION:-}" ] || [ "$(uname -o 2>/dev/null || true)" = "Android" ] || [ -d "/data/data/com.termux/files/usr" ] || { [ -e "/system/bin/linker64" ] && [ ! -e "/lib/ld-linux-aarch64.so.1" ]; }; then
  case "$ARCH_RAW" in
    aarch64|arm64) ;;
    *) echo "install.sh: prebuilt Termux/Android release targets arm64 ($ARCH_RAW detected)" >&2; exit 1 ;;
  esac

  PREFIX_DIR="${PREFIX:-/data/data/com.termux/files/usr}"
  if command -v pkg >/dev/null 2>&1 && [ ! -e "$PREFIX_DIR/lib/libssl.so.3" ] && [ ! -e "$PREFIX_DIR/lib/libssl.so" ]; then
    echo "▸ Installing OpenSSL runtime in Termux…"
    pkg install -y openssl
  fi

  ARCHIVE="ubit-${VERSION}-android-arm64.tar.gz"
  echo "▸ Downloading uBit ${VERSION} (Termux / Android arm64)…"
  curl -fsSL "${BASE_URL}/${ARCHIVE}" -o "$WORK/$ARCHIVE"
  verify_sha256 "$ARCHIVE"

  tar -xzf "$WORK/$ARCHIVE" -C "$WORK"
  if [ -d "$PREFIX_DIR" ] && { [ -w "$PREFIX_DIR/bin" ] || mkdir -p "$PREFIX_DIR/bin" 2>/dev/null; }; then
    install -m 0755 "$WORK/ubit" "$PREFIX_DIR/bin/ubit"
    echo "✓ Installed $PREFIX_DIR/bin/ubit"
    # Remove or replace any stale glibc binary in ~/.local/bin/ubit that would shadow $PREFIX/bin/ubit on PATH
    if [ -e "$HOME/.local/bin/ubit" ] || [ -L "$HOME/.local/bin/ubit" ]; then
      ln -sf "$PREFIX_DIR/bin/ubit" "$HOME/.local/bin/ubit"
      echo "✓ Updated $HOME/.local/bin/ubit -> $PREFIX_DIR/bin/ubit"
    fi
  else
    mkdir -p "$HOME/.local/bin"
    install -m 0755 "$WORK/ubit" "$HOME/.local/bin/ubit"
    echo "✓ Installed $HOME/.local/bin/ubit"
  fi
  echo "  Tip: run 'hash -r' in your current shell if needed, and 'termux-setup-storage' to save into ~/storage/downloads."
  exit 0
fi

# 2. macOS (arm64)
if [ "$OS" = "Darwin" ]; then
  if [ "$ARCH_RAW" = "x86_64" ] && [ "$(sysctl -n sysctl.proc_translated 2>/dev/null || echo 0)" = "1" ]; then
    ARCH_RAW="arm64"
  fi
  [ "$ARCH_RAW" = "arm64" ] || { echo "install.sh: prebuilt macOS release targets arm64; run ./build.sh from source" >&2; exit 1; }
  ARCHIVE="ubit-${VERSION}-darwin-arm64.tar.gz"
  echo "▸ Downloading uBit ${VERSION} (macOS arm64)…"
  curl -fsSL "${BASE_URL}/${ARCHIVE}" -o "$WORK/$ARCHIVE"
  verify_sha256 "$ARCHIVE"

  if [ -w "/Applications" ]; then
    APP_DIR="/Applications"
  else
    APP_DIR="$HOME/Applications"
    mkdir -p "$APP_DIR"
  fi
  rm -rf "$APP_DIR/uBit.app"
  tar -xzf "$WORK/$ARCHIVE" -C "$APP_DIR"
  xattr -dr com.apple.quarantine "$APP_DIR/uBit.app" 2>/dev/null || true

  if [ -w "/usr/local/bin" ]; then BIN_DIR="/usr/local/bin"
  else BIN_DIR="$HOME/.local/bin"; mkdir -p "$BIN_DIR"; fi

  ln -sf "$APP_DIR/uBit.app/Contents/MacOS/ubit" "$BIN_DIR/ubit"
  echo "✓ Installed $APP_DIR/uBit.app"
  echo "✓ Linked CLI at $BIN_DIR/ubit"
  exit 0
fi

# 3. Standard Linux (x86_64 & arm64 glibc)
if [ "$OS" = "Linux" ]; then
  case "$ARCH_RAW" in
    x86_64|amd64) TARGET_ARCH="amd64" ;;
    aarch64|arm64) TARGET_ARCH="arm64" ;;
    *) echo "install.sh: unsupported Linux architecture $ARCH_RAW" >&2; exit 1 ;;
  esac

  ARCHIVE="ubit-${VERSION}-linux-${TARGET_ARCH}.tar.gz"
  echo "▸ Downloading uBit ${VERSION} (Linux ${TARGET_ARCH})…"
  curl -fsSL "${BASE_URL}/${ARCHIVE}" -o "$WORK/$ARCHIVE"
  verify_sha256 "$ARCHIVE"

  tar -xzf "$WORK/$ARCHIVE" -C "$WORK"

  if [ "$(id -u)" != "0" ]; then
    BIN_DIR="$HOME/.local/bin"
    DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
    mkdir -p "$BIN_DIR" "$DATA_HOME/applications"
    install -m 0755 "$WORK/ubit" "$BIN_DIR/ubit"
    if [ -f "$WORK/ubit.desktop" ]; then
      sed "s|^Exec=ubit|Exec=\"$BIN_DIR/ubit\"|" "$WORK/ubit.desktop" > "$DATA_HOME/applications/ubit.desktop"
    fi
    echo "✓ Installed $BIN_DIR/ubit"
  else
    install -m 0755 "$WORK/ubit" /usr/local/bin/ubit
    echo "✓ Installed /usr/local/bin/ubit"
  fi
  echo "  Run 'ubit --llms' for agent docs or 'ubit' to open the desktop UI."
  exit 0
fi

echo "install.sh: unsupported OS $OS" >&2
exit 1
