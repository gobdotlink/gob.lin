#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
check_directory=$(mktemp -d)
trap 'rm -rf "$check_directory"' EXIT
swiftc -parse-as-library -swift-version 6 \
    Sources/GoblinApp/Permissions/PermissionModel.swift \
    Sources/GoblinApp/Permissions/OnboardingView.swift \
    Sources/GoblinApp/Hotkeys/EventTap.swift \
    Sources/GoblinApp/Hotkeys/HotkeyShortcut.swift \
    scripts/checks/permissions.swift -o "$check_directory/check"
"$check_directory/check"
