#!/bin/sh
# Builds dist/ubit.wasm: the Linux C++ CLI for wasm32-wasip1 (wasi-sdk). The host supplies TCP/TLS through the
# `ubit_net` imports (linux/src/wasi.hpp), the linear memory (imported, so the host sets its ceiling), and WASI
# preview 1 for files, clocks and random. No ffmpeg, threads, signals or desktop window in this build.
#   WASI_SDK_PATH=/path/to/wasi-sdk sh linux/build_wasm.sh
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WASI_SDK_PATH="${WASI_SDK_PATH:-/opt/wasi-sdk}"
CXX="$WASI_SDK_PATH/bin/clang++"
DIST="$ROOT/dist"
[ -x "$CXX" ] || { echo "wasi-sdk not found at $WASI_SDK_PATH (set WASI_SDK_PATH)" >&2; exit 1; }
mkdir -p "$DIST"

# The in-module SHA-1/SHA-256/AES-128-CBC replace OpenSSL here, so check them natively first.
if command -v c++ >/dev/null 2>&1; then
  c++ -std=c++20 -O2 "$ROOT/linux/tests/softcrypto_test.cpp" -o "$DIST/softcrypto_test"
  "$DIST/softcrypto_test"
  rm -f "$DIST/softcrypto_test"
fi

echo "▸ Compiling uBit for wasm32-wasip1…"
# Stack first, so an overflow traps instead of writing over static data; 8 MiB for deep JSON.
"$CXX" \
  --target=wasm32-wasip1 \
  -std=c++20 \
  -O2 \
  -g0 \
  -fwasm-exceptions \
  -mllvm -wasm-use-legacy-eh=false \
  -ffunction-sections \
  -fdata-sections \
  -Wl,--gc-sections \
  -Wl,--strip-all \
  -Wl,--stack-first \
  -Wl,-z,stack-size=8388608 \
  -Wl,--import-memory \
  -Wl,--initial-memory=16777216 \
  -Wl,--max-memory=4294967296 \
  "$ROOT/linux/src/main.cpp" \
  -lunwind \
  -o "$DIST/ubit.wasm"

ls -lh "$DIST/ubit.wasm" && wc -c "$DIST/ubit.wasm"
