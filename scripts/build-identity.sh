#!/bin/sh
set -eu
# The package plugin also runs for GoblinCore in the Xcode app build.
repository="$1"
destination="$2"
revision=$(git -C "$repository" rev-parse HEAD 2>/dev/null || printf unknown)
case "$revision" in *[!0-9a-f]*|'') revision=unknown ;; esac
dirty=false
if [ "$revision" != unknown ] && [ -n "$(git --no-optional-locks -C "$repository" status --porcelain --untracked-files=normal)" ]; then dirty=true; fi
mkdir -p "$destination"
cat > "$destination/GoblinBuildStamp.swift" <<STAMP
enum GoblinBuildStamp {
    static let revision = "$revision"
    static let dirty = $dirty
    static let builtAt = "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    static let id = "$(uuidgen)"
}
STAMP
