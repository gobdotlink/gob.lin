#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
node scripts/checks/feedback-media.mjs
check_directory=$(mktemp -d)
trap 'rm -rf "$check_directory"' EXIT
swiftc -parse-as-library -swift-version 6 Sources/GoblinApp/OutputMute.swift scripts/checks/output-mute.swift -o "$check_directory/output-mute"
"$check_directory/output-mute"
