#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
check_directory=$(mktemp -d)
trap 'rm -rf "$check_directory"' EXIT
cp scripts/checks/native-pasteboard.swift "$check_directory/main.swift"
swiftc -swift-version 6 Sources/GoblinCore/InsertionPolicy.swift \
    Sources/GoblinApp/Insertion/PasteboardTransaction.swift Sources/GoblinApp/Insertion/KeyboardLayout.swift \
    "$check_directory/main.swift" -o "$check_directory/check"
"$check_directory/check"
