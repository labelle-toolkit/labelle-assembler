"""Exercise the real installer with empty homes and a fail-closed fake curl.

No network: every requested URL must match one of the generated local archives.
Copy the binary outside the checkout to disable developer sibling discovery.
"""
import argparse
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument('--assembler', default='zig-out/bin/labelle-assembler')
parser.add_argument('--assembler-version', default='0.0.0-dev')
args = parser.parse_args()
binary = Path(args.assembler).resolve()

with tempfile.TemporaryDirectory(prefix='assembler-clean-home-') as folder:
    root = Path(folder)
    installed = root / 'bin/labelle-assembler'
    installed.parent.mkdir()
    shutil.copy2(binary, installed)
    fake_bin = root / 'fake-bin'
    fake_bin.mkdir()
    curl = fake_bin / 'curl'
    curl.write_text(f'#!{sys.executable}\n' + '''import json, os, pathlib, shutil, sys
url = sys.argv[-1]
with open(os.environ['FETCH_LOG'], 'a') as log:
    log.write(url + '\\n')
archives = json.loads(pathlib.Path(os.environ['FETCH_FIXTURES']).read_text())
if url not in archives:
    sys.exit('unexpected fetch: ' + url)
shutil.copyfile(archives[url], sys.argv[sys.argv.index('-o') + 1])
''')
    curl.chmod(0o755)

    for case, pin in [('implicit', None), ('explicit', '0.116.0')]:
        work = root / case
        project = work / 'project'
        project.mkdir(parents=True)
        home = work / 'home'
        home.mkdir()
        version = pin or args.assembler_version
        pin_field = f'.assembler_version = "{pin}",' if pin else ''
        (project / 'project.labelle').write_text('''.{
    .name = "clean_home", .labelle_version = "1.61.2",
    .core_version = "2.1.0", .engine_version = "3.4.1", .gfx_version = "2.2.0",
    .backend = .bgfx, .ecs = .mock, .gamepad = .none,
    .backend_package = .{ .name = "bgfx", .repo = "github.com/labelle-toolkit/labelle-bgfx", .version = "0.31.0" },
''' + pin_field + '\n}\n')
        expected = [
            ('labelle-core', '2.1.0'), ('labelle-engine', '3.4.1'),
            ('labelle-gfx', '2.2.0'), ('labelle-assembler', version),
            ('labelle-bgfx', '0.31.0'), ('labelle-null', '0.3.0'),
        ]
        fixtures = {}
        for index, (repo, release) in enumerate(expected):
            archive = work / f'{index}.tar.gz'
            with tarfile.open(archive, 'w:gz') as tar:
                # The assembler archive carries bundled source directories.
                names = ['ecs/mock/fixture.txt', 'backends/fixture.txt', 'gui/fixture.txt'] if repo == 'labelle-assembler' else ['fixture.txt']
                for name in names:
                    data = f'{repo}@{release}'.encode()
                    info = tarfile.TarInfo('archive-root/' + name)
                    info.size = len(data)
                    tar.addfile(info, io.BytesIO(data))
            # Every version is fetched as its `v` tag — including the dev
            # sentinel `0.0.0-dev`, a semver pre-release since #783.
            ref = f'v{release}'
            fixtures[f'https://github.com/labelle-toolkit/{repo}/archive/{ref}.tar.gz'] = str(archive)
        fixture_file = work / 'fixtures.json'
        fixture_file.write_text(json.dumps(fixtures))
        fetch_log = work / 'fetches.log'
        env = {key: value for key, value in os.environ.items() if not key.startswith('LABELLE_')}
        env.update(HOME=str(home), USERPROFILE=str(home), PATH=str(fake_bin) + os.pathsep + os.defpath,
                   FETCH_LOG=str(fetch_log), FETCH_FIXTURES=str(fixture_file))
        command = [str(installed), 'install', '--project-root', str(project)]
        assert list(home.iterdir()) == []
        result = subprocess.run(command, cwd=project, env=env, capture_output=True, text=True, timeout=60)
        assert result.returncode == 0, result.stdout + result.stderr
        # Assert the complete fetch mechanism, including the actual assembler ref.
        assert fetch_log.read_text().splitlines() == list(fixtures), fetch_log.read_text()
        packages = home / '.labelle/packages'
        assert (packages / f'assembler/{version}/ecs/mock/fixture.txt').read_text() == f'labelle-assembler@{version}'
        assert not (packages / 'assembler/1.61.2').exists()
        result = subprocess.run(command, cwd=project, env=env, capture_output=True, text=True, timeout=60)
        assert result.returncode == 0, result.stdout + result.stderr
        assert fetch_log.read_text().splitlines() == list(fixtures), 'warm install fetched packages again'
        print(f'PASS {case}: exact six-package fetch plan, assembler {version}, warm-cache no-op')
