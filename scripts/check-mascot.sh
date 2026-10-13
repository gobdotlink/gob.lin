#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
temporary=$(mktemp -d "$PWD/.build/mascot-check.XXXXXX")
trap 'rm -rf "$temporary"' EXIT
cp -R Sources/GoblinApp/Assets "$temporary/Assets"
swiftc -parse-as-library -swift-version 6 \
    Sources/GoblinApp/GoblinBrand.swift \
    Sources/GoblinApp/Overlay/OverlayController.swift \
    Sources/GoblinApp/Overlay/DictationOverlay.swift \
    scripts/checks/mascot.swift -o "$temporary/check-mascot"
"$temporary/check-mascot" "$@"
