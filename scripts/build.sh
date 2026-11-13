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
entitlements=Resources/Goblin.entitlements
case "$identities" in
    *"$certificate \"Developer ID Application: "*) developer_id=true ;;
    *) developer_id=false ;;
esac
if "$developer_id"; then
    # Apple's default requirement pins the team, so a renewed certificate still updates installs
    # and keeps privacy grants. Notarization needs a secure timestamp, which needs the network.
    signing=(--timestamp)
    # iCloud is a restricted entitlement: macOS honours it only beside the provisioning profile Apple issued for this
    # certificate, and refuses to launch an app that claims it without one. Any other certificate signs without iCloud.
    profile="${GOBLIN_PROVISIONING_PROFILE:-Resources/Goblin.provisionprofile}"
    if [ -f "$profile" ]; then
        security cms -D -i "$profile" > "$staging/profile.plist"
        # ponytail: checks the profile's first certificate only; loop if a profile ever lists several.
        issued_for=$(plutil -extract DeveloperCertificates.0 raw -o - "$staging/profile.plist" | base64 --decode | shasum | awk '{ print toupper($1) }')
        if [ "$issued_for" = "$certificate" ]; then
            team=$(/usr/libexec/PlistBuddy -c 'Print :TeamIdentifier:0' "$staging/profile.plist")
            cp "$profile" "$app/Contents/embedded.provisionprofile"
            cp Resources/Goblin.entitlements "$staging/entitlements.plist"
            entitlements="$staging/entitlements.plist"
            /usr/libexec/PlistBuddy -c "Add :com.apple.application-identifier string $team.app.goblin.dictation" \
                -c "Add :com.apple.developer.team-identifier string $team" \
                -c "Add :com.apple.developer.ubiquity-kvstore-identifier string $team.app.goblin.dictation" "$entitlements"
            # History sync needs CloudKit and push, which a profile grants only once its App ID has gob.lin's container.
            # The environment is Production unless GOBLIN_ICLOUD_ENVIRONMENT says Development, and the profile must allow it.
            container=iCloud.app.goblin.dictation
            environment="${GOBLIN_ICLOUD_ENVIRONMENT:-Production}"
            case "$environment" in
                Development|Production) ;;
                *) printf 'GOBLIN_ICLOUD_ENVIRONMENT must be Development or Production, not %s.\n' "$environment" >&2; exit 1 ;;
            esac
            granted() { /usr/libexec/PlistBuddy -c "Print :Entitlements:$1" "$staging/profile.plist" 2>/dev/null || true; }
            containers=$(granted com.apple.developer.icloud-container-identifiers)
            environments=$(granted com.apple.developer.icloud-container-environment)
            push=$(granted com.apple.developer.aps-environment)
            # The first thing missing, if any.
            missing=""
            [ -n "$push" ] || missing="the profile has no push notifications"
            case "$environments" in *"$environment"*) ;; *) missing="the profile does not allow the $environment environment" ;; esac
            case "$containers" in *"$container"*) ;; *) missing="the profile does not list $container" ;; esac
            if [ -z "$missing" ]; then
                /usr/libexec/PlistBuddy -c "Add :com.apple.developer.icloud-container-identifiers array" \
                    -c "Add :com.apple.developer.icloud-container-identifiers:0 string $container" \
                    -c "Add :com.apple.developer.icloud-services array" \
                    -c "Add :com.apple.developer.icloud-services:0 string CloudKit" \
                    -c "Add :com.apple.developer.icloud-container-environment string $environment" \
                    -c "Add :com.apple.developer.aps-environment string $push" "$entitlements"
                printf 'History sync: on, in the %s environment.\n' "$environment"
            elif [ -n "${GOBLIN_ICLOUD_ENVIRONMENT:-}" ]; then
                printf 'Cannot sign for the %s environment: %s.\n' "$environment" "$missing" >&2
                exit 1
            else
                printf 'Signing without History sync: %s.\n' "$missing" >&2
            fi
        else
            printf 'Signing without iCloud: %s was not issued for this certificate.\n' "$profile" >&2
        fi
    fi
else
    # A self-signed certificate has no Apple anchor: pin its public identity, not the executable hash.
    signing=(--timestamp=none --requirements "=designated => identifier \"app.goblin.dictation\" and certificate leaf = H\"$certificate\"")
fi
codesign --force --options runtime "${signing[@]}" \
    --entitlements "$entitlements" --sign "$certificate" "$app"
codesign --verify --strict --verbose=2 "$app"
# Replace only after signing succeeds; never accumulate stale resources between releases.
mkdir -p .build/app
rm -rf .build/app/gob.lin.app
mv "$app" .build/app/gob.lin.app
app='.build/app/gob.lin.app'
printf '\nBuilt %s\nRun: scripts/launch.sh\n' "$app"
