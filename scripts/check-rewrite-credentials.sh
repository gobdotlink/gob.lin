#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --target GoblinCore >/dev/null
binary_directory=$(swift build --show-bin-path)
temporary=$(mktemp -d)
trap 'rm -rf "$temporary"' EXIT
swiftc -parse-as-library -swift-version 6 \
    -I "$binary_directory/Modules" -I Sources/CSQLite \
    Sources/GoblinApp/RewriteKeychain.swift scripts/checks/rewrite-credentials.swift \
    "$binary_directory"/GoblinCore.build/*.swift.o -o "$temporary/check"
"$temporary/check"
