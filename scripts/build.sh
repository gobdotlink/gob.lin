#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
configuration="${1:-release}"
case "$configuration" in debug|release) ;; *) printf 'Usage: scripts/build.sh [debug|release]\n' >&2; exit 2 ;; esac

identity="${GOBLIN_SIGNING_IDENTITY:-gob.lin Local Development}"
if [ "$identity" = '-' ]; then
    printf 'Ad-hoc signing is unsupported: it can reset microphone and accessibility grants.\n' >&2
    exit 1
fi
if [ "$identity" = 'gob.lin Local Development' ]; then
    scripts/setup-signing.sh
fi
if ! security find-identity -v -p codesigning | grep -Fq "\"$identity\""; then
    printf 'No valid signing identity named "%s". Set GOBLIN_SIGNING_IDENTITY to an existing certificate name.\n' "$identity" >&2
    exit 1
fi

swift build -c "$configuration"
binary_directory=$(swift build -c "$configuration" --show-bin-path)
app='.build/app/gob.lin.app'
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary_directory/GoblinApp" "$app/Contents/MacOS/GoblinApp"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp -R Sources/GoblinApp/Assets "$app/Contents/Resources/"
cp Resources/Goblin.icns "$app/Contents/Resources/"

# Pin to the certificate public identity, not the changing executable hash.
certificate=$(security find-certificate -c "$identity" -p | /usr/bin/openssl x509 -outform DER | shasum -a 1 | awk '{print $1}')
requirement="designated => identifier \"app.goblin.dictation\" and certificate leaf = H\"$certificate\""
codesign --force --options runtime --timestamp=none \
    --entitlements Resources/Goblin.entitlements --sign "$identity" \
    --requirements "=$requirement" "$app"
codesign --verify --strict --verbose=2 "$app"
printf '\nBuilt %s\nRun: open "%s"\n' "$app" "$app"
