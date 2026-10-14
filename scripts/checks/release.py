"""Run the release command against local Git remotes and a fake GitHub CLI."""
import json
import os
import pathlib
import plistlib
import shutil
import subprocess
import tempfile

release_source = pathlib.Path('scripts/release.sh').resolve()

def run(*args, cwd, env=None, check=True):
    result = subprocess.run(args, cwd=cwd, env=env, capture_output=True, text=True)
    if check and result.returncode:
        raise RuntimeError(result.stdout + result.stderr)
    return result

with tempfile.TemporaryDirectory() as temporary:
    root = pathlib.Path(temporary)
    remote = root / 'remote.git'
    work = root / 'work'
    run('git', 'init', '--bare', str(remote), cwd=root)
    work.mkdir()
    run('git', 'init', '-b', 'main', cwd=work)
    run('git', 'config', 'user.name', 'Release fixture', cwd=work)
    run('git', 'config', 'user.email', 'release@example.invalid', cwd=work)
    run('git', 'config', 'commit.gpgsign', 'false', cwd=work)
    run('git', 'config', 'tag.gpgsign', 'false', cwd=work)
    run('git', 'remote', 'add', 'origin', str(remote), cwd=work)
    (work / 'Resources').mkdir()
    shutil.copy('Resources/Info.plist', work / 'Resources/Info.plist')
    plist = plistlib.loads((work / 'Resources/Info.plist').read_bytes())
    plist['CFBundleShortVersionString'] = '0.1.0'
    plist['CFBundleVersion'] = '1'
    (work / 'Resources/Info.plist').write_bytes(plistlib.dumps(plist))
    source = work / 'Sources/GoblinCore'
    source.mkdir(parents=True)
    (source / 'GoblinMetadata.swift').write_text('public enum GoblinMetadata { public static let version = "0.1.0" }\n')
    scripts = work / 'scripts'
    scripts.mkdir()
    shutil.copy(release_source, scripts / 'release.sh')
    for name in ['smoke.sh', 'check-updates.sh']:
        path = scripts / name
        path.write_text('#!/bin/sh\ntest "${FAIL_STEP:-}" != checks\n')
        path.chmod(0o755)
    (scripts / 'check-repository.py').write_text('pass\n')
    package = scripts / 'package-app.sh'
    package.write_text('''#!/bin/sh
set -eu
test "${FAIL_STEP:-}" != package
test -z "$(git status --porcelain)"
mkdir -p dist
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)
git rev-parse HEAD > "dist/gob.lin-$version.zip"
echo fixture > "dist/gob.lin-$version.zip.sha256"
''')
    package.chmod(0o755)
    (work / '.gitignore').write_text('dist/\n')
    run('git', 'add', '.', cwd=work)
    run('git', 'commit', '-m', 'Initial fixture', cwd=work)
    run('git', 'push', '-u', 'origin', 'main', cwd=work)
    initial = run('git', 'rev-parse', 'HEAD', cwd=work).stdout.strip()
    original_plist = (work / 'Resources/Info.plist').read_bytes()
    original_metadata = (source / 'GoblinMetadata.swift').read_bytes()
    tools = root / 'bin'
    tools.mkdir()
    swift = tools / 'swift'
    swift.write_text('#!/bin/sh\nexit 0\n')
    swift.chmod(0o755)
    gh = tools / 'gh'
    gh.write_text('''#!/usr/bin/env python3
import json, os, sys
with open(os.environ['GH_FIXTURE_LOG'], 'a') as log: log.write(json.dumps(sys.argv[1:]) + '\\n')
if sys.argv[1:3] == ['release', 'create'] and os.environ.get('FAIL_STEP') == 'upload': sys.exit(1)
if sys.argv[1:3] == ['release', 'view']: print('https://example.invalid/release')
''')
    gh.chmod(0o755)
    log = root / 'gh.jsonl'
    env = dict(os.environ, PATH=str(tools) + os.pathsep + os.environ['PATH'], GH_FIXTURE_LOG=str(log))

    for version in ['invalid', '0.1.0', '0.01.1', '0.1.1-beta']:
        assert run('bash', 'scripts/release.sh', version, cwd=work, env=env, check=False).returncode != 0
        assert (work / 'Resources/Info.plist').read_bytes() == original_plist
    failed = dict(env, FAIL_STEP='checks')
    assert run('bash', 'scripts/release.sh', '0.1.1', cwd=work, env=failed, check=False).returncode != 0
    assert (work / 'Resources/Info.plist').read_bytes() == original_plist
    assert (source / 'GoblinMetadata.swift').read_bytes() == original_metadata
    assert run('git', 'status', '--porcelain', cwd=work).stdout == ''
    assert run('git', 'rev-parse', 'HEAD', cwd=work).stdout.strip() == initial

    run('bash', 'scripts/release.sh', '0.1.1', cwd=work, env=env)
    revision = run('git', 'rev-parse', 'HEAD', cwd=work).stdout.strip()
    assert revision != initial
    assert run('git', 'rev-parse', 'v0.1.1^{commit}', cwd=work).stdout.strip() == revision
    assert run('git', 'rev-parse', 'origin/main', cwd=work).stdout.strip() == revision
    assert (work / 'dist/gob.lin-0.1.1.zip').read_text().strip() == revision
    calls = [json.loads(line) for line in log.read_text().splitlines()]
    create = next(call for call in calls if call[:2] == ['release', 'create'])
    assert '--draft' in create and '--verify-tag' in create
    assert create[create.index('--target') + 1] == revision
    edit = next(call for call in calls if call[:2] == ['release', 'edit'])
    assert '--draft=false' in edit and '--latest' in edit

    # Upload failure leaves a draft and never executes the publish operation.
    log.write_text('')
    failed = dict(env, FAIL_STEP='upload')
    assert run('bash', 'scripts/release.sh', '0.1.2', cwd=work, env=failed, check=False).returncode != 0
    calls = [json.loads(line) for line in log.read_text().splitlines()]
    assert any(call[:2] == ['release', 'create'] and '--draft' in call for call in calls)
    assert not any(call[:2] == ['release', 'edit'] for call in calls)
print('Release version recovery, exact-commit tagging, and draft-before-publish checks passed.')
