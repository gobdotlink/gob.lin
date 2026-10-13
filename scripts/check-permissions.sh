#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --target GoblinCore
binary_directory=$(swift build --show-bin-path)
check_directory=$(mktemp -d)
trap 'rm -rf "$check_directory"' EXIT
swiftc -parse-as-library -swift-version 6 \
    -I "$binary_directory/Modules" -I Sources/CSQLite \
    Sources/GoblinApp/Permissions/PermissionModel.swift \
    Sources/GoblinApp/Permissions/OnboardingView.swift \
    Sources/GoblinApp/Diagnostics/DiagnosticsModel.swift \
    scripts/checks/permissions.swift "$binary_directory"/GoblinCore.build/*.swift.o \
    -o "$check_directory/check"
"$check_directory/check"
