#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
check_root="${1:?Usage: scripts/build-native-dictation-check.sh private-output-directory}"
identity="${GOBLIN_SIGNING_IDENTITY:-gob.lin Local Development}"
# The signing requirement pins the certificate, so a name is resolved to its SHA-1 fingerprint.
if [[ ! "$identity" =~ ^[[:xdigit:]]{40}$ ]]; then
    name="$identity"
    identity=$(security find-identity -v -p codesigning | awk -v quoted="\"$name\"" 'index($0, quoted) && length($2) == 40 { print $2; exit }')
    if [ -z "$identity" ]; then
        printf 'No valid signing identity matches "%s". Set GOBLIN_SIGNING_IDENTITY to a certificate name or SHA-1 fingerprint.\n' "$name" >&2
        exit 1
    fi
fi
if pgrep -x GoblinApp >/dev/null || pgrep -x NativeTarget >/dev/null; then
    printf 'Close existing app/check instances before rebuilding native check bundles.\n' >&2
    exit 1
fi
swift build --product GoblinApp
mkdir -p "$check_root/gob.lin.app/Contents/MacOS" "$check_root/gob.lin.app/Contents/Resources"
mkdir -p "$check_root/Native Target.app/Contents/MacOS" "$check_root/Native Target.app/Contents/Resources"
python3 - "$check_root" <<'PY'
import json, pathlib, subprocess, sys
root=pathlib.Path(sys.argv[1]); desc=json.loads(pathlib.Path('.build/debug/description.json').read_text())
args=['swiftc','-module-name','NativeDictationProbe','-parse-as-library','-swift-version','6','-target','arm64-apple-macosx26.0','-I','.build/debug/Modules','-I','Sources/CSQLite']
for item in desc['swiftCommands'].values():
 if item.get('moduleName')=='GoblinApp':
  values=item['otherArguments']
  for i,value in enumerate(values):
   if value=='-Xcc': args.extend([value,values[i+1]])
objects=pathlib.Path('.build/debug/GoblinApp.product/Objects.LinkFileList').read_text().splitlines()
objects=[x for x in objects if not x.endswith('/GoblinApp.build/GoblinApp.swift.o')]
(root/'objects.txt').write_text('\n'.join(objects)+'\n')
args.extend(['scripts/checks/native-dictation.swift','@'+str(root/'objects.txt'),'-lc++','-lsqlite3','-o',str(root/'gob.lin.app/Contents/MacOS/GoblinApp')])
subprocess.run(args,check=True)
PY
swiftc -parse-as-library -swift-version 6 scripts/checks/native-dictation-target.swift -o "$check_root/Native Target.app/Contents/MacOS/NativeTarget"
cp Resources/Info.plist "$check_root/gob.lin.app/Contents/Info.plist"
cp -R Sources/GoblinApp/Assets "$check_root/gob.lin.app/Contents/Resources/"
cp Resources/Goblin.icns "$check_root/gob.lin.app/Contents/Resources/"
cat > "$check_root/Native Target.app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>app.goblin.native-dictation-target</string>
<key>CFBundleName</key><string>gob.lin Native Target</string>
<key>CFBundleExecutable</key><string>NativeTarget</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
say -r 180 -o "$check_root/gob.lin.app/Contents/Resources/speech.aiff" 'The small green goblin keeps every final word. Please write the ending clearly, purple violet.'
requirement="designated => identifier \"app.goblin.dictation\" and certificate leaf = H\"$identity\""
codesign --force --options runtime --timestamp=none --entitlements Resources/Goblin.entitlements --sign "$identity" --requirements "=$requirement" "$check_root/gob.lin.app"
codesign --force --timestamp=none --sign "$identity" "$check_root/Native Target.app"
scripts/launch.sh --check "$check_root/gob.lin.app"
printf 'Native check bundles built in %s. Launch only under the shared desktop/compute locks.\n' "$check_root"
