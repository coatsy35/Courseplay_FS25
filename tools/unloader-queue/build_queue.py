"""Qualify the automatic operational queue against pinned native CP and engine-boundary tests."""
import argparse
import re
import subprocess
import xml.etree.ElementTree as ET
import build_baseline as release
from build_foundation import SUITES

MODULES = {f'scripts/ai/CpUnloaderQueue{s}.lua'
           for s in ('Policy', 'Geometry', 'World', 'Search', '', 'Manoeuvres', 'Hooks')}
INTEGRATION = {'modDesc.xml'}


def canonical(element):
    return (element.tag, tuple(sorted(element.attrib.items())), (element.text or '').strip(),
            tuple(canonical(child) for child in element))


def check_queue(packager):
    tracked = subprocess.check_output(['git', 'ls-files', '-z'], cwd=release.ROOT).decode().split('\0')
    baseline = subprocess.check_output(['git', 'ls-tree', '-r', '--name-only', '-z', release.BASE],
                                       cwd=release.ROOT).decode().split('\0')
    native = {p for p in baseline if p and packager.is_runtime_file(p)}
    current = {p for p in tracked if p and packager.is_runtime_file(p)}
    if current != native | MODULES:
        raise RuntimeError('Unexpected runtime inventory change')
    subprocess.run(['git', 'diff', '--exit-code', release.BASE, '--', *sorted(native-INTEGRATION)],
                   cwd=release.ROOT, check=True)
    for path in INTEGRATION:
        expected = ET.fromstring(subprocess.check_output(['git', 'show', f'{release.BASE}:{path}'], cwd=release.ROOT))
        actual = ET.parse(release.ROOT/path).getroot()
        removed = []
        for parent in actual.iter():
            for child in list(parent):
                if child.attrib.get('filename') in MODULES:
                    removed.append(child)
                    parent.remove(child)
        if canonical(actual) != canonical(expected):
            raise RuntimeError(f'Unexpected integration change in {path}')
        if path == 'modDesc.xml' and {e.attrib['filename'] for e in removed} != MODULES:
            raise RuntimeError('Queue module load inventory incomplete')
    hooks = (release.ROOT/'scripts/ai/CpUnloaderQueueHooks.lua').read_text()
    methods = set(re.findall(r'function ([UC]):([A-Za-z]+)\(', hooks))
    expected = {('U', name) for name in ('update', 'getDriveData', 'isAllowedToBeCalled', 'call',
        'releaseCombine', 'startUnloadingTrailers', 'onTrailerFull', 'onLastWaypointPassed',
        'onBlockingVehicle', 'delete', 'requestToBackupForReversingCombine')} | {('C', 'findUnloader')}
    if methods != expected:
        raise RuntimeError('Integration hook surface changed')
    print('PASS: native runtime matches main; only reviewed automatic queue hooks added; settings match main', flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('build_number', type=int)
    release.build(parser.parse_args().build_number, qualification=check_queue,
                  suites=SUITES+('unloader-queue/test_runtime.py',),
                  stage='queue-operational-candidate-requires-in-game-validation')
