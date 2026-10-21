#!/bin/bash
# Live dictionary suggestions: speaks two sentences through the speakers into TextEdit, edits the result and checks
# the suggestions. Needs the microphone and Accessibility grants of the signing identity, a quiet room, and
# Parakeet v3 prepared. Uses an isolated dictionary, history and preferences; leaves an unsaved TextEdit window.
set -euo pipefail
cd "$(dirname "$0")/.."
root="${1:-$(mktemp -d /tmp/goblin-suggestions.XXXXXX)}"
identity="${GOBLIN_SIGNING_IDENTITY:-gob.lin Local Development}"
if [[ ! "$identity" =~ ^[[:xdigit:]]{40}$ ]]; then
    name="$identity"
    identity=$(security find-identity -v -p codesigning | awk -v quoted="\"$name\"" 'index($0, quoted) && length($2) == 40 { print $2; exit }')
    [ -n "$identity" ] || { printf 'No valid signing identity matches "%s".\n' "$name" >&2; exit 1; }
fi
if pgrep -x GoblinApp >/dev/null; then printf 'Quit gob.lin first: the check uses the same bundle identifier.\n' >&2; exit 1; fi

swift build --product GoblinApp
probe="$root/gob.lin.app"
mkdir -p "$probe/Contents/MacOS" "$probe/Contents/Resources" "$root/results"
python3 - "$root" <<'PY'
import json, pathlib, subprocess, sys
root=pathlib.Path(sys.argv[1]); desc=json.loads(pathlib.Path('.build/debug/description.json').read_text())
args=['swiftc','-module-name','DictionarySuggestionsProbe','-parse-as-library','-swift-version','6','-target','arm64-apple-macosx26.0','-I','.build/debug/Modules','-I','Sources/CSQLite']
for item in desc['swiftCommands'].values():
 if item.get('moduleName')=='GoblinApp':
  values=item['otherArguments']
  for i,value in enumerate(values):
   if value=='-Xcc': args.extend([value,values[i+1]])
objects=pathlib.Path('.build/debug/GoblinApp.product/Objects.LinkFileList').read_text().splitlines()
objects=[x for x in objects if not x.endswith('/GoblinApp.build/GoblinApp.swift.o')]
(root/'objects.txt').write_text('\n'.join(objects)+'\n')
args.extend(['scripts/checks/dictionary-suggestions.swift','@'+str(root/'objects.txt'),'-lc++','-lsqlite3','-o',str(root/'gob.lin.app/Contents/MacOS/GoblinApp')])
subprocess.run(args,check=True)
PY
cp Resources/Info.plist "$probe/Contents/Info.plist"
cp -R Sources/GoblinApp/Assets "$probe/Contents/Resources/"
requirement="designated => identifier \"app.goblin.dictation\" and certificate leaf = H\"$identity\""
codesign --force --options runtime --timestamp=none --entitlements Resources/Goblin.entitlements --sign "$identity" --requirements "=$requirement" "$probe"

# A repository TextEdit can name: a package, folders and one author.
repository="$root/quixlo"
mkdir -p "$repository/Fluxomatic" "$repository/Sources" "$repository/node_modules"
printf 'let package = Package(name: "QuixloKit")\n' > "$repository/Package.swift"
: > "$repository/notes.txt"
touch "$repository/Fluxomatic/.keep" "$repository/Sources/.keep"
git -C "$repository" init -q
git -C "$repository" add -A
git -C "$repository" -c user.name="Quentin Ostrowski" -c user.email=quentin@example.com commit -qm init
say -r 170 -o "$root/first.aiff" 'We should ship the zorb lax build to Quentin today.'
say -r 170 -o "$root/second.aiff" 'The zorb lax build is ready for review.'
open -a TextEdit "$repository/notes.txt"
sleep 2
open -n -W "$probe" --args "$root/results" "$repository/notes.txt" "$root/first.aiff" "$root/second.aiff"
cat "$root/results/suggestions-result.json"
printf '\nImages: %s/results\n' "$root"
python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1]))["passed"] else 1)' "$root/results/suggestions-result.json"
