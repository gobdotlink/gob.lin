#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --product GoblinApp
binary_directory=$(swift build --show-bin-path)
mkdir -p .build/development-log-check
sources=()
while IFS= read -r source; do sources+=("$source"); done < <(find Sources/GoblinApp -name '*.swift' | sort | sed '/\/GoblinApp.swift$/d')
swiftc -parse-as-library -swift-version 6 -target "$(uname -m)-apple-macosx26.0" \
    -I "$binary_directory/Modules" -I Sources/CSQLite \
    "${sources[@]}" scripts/checks/development-logs.swift \
    "$binary_directory"/GoblinCore.build/*.swift.o "$binary_directory"/GoblinEngines.build/*.swift.o \
    -o .build/development-log-check/check
.build/development-log-check/check
