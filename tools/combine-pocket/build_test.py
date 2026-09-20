"""Qualify a numbered combine-pocket test ZIP without changing the live manifest."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
from zipfile import ZipFile


ROOT = Path(__file__).resolve().parents[2]
NAME = 'FS25_Courseplay_CombinePocketTest.zip'
TITLE = 'CoursePlay - Combine Pocket Test'
VERSION = '8.1.0.324'
BUILD = '007'
BASE = '13b80109'


def run(*args, cwd=ROOT):
    subprocess.run([sys.executable, '-B', *map(str, args)], cwd=cwd, check=True)


def revision():
    status = subprocess.check_output(['git', 'status', '--porcelain', '--untracked-files=all'], cwd=ROOT, text=True)
    if status.strip():
        raise RuntimeError('Commit source, tests and notes before building:\n' + status)
    return subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()


def profiles(runtime):
    run('-c', "from lupa.lua51 import LuaRuntime; "
        "LuaRuntime().execute(open('ImplementProfileTest.lua', encoding='utf-8-sig').read())",
        cwd=runtime / 'scripts/test')


def build(output):
    commit = revision()
    run('-m', 'unittest', 'discover', '-s', '.github/scripts', '-p', 'test_*.py', '-v')
    run('tools/course-headland-loop/test_setting.py')
    run('tools/combine-pocket/test_pocket.py')
    profiles(ROOT)
    subprocess.run(['git', 'diff', '--check', BASE], cwd=ROOT, check=True)
    spec = importlib.util.spec_from_file_location('package_mod', ROOT / '.github/scripts/build_mod.py')
    packager = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(packager)
    staging = ROOT / 'out'
    staging.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='combine-pocket-release-', dir=staging) as temporary:
        temporary = Path(temporary)
        raw, duplicate = temporary / 'source.zip', temporary / 'repeat.zip'
        packager.build_mod(ROOT, raw)
        packager.build_mod(ROOT, duplicate)
        if raw.read_bytes() != duplicate.read_bytes():
            raise RuntimeError('Package is not reproducible')
        candidate = temporary / NAME
        with ZipFile(raw) as original, ZipFile(candidate, 'w') as archive:
            for info in original.infolist():
                data = original.read(info.filename)
                if info.filename == 'modDesc.xml':
                    title = '<title>' + ''.join(f'<{e.tag}>{TITLE}</{e.tag}>'
                        for e in ET.fromstring(data).find('title')) + '</title>'
                    data = re.sub(rb'<title>.*?</title>', title.encode(), data, count=1, flags=re.S)
                    data = re.sub(rb'<version>.*?</version>', f'<version>{VERSION}</version>'.encode(), data, count=1)
                archive.writestr(info, data)
        extracted = temporary / 'extracted'
        with ZipFile(candidate) as archive:
            assert archive.testzip() is None
            manifest = ET.fromstring(archive.read('modDesc.xml'))
            assert manifest.findtext('version') == VERSION
            assert all(e.text == TITLE for e in manifest.find('title'))
            for name in archive.namelist():
                assert packager.is_runtime_file(name), name
                if name != 'modDesc.xml':
                    assert archive.read(name) == (ROOT / name).read_bytes(), name
                if name.endswith('.xml'):
                    ET.fromstring(archive.read(name))
            archive.extractall(extracted)
        run('tools/course-headland-loop/test_setting.py', extracted)
        run('tools/straight-entry/test_entry.py', extracted)
        run('tools/double-pivot/test_loops.py', extracted)
        run('tools/combine-pocket/test_pocket.py', extracted)
        (extracted / 'scripts/test').mkdir()
        for name in ('luaunit.lua', 'ImplementProfileTest.lua'):
            shutil.copy2(ROOT / 'scripts/test' / name, extracted / 'scripts/test' / name)
        profiles(extracted)
        if revision() != commit:
            raise RuntimeError('Source changed during release checks')
        data = candidate.read_bytes()
        metadata = {'build': BUILD, 'version': VERSION, 'commit': commit,
                    'base': BASE, 'sha256': hashlib.sha256(data).hexdigest()}
        destination, receipt = output / NAME, output / 'build.json'
        if destination.exists() and destination.read_bytes() != data:
            raise RuntimeError('This build already exists with different bytes; increment the build and version')
        if receipt.exists() and json.loads(receipt.read_text()) != metadata:
            raise RuntimeError('This build already belongs to a different source revision')
        output.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(data)
        receipt.write_text(json.dumps(metadata, indent=2) + '\n', encoding='utf-8')
        print(f'PASS: Test {BUILD}, version {VERSION}\n{destination}\nSHA-256: {metadata["sha256"]}')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=ROOT / 'out/combine-pocket' / BUILD)
    build(parser.parse_args().output.resolve())
