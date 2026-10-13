#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [ "$#" -eq 0 ]; then
    printf 'Usage: scripts/check-icons.sh /path/to/gob.lin.app [...]\n' >&2
    exit 2
fi
for app in "$@"; do codesign --verify --strict "$app"; done
mkdir -p .build
temporary=$(mktemp -d "$PWD/.build/icon-check.XXXXXX")
trap 'rm -rf "$temporary"' EXIT
probe="$temporary/IconCheck.app"
mkdir "$probe"
cp -R Sources/GoblinApp/Assets "$probe/Assets"
swiftc -parse-as-library -swift-version 6 -D SWIFT_PACKAGE \
    Sources/GoblinApp/GoblinBrand.swift scripts/checks/icons.swift -o "$probe/check-icons"
"$probe/check-icons" "$@"
