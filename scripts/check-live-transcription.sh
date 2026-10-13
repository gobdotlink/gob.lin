#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
check_directory=$(mktemp -d)
trap 'rm -rf "$check_directory"' EXIT
swiftc -parse-as-library -I .build/debug/Modules -I Sources/CSQLite Sources/GoblinEngines/SpeechEngine.swift Sources/GoblinEngines/LiveTranscriber.swift scripts/checks/live-transcription.swift -o "$check_directory/check"
"$check_directory/check"
