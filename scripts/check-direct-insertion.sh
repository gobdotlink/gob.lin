#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
check_directory=$(mktemp -d)
trap 'rm -rf "$check_directory"' EXIT
swiftc -parse-as-library -swift-version 6 Sources/GoblinApp/Insertion/DirectInsertionVerification.swift \
    scripts/checks/direct-insertion.swift -o "$check_directory/check"
"$check_directory/check"
