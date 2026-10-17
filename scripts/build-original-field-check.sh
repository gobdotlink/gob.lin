#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
check_root="${1:?Usage: scripts/build-original-field-check.sh private-output-directory}"
swift build --product GoblinApp
python3 - "$check_root" <<'PY'
import json, os, pathlib, plistlib, re, shutil, subprocess, sys
root = pathlib.Path(sys.argv[1]).resolve()
identity = os.environ.get('GOBLIN_SIGNING_IDENTITY', 'gob.lin Local Development')
if not re.fullmatch(r'[0-9A-Fa-f]{40}', identity):
    identities = subprocess.check_output(['security', 'find-identity', '-v', '-p', 'codesigning'], text=True)
    matches = re.findall(r'([0-9A-Fa-f]{40}) "' + re.escape(identity) + '"', identities)
    if len(set(matches)) != 1:
        raise SystemExit('Set GOBLIN_SIGNING_IDENTITY to one valid certificate fingerprint.')
    identity = matches[0]
probe = root / 'gob.lin.app'
target = root / 'Original Field Target.app'
for app in (probe, target):
    (app / 'Contents/MacOS').mkdir(parents=True, exist_ok=True)
description = json.loads(pathlib.Path('.build/debug/description.json').read_text())
args = ['swiftc', '-module-name', 'OriginalFieldProbe', '-parse-as-library', '-swift-version', '6',
        '-target', 'arm64-apple-macosx26.0', '-I', '.build/debug/Modules', '-I', 'Sources/CSQLite']
for item in description['swiftCommands'].values():
    if item.get('moduleName') == 'GoblinApp':
        values = item['otherArguments']
        for i, value in enumerate(values):
            if value == '-Xcc':
                args.extend([value, values[i + 1]])
objects = pathlib.Path('.build/debug/GoblinApp.product/Objects.LinkFileList').read_text().splitlines()
response = root / 'objects.txt'
response.write_text('\n'.join('"' + p + '"' for p in objects if not p.endswith('/GoblinApp.build/GoblinApp.swift.o')) + '\n')
args += ['scripts/checks/original-field.swift', '@' + str(response), '-lc++', '-lsqlite3', '-o', str(probe / 'Contents/MacOS/GoblinApp')]
subprocess.run(args, check=True)
subprocess.run(['swiftc', '-parse-as-library', '-swift-version', '6', 'scripts/checks/original-field-target.swift',
                '-o', str(target / 'Contents/MacOS/OriginalFieldTarget')], check=True)
(probe / 'Contents/Info.plist').write_bytes(pathlib.Path('Resources/Info.plist').read_bytes())
shutil.copytree('Sources/GoblinApp/Assets', probe / 'Contents/Resources/Assets', dirs_exist_ok=True)
with (target / 'Contents/Info.plist').open('wb') as f:
    plistlib.dump(dict(CFBundleIdentifier='app.goblin.original-field-target', CFBundleExecutable='OriginalFieldTarget',
                      CFBundleName='Original Field Target', CFBundlePackageType='APPL'), f)
requirement = 'designated => identifier "app.goblin.dictation" and certificate leaf = H"' + identity + '"'
subprocess.run(['codesign', '--force', '--options', 'runtime', '--timestamp=none', '--entitlements',
                'Resources/Goblin.entitlements', '--sign', identity, '--requirements', '=' + requirement, str(probe)], check=True)
subprocess.run(['codesign', '--force', '--timestamp=none', '--sign', identity, str(target)], check=True)
PY
scripts/launch.sh --check "$check_root/gob.lin.app"
printf 'Built original-field check bundles in %s. Launch both under the shared desktop lock; inspect result.json.\n' "$check_root"
