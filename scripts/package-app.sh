#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [ "$#" -gt 1 ]; then printf 'Usage: scripts/package-app.sh [output-directory]\n' >&2; exit 2; fi
destination="${1:-dist}"
scripts/build.sh release
app=.build/app/gob.lin.app
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)
mkdir -p "$destination"
archive="$destination/gob.lin-$version.zip"
# Notarize and staple Developer ID builds so a download opens without Open Anyway, even offline.
# A rejected submission leaves no ticket, so stapling fails; `xcrun notarytool log <id>` says why.
signature=$(codesign -dvv "$app" 2>&1)
if [[ "$signature" == *$'\nAuthority=Developer ID Application: '* ]]; then
    ditto -c -k --keepParent --norsrc "$app" "$archive"
    xcrun notarytool submit "$archive" --keychain-profile "${GOBLIN_NOTARY_PROFILE:-goblin-notary}" --wait
    xcrun stapler staple "$app"
    spctl --assess --type execute --verbose "$app"
fi
# Archive the stapled bundle: the updater and Gatekeeper both check this exact app.
ditto -c -k --keepParent --norsrc "$app" "$archive"
shasum -a 256 "$archive" > "$archive.sha256"
printf 'Packaged %s\n' "$archive"
