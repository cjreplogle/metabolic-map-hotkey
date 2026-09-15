#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

echo "Building MetabolicMap.app..."

rm -rf MetabolicMap.app AppIcon.iconset
mkdir -p MetabolicMap.app/Contents/MacOS MetabolicMap.app/Contents/Resources AppIcon.iconset

# Build a native macOS .icns if AppIcon.png is present
if [ -f "Resources/AppIcon.png" ]; then
    sips -z 16 16 Resources/AppIcon.png --out AppIcon.iconset/icon_16x16.png >/dev/null
    sips -z 32 32 Resources/AppIcon.png --out AppIcon.iconset/icon_16x16@2x.png >/dev/null
    sips -z 32 32 Resources/AppIcon.png --out AppIcon.iconset/icon_32x32.png >/dev/null
    sips -z 64 64 Resources/AppIcon.png --out AppIcon.iconset/icon_32x32@2x.png >/dev/null
    sips -z 128 128 Resources/AppIcon.png --out AppIcon.iconset/icon_128x128.png >/dev/null
    sips -z 256 256 Resources/AppIcon.png --out AppIcon.iconset/icon_128x128@2x.png >/dev/null
    sips -z 256 256 Resources/AppIcon.png --out AppIcon.iconset/icon_256x256.png >/dev/null
    sips -z 512 512 Resources/AppIcon.png --out AppIcon.iconset/icon_256x256@2x.png >/dev/null
    sips -z 512 512 Resources/AppIcon.png --out AppIcon.iconset/icon_512x512.png >/dev/null
    sips -z 1024 1024 Resources/AppIcon.png --out AppIcon.iconset/icon_512x512@2x.png >/dev/null
    iconutil -c icns AppIcon.iconset -o MetabolicMap.app/Contents/Resources/AppIcon.icns
    rm -rf AppIcon.iconset
    cp Resources/AppIcon.png MetabolicMap.app/Contents/Resources/AppIcon.png
fi

# Bundle the menu-bar (status item) metabolite icons.
for svg in Resources/*.svg; do
    [ -f "$svg" ] && cp "$svg" MetabolicMap.app/Contents/Resources/
done

# Compile Swift code with -parse-as-library so @main is synthesized properly
swiftc -parse-as-library MetabolicMapApp.swift \
  -o MetabolicMap.app/Contents/MacOS/MetabolicMap \
  -framework Cocoa -framework SwiftUI -framework PDFKit

cat > MetabolicMap.app/Contents/Info.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>MetabolicMap</string>
    <key>CFBundleIdentifier</key>
    <string>local.metabolicmap.app</string>
    <key>CFBundleName</key>
    <string>Metabolic Map</string>
    <key>CFBundleDisplayName</key>
    <string>Metabolic Map</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon.icns</string>
    <key>CFBundleShortVersionString</key>
    <string>2.2</string>
    <key>CFBundleVersion</key>
    <string>10</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
PLIST

# Sign with a stable identity so macOS TCC (Accessibility) trust persists across
# rebuilds instead of resetting every time (ad-hoc signing changes the cdhash).
SIGN_IDENTITY="Apple Development: creplogle20@gmail.com (2YM423YA3K)"
if security find-identity -v -p codesigning | grep -q "$SIGN_IDENTITY"; then
    codesign --force --deep --sign "$SIGN_IDENTITY" MetabolicMap.app
    echo "Signed with stable identity."
else
    echo "Warning: signing identity not found; using ad-hoc (Accessibility grant will reset each build)."
fi

echo "Build successful! Relaunching MetabolicMap.app..."
# Quit any running instance first — `open` alone only re-activates a running
# LSUIElement app and would keep the OLD binary running.
pkill -f "MetabolicMap.app/Contents/MacOS/MetabolicMap" 2>/dev/null
sleep 0.5
# Keep the /Applications copy (Spotlight-searchable) in sync and launch that one.
rm -rf /Applications/MetabolicMap.app
ditto MetabolicMap.app /Applications/MetabolicMap.app
open /Applications/MetabolicMap.app
