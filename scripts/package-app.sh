#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [ "$#" -gt 1 ]; then printf 'Usage: scripts/package-app.sh [output-directory]\n' >&2; exit 2; fi
destination="${1:-dist}"
scripts/build.sh release
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)
mkdir -p "$destination"
archive="$destination/gob.lin-$version.zip"
ditto -c -k --keepParent --norsrc .build/app/gob.lin.app "$archive"
shasum -a 256 "$archive" > "$archive.sha256"
printf 'Packaged %s\n' "$archive"
