"""Qualify the main merge while keeping its live manifest separate from the test ZIP."""
import hashlib
import importlib.util
import json
import re
from pathlib import Path
import subprocess
import sys
import tempfile
from zipfile import ZipFile
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[2]
NAME = 'FS25_Courseplay_StraightEntryTest.zip'
VERSION = '8.1.0.317'
TITLE = 'CoursePlay - Straight Entry + Loop Test v0.29'
sys.dont_write_bytecode = True


def run(*args):
    subprocess.run([sys.executable, '-B', *map(str, args)], cwd=ROOT, check=True)


def committed_source():
    status = subprocess.check_output(['git', 'status', '--porcelain', '--untracked-files=all'], cwd=ROOT, text=True)
    if status.strip():
        raise RuntimeError('Commit the source, tests and release notes before building:\n' + status)
    return subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()


def build(output):
    revision = committed_source()
    run('-m', 'unittest', 'discover', '-s', '.github/scripts', '-p', 'test_*.py', '-v')
    run('tools/straight-entry/test_entry.py')
    run('tools/double-pivot/test_loops.py')
    subprocess.run(['git', 'diff', '--check', 'c965b604'], cwd=ROOT, check=True)
    # Compare with the fetched main parent. Existing main features stay intact;
    # only the reviewed turn changes may be introduced by this merge.
    changed = subprocess.check_output(['git', 'diff', '--name-only', 'c965b604'], cwd=ROOT, text=True).splitlines()
    permitted = {'modDesc.xml', 'scripts/ai/turns/AITurn.lua',
                 'scripts/ai/turns/TurnContext.lua', 'scripts/ai/turns/TurnManeuver.lua',
                 'scripts/ai/turns/WorkStartHandler.lua', 'scripts/ai/controllers/PlowController.lua'}
    permitted.update({'scripts/ai/strategies/AIDriveStrategyCourse.lua',
                      'scripts/ai/strategies/AIDriveStrategyFieldWorkCourse.lua',
                      'scripts/ai/turns/BulbTurnExtension.lua',
                      'scripts/ai/turns/HeadlandLoopGeometry.lua',
                      'scripts/ai/turns/HeadlandLoopModel.lua',
                      'scripts/ai/turns/HeadlandLoopValidation.lua',
                      'scripts/ai/turns/HeadlandLoopReturn.lua',
                      'scripts/ai/turns/HeadlandLoopSearch.lua',
                      'scripts/ai/strategies/AIDriveStrategyDriveToFieldWorkStart.lua',
                      'scripts/ai/util/FieldworkBoundary.lua',
                      'scripts/courseGenerator/FieldworkCourse.lua', 'scripts/courseGenerator/HeadlandConnector.lua',
                      'scripts/courseGenerator/FieldworkCourseMultiVehicle.lua',
                      'scripts/pathfinder/PathfinderConstraints.lua', 'scripts/pathfinder/PathfinderUtil.lua'})
    unexpected = [n for n in changed if (n.startswith(('scripts/', 'config/')) or n == 'Courseplay.lua') and n not in permitted]
    if unexpected:
        raise RuntimeError(f'Unreviewed runtime changes: {unexpected}')
    spec = importlib.util.spec_from_file_location('package_mod', ROOT / '.github/scripts/build_mod.py')
    packager = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(packager)
    staging = ROOT / 'out'
    staging.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='straight-entry-release-', dir=staging) as temp:
        temp = Path(temp)
        candidate = temp / NAME
        # Build and compare twice before changing only the test identity. Main
        # keeps its normal CoursePlay title and live version for GitHub releases.
        raw = temp / 'source.zip'
        repeated = temp / 'repeat.zip'
        assert packager.build_mod(ROOT, raw) == '8.1.0.28'
        packager.build_mod(ROOT, repeated)
        assert raw.read_bytes() == repeated.read_bytes(), 'Non-reproducible package'
        with ZipFile(raw) as original, ZipFile(candidate, 'w') as test:
            for info in original.infolist():
                data = original.read(info.filename)
                assert data == (ROOT / info.filename).read_bytes(), info.filename
                if info.filename == 'modDesc.xml':
                    manifest = ET.fromstring(data)
                    title = '<title>' + ''.join(f'<{e.tag}>{TITLE}</{e.tag}>' for e in manifest.find('title')) + '</title>'
                    data = re.sub(rb'<title>.*?</title>', title.encode(), data, count=1, flags=re.S)
                    data = re.sub(rb'<version>.*?</version>', f'<version>{VERSION}</version>'.encode(), data, count=1)
                test.writestr(info, data)
        extracted = temp / 'extracted'
        with ZipFile(candidate) as archive:
            manifest = ET.fromstring(archive.read('modDesc.xml'))
            assert manifest.findtext('version') == VERSION
            assert all(t.text == TITLE for t in manifest.find('title'))
            for name in archive.namelist():
                assert 'EnvelopeTurn' not in name
                if name != 'modDesc.xml':
                    assert archive.read(name) == (ROOT / name).read_bytes(), name
            archive.extractall(extracted)
        run('tools/straight-entry/test_entry.py', extracted)
        run('tools/double-pivot/test_loops.py', extracted)
        if committed_source() != revision:
            raise RuntimeError('Source commit changed during release checks')
        # Only the qualified bytes become the downloadable build.
        output.mkdir(parents=True, exist_ok=True)
        version = manifest.findtext('version')
        history = output / 'history' / version
        history.mkdir(parents=True, exist_ok=True)
        archived = history / NAME
        data = candidate.read_bytes()
        if archived.exists() and archived.read_bytes() != data:
            raise RuntimeError('This version already has a different archived ZIP; increment the version')
        receipt = history / 'build.json'
        metadata = {'version': version, 'commit': revision, 'sha256': hashlib.sha256(data).hexdigest()}
        if receipt.exists() and json.loads(receipt.read_text()) != metadata:
            raise RuntimeError('This version is already associated with a different source commit')
        archived.write_bytes(data)
        receipt.write_text(json.dumps(metadata, indent=2) + '\n', encoding='utf-8')
        destination = output / NAME
        candidate.replace(destination)
    checksum = hashlib.sha256(destination.read_bytes()).hexdigest()
    print(f'PASS: {destination}\nCommit: {revision}\nArchive: {archived}\nSHA-256: {checksum}')


if __name__ == '__main__':
    build(Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else ROOT / 'out/main-loop-release')
