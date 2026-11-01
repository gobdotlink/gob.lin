#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [ "${1:-}" = --help ]; then
    printf 'Usage: scripts/release.sh <major.minor.patch>\nRun from clean, up-to-date main. Builds a signed ZIP, commits the version, pushes, and publishes a GitHub release.\n'
    exit 0
fi
if [ "$#" -ne 1 ]; then printf 'Usage: scripts/release.sh <major.minor.patch>\n' >&2; exit 2; fi
version=$1
repository=gobdotlink/gob.lin
fail() { printf 'release: %s\n' "$*" >&2; exit 1; }
command -v gh >/dev/null || fail 'Install GitHub CLI and run gh auth login first.'
command -v python3 >/dev/null || fail 'Python 3 is required for version validation.'
[ -z "$(git status --porcelain)" ] || fail 'Working tree is dirty.'
[ "$(git branch --show-current)" = main ] || fail 'Run from main.'
gh auth status --hostname github.com >/dev/null 2>&1 || fail 'GitHub authentication unavailable.'
git fetch origin main --tags
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || fail 'main must match origin/main. Pull or push your changes first.'
if git rev-parse -q --verify "refs/tags/v$version" >/dev/null; then fail 'Release tag already exists.'; fi

# Validate before changing any files. Keep the CLI and app versions in sync.
python3 - "$version" <<'PY'
import pathlib, plistlib, re, sys
version = sys.argv[1]
def parse(value):
    if not re.fullmatch(r'(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)', value):
        sys.exit('release: use a stable major.minor.patch version without a v prefix')
    parts = tuple(map(int, value.split('.')))
    if any(part > 2**63 - 1 for part in parts):
        sys.exit('release: version component is too large')
    return parts
plist = plistlib.loads(pathlib.Path('Resources/Info.plist').read_bytes())
if parse(version) <= parse(plist['CFBundleShortVersionString']):
    sys.exit('release: version must increase')
source = pathlib.Path('Sources/GoblinCore/GoblinMetadata.swift').read_text()
if f'public static let version = "{plist["CFBundleShortVersionString"]}"' not in source:
    sys.exit('release: CLI and app versions differ')
if not str(plist['CFBundleVersion']).isdigit():
    sys.exit('release: invalid bundle build number')
PY

temporary=$(mktemp -d)
cp Resources/Info.plist "$temporary/Info.plist"
cp Sources/GoblinCore/GoblinMetadata.swift "$temporary/GoblinMetadata.swift"
committed=false
cleanup() {
    if ! "$committed"; then
        git restore --staged -- Resources/Info.plist Sources/GoblinCore/GoblinMetadata.swift
        cp "$temporary/Info.plist" Resources/Info.plist
        cp "$temporary/GoblinMetadata.swift" Sources/GoblinCore/GoblinMetadata.swift
    fi
    rm -rf "$temporary"
}
trap cleanup EXIT
python3 - "$version" <<'PY'
import pathlib, plistlib, re, sys
path = pathlib.Path('Resources/Info.plist')
plist = plistlib.loads(path.read_bytes())
plist['CFBundleShortVersionString'] = sys.argv[1]
plist['CFBundleVersion'] = str(int(plist['CFBundleVersion']) + 1)
path.write_bytes(plistlib.dumps(plist, sort_keys=False))
path = pathlib.Path('Sources/GoblinCore/GoblinMetadata.swift')
path.write_text(re.sub(r'public static let version = "[^"]+"',
                       f'public static let version = "{sys.argv[1]}"', path.read_text()))
PY

# Validate before committing/publishing. A failure restores the version files.
scripts/smoke.sh
swift test
scripts/check-updates.sh
python3 scripts/check-repository.py
git add Resources/Info.plist Sources/GoblinCore/GoblinMetadata.swift
git commit -m "Release v$version"
committed=true
revision=$(git rev-parse HEAD)
# Package the clean release commit so embedded build identity matches the published tag.
scripts/package-app.sh
archive="dist/gob.lin-$version.zip"
git tag -a "v$version" -m "Release v$version"
git push --atomic origin main "v$version"
# A draft keeps incomplete asset uploads out of the app's update channel.
gh release create "v$version" "$archive" "$archive.sha256" --repo "$repository" \
    --verify-tag --target "$revision" --title "v$version" --generate-notes --draft \
    --notes "New to gob.lin? Follow the [install steps](https://github.com/gobdotlink/gob.lin#install): this build is not notarized, so the first launch needs **Open Anyway**."
gh release edit "v$version" --repo "$repository" --draft=false --latest
gh release view "v$version" --repo "$repository" --json url --jq .url
