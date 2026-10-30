#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --target GoblinCore
binary_directory=$(swift build --show-bin-path)
mkdir -p .build/development-log-check
sources=(
    Sources/GoblinApp/Diagnostics/DiagnosticsModel.swift
    Sources/GoblinApp/Permissions/PermissionModel.swift
    Sources/GoblinApp/Hotkeys/EventTap.swift
    Sources/GoblinApp/Hotkeys/HotkeyShortcut.swift
    Sources/GoblinApp/GoblinBrand.swift
)
swiftc -parse-as-library -swift-version 6 -target "$(uname -m)-apple-macosx26.0" \
    -I "$binary_directory/Modules" -I Sources/CSQLite \
    "${sources[@]}" scripts/checks/development-logs.swift \
    "$binary_directory"/GoblinCore.build/*.swift.o \
    -o .build/development-log-check/check
.build/development-log-check/check
