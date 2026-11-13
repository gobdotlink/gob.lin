#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --build-system native --product GoblinApp
binary_directory=$(swift build --build-system native --show-bin-path)
preview='.build/settings-capture/gob.lin Settings Capture.app'
mkdir -p "$preview/Contents/MacOS" "$preview/Contents/Resources"
objects="$binary_directory/settings-capture-objects.txt"
python3 - "$binary_directory" "$objects" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
objects = (root / 'GoblinApp.product/Objects.LinkFileList').read_text().splitlines()
Path(sys.argv[2]).write_text('\n'.join('"' + p + '"' for p in objects if '/GoblinApp.build/' not in p) + '\n')
PY
sources=()
while IFS= read -r source; do sources+=("$source"); done < <(find Sources/GoblinApp -name '*.swift' | sort | sed '/\/GoblinApp.swift$/d')
swiftc -parse-as-library -swift-version 6 -target arm64-apple-macosx26.0 \
    -I "$binary_directory/Modules" -I Sources/CSQLite \
    -I .build/checkouts/FluidAudio/Sources/MachTaskSelfWrapper/include \
    -I .build/checkouts/FluidAudio/Sources/FastClusterWrapper/include \
    "${sources[@]}" scripts/capture-settings.swift "@$objects" -lc++ -lsqlite3 \
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
"$preview/Contents/MacOS/SettingsCapture" "${1:-docs/screenshots}" "${@:2}"
