#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --target GoblinCore >/dev/null
binary_directory=$(swift build --show-bin-path)
# Swift Build (the default from Swift 6.4) puts each module and one merged object straight into the
# products folder; the native build system keeps modules in Modules and an object per source file.
if [ -f "$binary_directory/GoblinCore.o" ]; then
    modules=$binary_directory; objects=("$binary_directory/GoblinCore.o")
else
    modules=$binary_directory/Modules; objects=("$binary_directory"/GoblinCore.build/*.swift.o)
fi
temporary=$(mktemp -d)
trap 'rm -rf "$temporary"' EXIT
swiftc -parse-as-library -swift-version 6 \
    -I "$modules" -I Sources/CSQLite \
    Sources/GoblinApp/Updates/*.swift scripts/checks/updates.swift \
    "${objects[@]}" -o "$temporary/check"
"$temporary/check" "$@"
swiftc -parse-as-library -swift-version 6 \
    -I "$modules" -I Sources/CSQLite \
    Sources/GoblinApp/Updates/*.swift scripts/checks/update-termination.swift \
    "${objects[@]}" -o "$temporary/termination-check"
python3 - "$temporary" <<'PY'
import pathlib, subprocess, sys
directory = pathlib.Path(sys.argv[1])
marker = directory / 'shutdown-completed'
# This native fixture has no windows, microphone, clipboard, history or user data.
# Timeout kills only this child fixture if the main actor becomes blocked.
subprocess.run([str(directory / 'termination-check'), str(marker)], check=True, timeout=10)
assert marker.read_text() == 'shutdown finished'
print('Native update termination completed async shutdown and exited.')
PY
python3 scripts/checks/update-helper.py
python3 scripts/checks/release.py
bash -n scripts/build.sh scripts/package-app.sh scripts/release.sh
sh -n Sources/GoblinApp/Assets/install-update.sh
printf 'Updater checks passed (temporary fixtures only; no app installed or launched).\n'
