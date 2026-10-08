"""Qualify the automatic operational queue against pinned native CP and engine-boundary tests."""
import argparse
import hashlib
import re
import subprocess
import xml.etree.ElementTree as ET
import build_baseline as release
from build_foundation import SUITES

MODULES = {f'scripts/ai/CpUnloaderQueue{s}.lua'
           for s in ('Policy', 'Geometry', 'World', 'Search', '', 'Manoeuvres', 'Hooks')}
INTEGRATION = {'modDesc.xml'}
STEERING = 'scripts/ai/strategies/AIDriveStrategyCombineCourse.lua'
TURNS = 'scripts/ai/turns/AITurn.lua'
CONNECTORS = 'scripts/ai/strategies/AIDriveStrategyFieldWorkCourse.lua'


def check_harvester_turns():
    actual = (release.ROOT/TURNS).read_text(encoding='utf-8')
    expected = subprocess.check_output(['git', 'show', f'{release.BASE}:{TURNS}'],
                                       cwd=release.ROOT).decode().replace('\r\n', '\n')
    pattern = r'-- BEGIN stock harvester turn boundary selection\n.*?-- END stock harvester turn boundary selection\n\n'
    additions = re.findall(pattern, actual, re.S)
    if len(additions) != 1 or hashlib.sha256(additions[0].encode()).hexdigest() != (
            'fff3f29dfb84f3476fcce9a7e572e00ccef09576e3345e097d147e46ab715d86'):
        raise RuntimeError('Unreviewed harvester turn boundary selection')
    for args, count in [('self.vehicle, self.workWidth', 2), ('vehicle, turnContext.workWidth', 1)]:
        original = f'FieldworkBoundary.forVehicle({args})'
        if expected.count(original) != count:
            raise RuntimeError('Unexpected native turn boundary call inventory')
        expected = expected.replace(original, f'getTurnBoundary({args})')
    if actual.replace(additions[0], '', 1) != expected:
        raise RuntimeError('Turn behaviour changed outside reviewed harvester corridor correction')


def check_steering():
    # The user's 5 October steering request is an explicit, isolated exception.
    # Require the reviewed addition AND byte-equivalent original method bodies;
    # do not exempt the combine strategy from baseline qualification wholesale.
    actual = (release.ROOT/STEERING).read_text(encoding='utf-8')
    expected = subprocess.check_output(['git', 'show', f'{release.BASE}:{STEERING}'],
                                       cwd=release.ROOT).decode().replace('\r\n', '\n')
    pattern = r'-- BEGIN authorised approach lookahead adjustment\n.*?-- END authorised approach lookahead adjustment\n\n'
    additions = re.findall(pattern, actual, re.S)
    if len(additions) != 1 or hashlib.sha256(additions[0].encode()).hexdigest() != (
            '4737ff46ea51b2db480124870e93d0ffbec8b0befe3b81687e4f929bfc325174'):
        raise RuntimeError('Unreviewed approach steering adjustment')
    if actual.replace(additions[0], '', 1) != expected:
        raise RuntimeError('Native combine strategy changed outside authorised steering addition')


def check_connector_entry():
    actual = (release.ROOT/CONNECTORS).read_text(encoding='utf-8')
    expected = subprocess.check_output(['git', 'show', f'{release.BASE}:{CONNECTORS}'],
                                       cwd=release.ROOT).decode().replace('\r\n', '\n')
    pattern = r' *-- BEGIN authorised harvester connector entry\n.*? *-- END authorised harvester connector entry\n'
    additions = re.findall(pattern, actual, re.S)
    if len(additions) != 3 or hashlib.sha256(''.join(additions).encode()).hexdigest() != (
            '303787a683a82e01ce4eef9085a6cec33cabbf92efc5717ee881cfac58f25d90'):
        raise RuntimeError('Unreviewed harvester connector entry change')
    if re.sub(pattern, '', actual, flags=re.S) != expected:
        raise RuntimeError('Native fieldwork changed outside authorised connector entry')


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
    subprocess.run(['git', 'diff', '--exit-code', release.BASE, '--', *sorted(native-INTEGRATION-{STEERING,TURNS,CONNECTORS})],
                   cwd=release.ROOT, check=True)
    check_steering()
    check_harvester_turns()
    check_connector_entry()
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
        'startUnloadingTrailers', 'onLastWaypointPassed',
        'onBlockingVehicle', 'delete', 'requestToBackupForReversingCombine', 'getAllTrailersFull')} | {('C', 'findUnloader'), ('C', 'onBlockingVehicle')}
    if methods != expected:
        raise RuntimeError('Integration hook surface changed')
    print('PASS: native runtime parity outside reviewed connector entry, steering/corridor corrections and queue hooks; settings qualified', flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('build_number', type=int)
    release.build(parser.parse_args().build_number, qualification=check_queue,
                  suites=SUITES+('unloader-queue/test_runtime.py', 'unloader-queue/test_lookahead.py',
                                'unloader-queue/test_harvester_turns.py',
                                'unloader-queue/test_native_connectors.py',
                                'unloader-queue/test_native_departure.py', 'unloader-queue/test_yield.py',
                                'unloader-queue/test_departure_threshold.py',
                                'unloader-queue/test_harvester_bypass.py'),
                  stage='queue-operational-candidate-requires-in-game-validation')
