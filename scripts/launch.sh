#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

check_only=false
if [ "${1:-}" = '--check' ]; then check_only=true; shift; fi
if [ "$#" -gt 1 ]; then
    printf 'Usage: scripts/launch.sh [--check] [path/to/gob.lin.app]\n' >&2
    exit 2
fi
app="${1:-.build/app/gob.lin.app}"
if [ ! -d "$app" ]; then
    printf 'App bundle not found: %s. Build with scripts/build.sh first.\n' "$app" >&2
    exit 1
fi
app=$(cd "$app" && pwd -P)
identifier=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")
executable=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app/Contents/Info.plist")
if [ "$identifier" != 'app.goblin.dictation' ] || [ "$executable" != 'GoblinApp' ]; then
    printf 'This is not the supported gob.lin app bundle: %s\n' "$app" >&2
    exit 1
fi
codesign --verify --strict --verbose=2 "$app"
signature=$(codesign --display --verbose=4 "$app" 2>&1)
requirement=$(codesign --display --requirements - "$app" 2>&1)
if ! printf '%s\n' "$signature" | grep -q '^Authority=' || printf '%s\n' "$requirement" | grep -q 'cdhash'; then
    printf 'Unsupported signing identity. Use a certificate-signed bundle from scripts/build.sh or the signed Xcode target; validation/ad-hoc products must not request grants.\n' >&2
    exit 1
fi
codesign --verify --strict --test-requirement '=identifier "app.goblin.dictation"' "$app"
printf 'Verified bundle: %s\nExecutable: %s/Contents/MacOS/%s\n%s\n' "$app" "$app" "$executable" "$requirement"
if "$check_only"; then exit 0; fi
if running=$(pgrep -x GoblinApp); then
    printf 'gob.lin is already running (PID %s). Quit it before launching this exact bundle.\n' "$running" >&2
    exit 1
fi
# An explicit new instance avoids Launch Services activating a different worktree.
open -n "$app"
