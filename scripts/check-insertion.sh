#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
check_directory=$(mktemp -d)
trap 'rm -rf "$check_directory"' EXIT
cp scripts/checks/insertion.swift "$check_directory/main.swift"
swiftc Sources/GoblinCore/InsertionPolicy.swift "$check_directory/main.swift" -o "$check_directory/check"
"$check_directory/check"
