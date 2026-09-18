"""Qualify and archive the main-based headland-loop test build."""
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile
from zipfile import ZipFile
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[2]
NAME = 'FS25_Courseplay_ImplementProfilesTest.zip'
VERSION = '8.1.0.303'
TITLE = 'CoursePlay - Implement Profiles Test'
BASE = '9b915b07'
sys.dont_write_bytecode = True


def run(*args):
    subprocess.run([sys.executable, '-B', *map(str, args)], cwd=ROOT, check=True)


def revision():
    status = subprocess.check_output(['git', 'status', '--porcelain', '--untracked-files=all'], cwd=ROOT, text=True)
    if status.strip():
        raise RuntimeError('Commit source, tests and notes before building:\n' + status)
    return subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()


def build(output):
    commit = revision()
    run('-m', 'unittest', 'discover', '-s', '.github/scripts', '-p', 'test_build_mod.py', '-v')
    run('tools/double-pivot/test_loops.py')
    subprocess.run(['git', 'diff', '--check', BASE], cwd=ROOT, check=True)
    changed = subprocess.check_output(['git', 'diff', '--name-only', BASE], cwd=ROOT, text=True).splitlines()
    permitted = {'modDesc.xml', 'scripts/ai/turns/AITurn.lua',
                 'scripts/ai/turns/TurnManeuver.lua', 'scripts/ai/turns/HeadlandLoopGeometry.lua'}
    unexpected = [p for p in changed if p.startswith(('scripts/', 'config/')) or p == 'Courseplay.lua']
    if set(unexpected) - permitted:
        raise RuntimeError('Unexpected runtime changes: ' + str(set(unexpected) - permitted))
    spec = importlib.util.spec_from_file_location('package_mod', ROOT / '.github/scripts/build_mod.py')
    packager = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(packager)
    staging = ROOT / 'out'
    staging.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='loop-release-', dir=staging) as temporary:
        temporary = Path(temporary)
        raw = temporary / 'source.zip'
        duplicate = temporary / 'repeat.zip'
        packager.build_mod(ROOT, raw)
        packager.build_mod(ROOT, duplicate)
        if raw.read_bytes() != duplicate.read_bytes():
            raise RuntimeError('Package is not reproducible')
        candidate = temporary / NAME
        with ZipFile(raw) as original, ZipFile(candidate, 'w') as archive:
            for info in original.infolist():
                data = original.read(info.filename)
                if info.filename == 'modDesc.xml':
                    title = '<title>\n' + '\n'.join(f'        <{e.tag}>{TITLE}</{e.tag}>'
                        for e in ET.fromstring(data).find('title')) + '\n    </title>'
                    data = re.sub(rb'<title>.*?</title>', title.encode('utf-8'), data, count=1, flags=re.S)
                archive.writestr(info, data)
        extracted = temporary / 'extracted'
        with ZipFile(candidate) as archive:
            if archive.testzip() is not None:
                raise RuntimeError('ZIP integrity check failed')
            manifest = ET.fromstring(archive.read('modDesc.xml'))
            assert manifest.findtext('version') == VERSION
            assert all(e.text == TITLE for e in manifest.find('title'))
            for name in archive.namelist():
                if name != 'modDesc.xml':
                    assert archive.read(name) == (ROOT / name).read_bytes(), name
                assert 'EnvelopeTurn' not in name
            expected = ET.parse(ROOT / 'modDesc.xml').getroot()
            for entry in expected.find('title'):
                entry.text = TITLE
            # Whitespace in the title section is the only formatting change.
            def normalise(element):
                return (element.tag, sorted(element.attrib.items()), (element.text or '').strip(),
                        [normalise(child) for child in element])
            assert normalise(expected) == normalise(manifest)
            archive.extractall(extracted)
        run('tools/double-pivot/test_loops.py', extracted)
        if revision() != commit:
            raise RuntimeError('Source changed during qualification')
        data = candidate.read_bytes()
        digest = hashlib.sha256(data).hexdigest()
        metadata = {'version': VERSION, 'commit': commit, 'base': BASE, 'sha256': digest}
        history = output / 'history' / VERSION
        archived = history / NAME
        receipt = history / 'build.json'
        if archived.exists() and archived.read_bytes() != data:
            raise RuntimeError('Version already contains a different archive; increment the version')
        if receipt.exists() and json.loads(receipt.read_text()) != metadata:
            raise RuntimeError('Version already belongs to another source commit')
        history.mkdir(parents=True, exist_ok=True)
        archived.write_bytes(data)
        receipt.write_text(json.dumps(metadata, indent=2) + '\n', encoding='utf-8')
        destination = output / NAME
        candidate.replace(destination)
    print(f'PASS: {destination}\nArchive: {archived}\nCommit: {commit}\nSHA-256: {digest}')


if __name__ == '__main__':
    build(Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else ROOT / 'out/double-pivot-release')
