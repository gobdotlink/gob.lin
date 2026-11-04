#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --product GoblinCore >/dev/null 2>&1 || swift build >/dev/null
binary_directory=$(swift build --show-bin-path)
mkdir -p .build
temporary=$(mktemp -d "$PWD/.build/mascot-check.XXXXXX")
trap 'rm -rf "$temporary"' EXIT
cp -R Sources/GoblinApp/Assets "$temporary/Assets"
swiftc -parse-as-library -swift-version 6 -target arm64-apple-macosx26.0 \
    -I "$binary_directory/Modules" -I Sources/CSQLite \
    Sources/GoblinApp/GoblinBrand.swift \
    Sources/GoblinApp/Hotkeys/HotkeyShortcut.swift \
    Sources/GoblinApp/Overlay/OverlayController.swift \
    Sources/GoblinApp/Overlay/DictationOverlay.swift \
    scripts/checks/mascot.swift "$binary_directory"/GoblinCore.build/*.swift.o -lsqlite3 \
    -o "$temporary/check-mascot"
"$temporary/check-mascot" "$@"
