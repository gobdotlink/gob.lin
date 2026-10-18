#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --product GoblinApp
binary_directory=$(swift build --show-bin-path)
objects="$binary_directory/model-check-objects.txt"
python3 - "$binary_directory" "$objects" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
objects = (root / 'GoblinApp.product/Objects.LinkFileList').read_text().splitlines()
Path(sys.argv[2]).write_text('\n'.join('"' + p + '"' for p in objects if not p.endswith('/GoblinApp.build/GoblinApp.swift.o')) + '\n')
PY
swiftc -parse-as-library -swift-version 6 -target arm64-apple-macosx26.0 \
    -I "$binary_directory/Modules" -I Sources/CSQLite \
    -I .build/checkouts/FluidAudio/Sources/MachTaskSelfWrapper/include \
    -I .build/checkouts/FluidAudio/Sources/FastClusterWrapper/include \
    scripts/checks/models.swift "@$objects" -lc++ -lsqlite3 -o "$binary_directory/ModelChecks"
"$binary_directory/ModelChecks" "$@"
