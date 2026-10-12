#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
swift build
swift run HistorySmoke
binary_directory=$(swift build --show-bin-path)
"$binary_directory/goblin" --self-check
"$binary_directory/goblin" --version
"$binary_directory/goblin" --help >/dev/null
if "$binary_directory/goblin" --unknown >/dev/null 2>&1; then
    printf 'CLI incorrectly accepted an unknown option.\n' >&2
    exit 1
fi
plutil -lint Resources/Info.plist Resources/Goblin.entitlements
