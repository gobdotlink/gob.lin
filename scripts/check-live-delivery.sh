#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --product GoblinApp
check_directory=$(mktemp -d)
trap 'rm -rf "$check_directory"' EXIT
python3 - "$check_directory/objects" <<'PY'
from pathlib import Path
import sys
objects = Path('.build/debug/GoblinApp.product/Objects.LinkFileList').read_text().splitlines()
Path(sys.argv[1]).write_text('\n'.join('"' + p + '"' for p in objects if not p.endswith('/GoblinApp.build/GoblinApp.swift.o')) + '\n')
PY
swiftc -parse-as-library -swift-version 6 -I .build/debug/Modules -I Sources/CSQLite \
    -I .build/checkouts/FluidAudio/Sources/MachTaskSelfWrapper/include \
    -I .build/checkouts/FluidAudio/Sources/FastClusterWrapper/include \
    scripts/checks/live-delivery.swift "@$check_directory/objects" -lc++ -lsqlite3 -o "$check_directory/check"
"$check_directory/check"
