#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
check_directory=$(mktemp -d)
trap 'rm -rf "$check_directory"' EXIT
swiftc -parse-as-library Sources/GoblinApp/DictationSession.swift scripts/checks/dictation-session.swift -o "$check_directory/check"
"$check_directory/check"
