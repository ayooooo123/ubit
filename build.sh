#!/bin/sh
set -eu

ROOT="$(cd "$(dirname "$0")" && pwd)"
DIST="$ROOT/dist"
APP="$DIST/uBit.app"
MACOS="$APP/Contents/MacOS"
RES="$APP/Contents/Resources"

rm -rf "$DIST"
mkdir -p "$MACOS" "$RES"

echo "▸ Compiling uBit (arm64, -Osize, whole-module-optimization, dead_strip)…"
swiftc \
  -Osize \
  -whole-module-optimization \
  -gnone \
  -target arm64-apple-macos14.0 \
  -Xlinker -dead_strip \
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
  "$ROOT"/Sources/main.swift \
  -o "$MACOS/ubit"

strip -u -r "$MACOS/ubit"

# Generate compact vector-rendered AppIcon.icns (<20 KB vs Downbit's 947 KB!)
ICONSET="$DIST/AppIcon.iconset"
mkdir -p "$ICONSET"
python3 - "$ICONSET" <<'PY'
import sys, subprocess
from pathlib import Path

# Use tiny inline Swift CoreGraphics script to render crisp macOS squircle icon
iconset = Path(sys.argv[1])
swift_icon = iconset.parent / "gen_icon.swift"
swift_icon.write_text("""
import AppKit
let outDir = URL(fileURLWithPath: CommandLine.arguments[1])
for sz in [16, 32, 128, 256] {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: sz, pixelsHigh: sz, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let rect = NSRect(x: CGFloat(sz)*0.08, y: CGFloat(sz)*0.08, width: CGFloat(sz)*0.84, height: CGFloat(sz)*0.84)
    let path = NSBezierPath(roundedRect: rect, xRadius: CGFloat(sz)*0.22, yRadius: CGFloat(sz)*0.22)
    let grad = NSGradient(starting: NSColor(calibratedRed: 0.07, green: 0.48, blue: 0.98, alpha: 1.0), ending: NSColor(calibratedRed: 0.04, green: 0.16, blue: 0.42, alpha: 1.0))!
    grad.draw(in: path, angle: -65)
    // Crisp white downward arrow + bar
    NSColor.white.setFill()
    let cx = CGFloat(sz) * 0.5
    let shaftW = max(2.0, CGFloat(sz) * 0.11)
    NSBezierPath(roundedRect: NSRect(x: cx - shaftW/2, y: CGFloat(sz)*0.40, width: shaftW, height: CGFloat(sz)*0.32), xRadius: shaftW*0.3, yRadius: shaftW*0.3).fill()
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: cx - CGFloat(sz)*0.20, y: CGFloat(sz)*0.46))
    arrow.line(to: NSPoint(x: cx + CGFloat(sz)*0.20, y: CGFloat(sz)*0.46))
    arrow.line(to: NSPoint(x: cx, y: CGFloat(sz)*0.26))
    arrow.close()
    arrow.fill()
    NSBezierPath(roundedRect: NSRect(x: cx - CGFloat(sz)*0.20, y: CGFloat(sz)*0.19, width: CGFloat(sz)*0.40, height: max(1.5, CGFloat(sz)*0.06)), xRadius: 2, yRadius: 2).fill()
    NSGraphicsContext.restoreGraphicsState()
    let png = rep.representation(using: .png, properties: [:])!
    try! png.write(to: outDir.appendingPathComponent("icon_\\(sz)x\\(sz).png"))
    if sz <= 128 {
        try! png.write(to: outDir.appendingPathComponent("icon_\\(sz/2 == 0 ? 16 : sz)x\\(sz/2 == 0 ? 16 : sz)@2x.png"))
    }
}
""")
subprocess.run(["swift", str(swift_icon), str(iconset)], check=True)
swift_icon.unlink()
PY
iconutil -c icns "$ICONSET" -o "$RES/AppIcon.icns"
rm -rf "$ICONSET"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleDisplayName</key>
	<string>uBit</string>
	<key>CFBundleExecutable</key>
	<string>ubit</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon.icns</string>
	<key>CFBundleIdentifier</key>
	<string>app.ubit.mac</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>uBit</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>0.3.3</string>
	<key>CFBundleVersion</key>
	<string>0.3.3</string>
	<key>CFBundleURLTypes</key>
	<array>
		<dict>
			<key>CFBundleURLName</key>
			<string>app.ubit.mac</string>
			<key>CFBundleURLSchemes</key>
			<array>
				<string>ubit</string>
			</array>
		</dict>
	</array>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<key>NSAppleEventsUsageDescription</key>
	<string>uBit adds finished downloads to Music or TV when enabled in Settings.</string>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSPrincipalClass</key>
	<string>NSApplication</string>
</dict>
</plist>
PLIST

printf 'APPL????' > "$APP/Contents/PkgInfo"
codesign --force --deep --sign - "$APP"
ln -sf "$MACOS/ubit" "$DIST/ubit"
tar -czf "$DIST/ubit-0.3.3-darwin-arm64.tar.gz" -C "$DIST" uBit.app

echo "✓ Built $APP and $DIST/ubit-0.3.3-darwin-arm64.tar.gz"
ls -lh "$MACOS/ubit" "$RES/AppIcon.icns" "$DIST/ubit-0.3.3-darwin-arm64.tar.gz"
du -sh "$APP"
