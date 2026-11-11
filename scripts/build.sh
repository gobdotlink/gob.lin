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
identities=$(security find-identity -v -p codesigning)
certificate=$(printf '%s\n' "$identities" | goblin_requested_identity="$identity" awk '
    BEGIN { requested = ENVIRON["goblin_requested_identity"] }
    length($2) == 40 && $2 !~ /[^[:xdigit:]]/ {
        name = $0
        sub(/^[^"]*"/, "", name)
        sub(/"[^"]*$/, "", name)
        hash = toupper($2)
        if ((name == requested || hash == toupper(requested)) && !seen[hash]++) print hash
    }')
if [ -z "$certificate" ]; then
    printf 'No valid signing identity matches "%s". Set GOBLIN_SIGNING_IDENTITY to an exact certificate name or SHA-1 fingerprint.\n' "$identity" >&2
    exit 1
fi
case "$certificate" in
    *$'\n'*)
        printf 'Multiple valid signing identities match "%s". Set GOBLIN_SIGNING_IDENTITY to one certificate SHA-1 fingerprint:\n%s\n' "$identity" "$certificate" >&2
        exit 1
        ;;
esac

swift build -c "$configuration" --disable-build-manifest-caching
binary_directory=$(swift build -c "$configuration" --show-bin-path)
staging=$(mktemp -d .build/bundle.XXXXXX)
trap 'rm -rf "$staging"' EXIT
app="$staging/gob.lin.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary_directory/GoblinApp" "$app/Contents/MacOS/GoblinApp"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp -R Sources/GoblinApp/Assets "$app/Contents/Resources/"
cp Resources/Goblin.icns "$app/Contents/Resources/"
# Keep dependency resources inside the signed app's canonical Resources directory.
for resource in "$binary_directory"/*.bundle; do
    [ -d "$resource" ] || continue
    cp -R "$resource" "$app/Contents/Resources/"
done

# Match without a pipe: under pipefail, an early-exiting grep can make a match look like a miss.
case "$identities" in
    *"$certificate \"Developer ID Application: "*) developer_id=true ;;
    *) developer_id=false ;;
esac
if "$developer_id"; then
    # Apple's default requirement pins the team, so a renewed certificate still updates installs
    # and keeps privacy grants. Notarization needs a secure timestamp, which needs the network.
    signing=(--timestamp)
else
    # A self-signed certificate has no Apple anchor: pin its public identity, not the executable hash.
    signing=(--timestamp=none --requirements "=designated => identifier \"app.goblin.dictation\" and certificate leaf = H\"$certificate\"")
fi
codesign --force --options runtime "${signing[@]}" \
    --entitlements Resources/Goblin.entitlements --sign "$certificate" "$app"
codesign --verify --strict --verbose=2 "$app"
# Replace only after signing succeeds; never accumulate stale resources between releases.
mkdir -p .build/app
rm -rf .build/app/gob.lin.app
mv "$app" .build/app/gob.lin.app
app='.build/app/gob.lin.app'
printf '\nBuilt %s\nRun: scripts/launch.sh\n' "$app"
