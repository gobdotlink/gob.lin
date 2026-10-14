"""Exercise the real helper with temporary app fixtures and a stub launcher."""
import pathlib
import shlex
import subprocess
import tempfile
import time

source = pathlib.Path('Sources/GoblinApp/Assets/install-update.sh').read_text()
with tempfile.TemporaryDirectory() as temporary:
    root = pathlib.Path(temporary) / "Mac's apps"
    root.mkdir()
    launcher = root / 'open'
    launcher.write_text('#!/bin/sh\nexit 0\n')
    launcher.chmod(0o755)
    helper = root / 'install.sh'
    helper.write_text(source.replace('/usr/bin/open', shlex.quote(str(launcher))))

    def fixture(name):
        directory = root / name
        directory.mkdir()
        app = directory / 'gob.lin.app'
        app.mkdir()
        (app / 'version').write_text('old')
        staging = directory / '.goblin-update-fixture'
        payload = staging / 'payload' / 'gob.lin.app'
        payload.mkdir(parents=True)
        (payload / 'version').write_text('new')
        return app, staging

    app, staging = fixture('normal')
    old_process = subprocess.Popen(['/bin/sleep', '1'])
    process = subprocess.Popen(['/bin/sh', str(helper), str(old_process.pid), str(app), str(staging), str(root / 'normal.log')])
    time.sleep(0.15)
    assert (app / 'version').read_text() == 'old', 'Must not replace a running app'
    old_process.wait()
    assert process.wait(timeout=5) == 0
    assert (app / 'version').read_text() == 'new'
    assert not staging.exists()

    # Fail the first launch of the new bundle, then permit launch of the restored copy.
    launcher.write_text('#!/bin/sh\ntest "$(cat "$2/version")" = old\n')
    app, staging = fixture('rollback')
    exited = subprocess.Popen(['/usr/bin/true'])
    exited.wait()
    result = subprocess.run(['/bin/sh', str(helper), str(exited.pid), str(app), str(staging), str(root / 'rollback.log')], timeout=5)
    assert result.returncode == 1
    assert (app / 'version').read_text() == 'old', 'Restore old app if relaunch fails'
    assert not staging.exists()
print('Install waits for exit and restores the previous app on relaunch failure.')
