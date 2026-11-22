#!/bin/sh
# Compiles tests/swift/RegressionChecks.swift with the app sources (without Sources/main.swift)
# and runs each case in its own process with its own UBIT_CONFIG_DIR. No case uses the network.
# Usage: tests/swift/run.sh [case ...]   (default: every case)
set -eu

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${TMPDIR:-/tmp}/ubit-swift-checks"
rm -rf "$OUT"
mkdir -p "$OUT"

echo "▸ Compiling Swift regression checks…"
swiftc \
  -Onone \
  -target arm64-apple-macos14.0 \
  -whole-module-optimization \
  -module-cache-path "$OUT/module-cache" \
  -framework AppKit \
  -framework SwiftUI \
  -framework WebKit \
  -framework JavaScriptCore \
  -framework AVFoundation \
  -framework AudioToolbox \
  -framework QuickLookUI \
  -framework IOKit \
  -framework ImageIO \
  -framework UniformTypeIdentifiers \
  -lsqlite3 \
  "$ROOT"/Sources/Core/*.swift \
  "$ROOT"/Sources/Mux/*.swift \
  "$ROOT"/Sources/Engine/*.swift \
  "$ROOT"/Sources/Extractors/*.swift \
  "$ROOT"/Sources/CLI/*.swift \
  "$ROOT"/Sources/UI/*.swift \
  "$ROOT"/tests/swift/RegressionChecks.swift \
  -o "$OUT/checks"

# visitor-first and visitor-reuse share one config directory: the second process must reuse
# the visitor ID that the first one stored. Naming visitor-reuse alone runs visitor-first first.
CASES="${*:-optional-refusal metadata-refusal embed-disabled imgur-405 imgur-reset watch-gate notice-bot notice-bot-text notice-entity notice-entity-number notice-age notice-traffic notice-summary notice-widget plain-inert plain-no-state plain-hidden plain-closed-details plain-secondary-summary plain-unlisted plain-lessons ok-reason redirect-google redirect-ordinary player-gate watch-status player-status probe-status download-status download-stream-status playability-status watch-challenge-cookie player-challenge-cookie visitor-first visitor-reuse pace-concurrent pace-retry player-body-lost player-timeout retry-5xx retry-429 refusal-body-reset refusal-body-stall range-refusal refusal-headers-only lost-after-headers transport-unreached transport-timeout lost-before-response cancel-slots cancel-middle pace-late-wake wall-unusable-cookie auth-header cache cache-context cache-scope cache-cancelled normal watch-flags cancel-download dash-refusal cancel-watch cancel-player cancel-probe hls-fallback hls-fallback-nowatch hls-fallback-watchlist hls-fallback-lateprofile cli-flags sigint-info sigint-formats sigint-get proxy-values proxy-stored safari-values safari-expiry-sentinels safari-infinite-expiry chromium}"

failed=""
for case in $CASES; do
  config="$OUT/config-$case"
  case "$case" in visitor-*) config="$OUT/config-visitor" ;; esac
  if [ "$case" = visitor-reuse ] && [ ! -f "$config/yt_visitor.txt" ]; then
    UBIT_CONFIG_DIR="$config" "$OUT/checks" visitor-first >/dev/null || true
  fi
  if ! UBIT_CONFIG_DIR="$config" "$OUT/checks" "$case"; then
    echo "FAIL $case (exit or signal)"
    failed="$failed $case"
  fi
done

if [ -n "$failed" ]; then
  echo "✗ Failed:$failed"
  exit 1
fi
echo "✓ All Swift regression checks passed"
