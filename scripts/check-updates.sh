#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --target GoblinCore >/dev/null
binary_directory=$(swift build --show-bin-path)
temporary=$(mktemp -d)
trap 'rm -rf "$temporary"' EXIT
swiftc -parse-as-library -swift-version 6 \
    -I "$binary_directory/Modules" -I Sources/CSQLite \
    Sources/GoblinApp/Updates/*.swift scripts/checks/updates.swift \
    "$binary_directory"/GoblinCore.build/*.swift.o -o "$temporary/check"
"$temporary/check" "$@"
python3 scripts/checks/update-helper.py
python3 scripts/checks/release.py
bash -n scripts/build.sh scripts/package-app.sh scripts/release.sh
sh -n Sources/GoblinApp/Assets/install-update.sh
printf 'Updater checks passed (temporary fixtures only; no app installed or launched).\n'
