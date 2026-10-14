#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --product GoblinApp
binary_directory=$(swift build --show-bin-path)
objects="$binary_directory/history-layout-objects.txt"
python3 - "$binary_directory" "$objects" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
objects = (root / 'GoblinApp.product/Objects.LinkFileList').read_text().splitlines()
Path(sys.argv[2]).write_text('\n'.join('"' + p + '"' for p in objects if '/GoblinApp.build/' not in p) + '\n')
PY
sources=()
while IFS= read -r source; do sources+=("$source"); done < <(find Sources/GoblinApp -name '*.swift' | sort | sed '/\/GoblinApp.swift$/d')
swiftc -parse-as-library -swift-version 6 -target arm64-apple-macosx26.0 \
    -I "$binary_directory/Modules" -I Sources/CSQLite \
    -I .build/checkouts/FluidAudio/Sources/MachTaskSelfWrapper/include \
    -I .build/checkouts/FluidAudio/Sources/FastClusterWrapper/include \
    "${sources[@]}" scripts/checks/history-layout.swift "@$objects" -lc++ -lsqlite3 \
    -o "$binary_directory/HistoryLayoutChecks"
codesign --force --timestamp=none --sign "${GOBLIN_SIGNING_IDENTITY:-gob.lin Local Development}" "$binary_directory/HistoryLayoutChecks"
"$binary_directory/HistoryLayoutChecks" "${1:-docs/screenshots/history}"
