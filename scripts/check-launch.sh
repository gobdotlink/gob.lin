#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
app="${1:-.build/app/gob.lin.app}"
scripts/launch.sh --check "$app"
check_directory=$(mktemp -d)
trap 'rm -rf "$check_directory"' EXIT
fixture="$check_directory/signed copy.app"
ditto "$app" "$fixture"
scripts/launch.sh --check "$fixture" >/dev/null 2>&1

mkdir "$check_directory/bin"
cat > "$check_directory/bin/pgrep" <<'STUB'
#!/bin/bash
printf '424242\n'
STUB
cat > "$check_directory/bin/open" <<'STUB'
#!/bin/bash
printf 'ERROR: launcher tried to open an app despite an existing process\n' >&2
exit 99
STUB
chmod +x "$check_directory/bin/pgrep" "$check_directory/bin/open"
if PATH="$check_directory/bin:$PATH" scripts/launch.sh "$fixture" > "$check_directory/output" 2>&1; then
    printf 'Launcher accepted an existing gob.lin process.\n' >&2; exit 1
fi
grep -q 'already running (PID 424242)' "$check_directory/output"

codesign --force --sign - --identifier app.goblin.dictation "$fixture" >/dev/null 2>&1
if scripts/launch.sh --check "$fixture" > "$check_directory/output" 2>&1; then
    printf 'Launcher accepted an ad-hoc bundle.\n' >&2; exit 1
fi
grep -q 'Unsupported signing identity' "$check_directory/output"
codesign --remove-signature "$fixture"
if scripts/launch.sh --check "$fixture" >/dev/null 2>&1; then
    printf 'Launcher accepted an unsigned bundle.\n' >&2; exit 1
fi
if scripts/launch.sh --check "$check_directory/missing.app" >/dev/null 2>&1; then
    printf 'Launcher accepted a missing bundle.\n' >&2; exit 1
fi
printf 'Signed launcher probes passed (no app launched; temporary copies only).\n'
