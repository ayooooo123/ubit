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
CASES="${*:-optional-refusal metadata-refusal watch-gate watch-wall-text watch-wall-metadata watch-human-notice watch-age-notice watch-inline-age watch-blocked-text watch-blocked-notice watch-header-age watch-inert-text watch-lesson-no-state watch-hidden-notice player-gate watch-status player-status probe-status download-status download-stream-status playability-status watch-challenge-cookie player-challenge-cookie visitor-first visitor-reuse pace-concurrent pace-retry retry-5xx retry-429 cancel-slots cancel-middle pace-late-wake wall-unusable-cookie auth-header cache cache-context cache-scope cache-prune cache-cancelled normal watch-flags cancel-download hls-section-base hls-section-clip hls-section-outside hls-decimal hls-ntsc trim-boundaries trim-keyframe trim-display-end sidx-boundaries sidx-padding sidx-fragments sidx-cut hls-short-range hls-changed-edition hls-untagged-edition hls-redirect-vod hls-live-stable hls-live-changed hls-live-whole hls-live-whole-changed hls-redirect-live hls-event-whole hls-event-ranged parallel-unvalidated parallel-intact parallel-short parallel-cancel parallel-redirect dash-refusal range-ignored hls-raw-section http-raw-section cancel-watch cancel-player cancel-probe hls-fallback hls-fallback-nowatch hls-fallback-watchlist hls-fallback-lateprofile cli-flags proxy-values proxy-stored safari-values safari-expiry-sentinels safari-infinite-expiry chromium}"

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
