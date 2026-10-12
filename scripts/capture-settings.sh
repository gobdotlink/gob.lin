#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build
binary_directory=$(swift build --show-bin-path)
preview='.build/settings-capture/gob.lin Settings Capture.app'
mkdir -p "$preview/Contents/MacOS" "$preview/Contents/Resources"
sources=()
while IFS= read -r source; do sources+=("$source"); done < <(rg --files Sources/GoblinApp -g '*.swift' | sort | sed '/\/GoblinApp.swift$/d')
swiftc -parse-as-library -swift-version 6 -target arm64-apple-macosx26.0 \
    -I "$binary_directory/Modules" -I Sources/CSQLite \
    "${sources[@]}" scripts/capture-settings.swift \
    "$binary_directory"/GoblinCore.build/*.swift.o "$binary_directory"/GoblinEngines.build/*.swift.o \
    -o "$preview/Contents/MacOS/SettingsCapture"
cp -R Sources/GoblinApp/Assets "$preview/Contents/Resources/"
cat > "$preview/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>app.goblin.settings-capture</string>
<key>CFBundleName</key><string>gob.lin Settings Capture</string>
<key>CFBundleExecutable</key><string>SettingsCapture</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
"$preview/Contents/MacOS/SettingsCapture" "${1:-docs/screenshots}"
