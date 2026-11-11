"""Run the release command against local Git remotes."""
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
    env = dict(os.environ, PATH=str(tools) + os.pathsep + os.environ['PATH'])

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
    assert run('git', 'ls-remote', '--tags', 'origin', 'v0.1.1', cwd=work).stdout != ''
    assert run('bash', 'scripts/release.sh', '0.1.1', cwd=work, env=env, check=False).returncode != 0
print('Release version recovery, exact-commit tagging and atomic push checks passed.')
