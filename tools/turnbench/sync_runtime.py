"""Pin the bench to the same Lua files as an envelope test build.

Usage: python sync_runtime.py --source <envelope-checkout>
The bench is portable after synchronisation; it never reads a moving sibling
checkout while running. Shared CP dependencies must match before synchronising.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[2]
FOLDER = Path(__file__).with_name('runtime')
NAMES = ('EnvelopeTurnPlanner', 'EnvelopeTurnGeometry', 'EnvelopeCourseTurn')
DEPENDENCIES = ('scripts/ai/turns/AITurn.lua', 'scripts/ai/turns/WorkStartHandler.lua',
                'scripts/ai/util/AIUtil.lua', 'scripts/ai/PurePursuitController.lua',
                'scripts/Course.lua', 'scripts/Waypoint.lua', 'scripts/pathfinder/Dubins.lua')


def digest(path):
    return hashlib.sha256(path.read_text(encoding='utf-8-sig').encode()).hexdigest()


def validate():
    manifest = json.loads((FOLDER/'manifest.json').read_text())
    for name, expected in manifest['files'].items():
        if digest(FOLDER/name) != expected:
            raise ValueError('Envelope runtime snapshot changed: run sync_runtime.py from the test-mod checkout')
    for name, expected in manifest['dependencies'].items():
        if digest(ROOT/name) != expected:
            raise ValueError('Shared CP dependency differs from envelope build: '+name)
    return manifest


def synchronise(source):
    dependencies = {}
    for name in DEPENDENCIES:
        expected = digest(source/name)
        if digest(ROOT/name) != expected:
            raise ValueError('Update shared CP dependency before synchronising: '+name)
        dependencies[name] = expected
    files = {}
    for name in NAMES:
        text = (source/'scripts/ai/turns'/(name+'.lua')).read_text(encoding='utf-8-sig')
        target = FOLDER/(name+'.lua')
        target.write_text(text, encoding='utf-8', newline='\n')
        files[target.name] = digest(target)
    version = re.search(r"TEST_VERSION = '([^']+)'",(FOLDER/'EnvelopeCourseTurn.lua').read_text())[1]
    revision = subprocess.check_output(['git','-C',str(source),'rev-parse','HEAD'],text=True).strip()
    (FOLDER/'manifest.json').write_text(json.dumps(dict(version=version,revision=revision,
        files=files,dependencies=dependencies),indent=2)+'\n')


if __name__ == '__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source',type=Path,required=True)
    synchronise(parser.parse_args().source)
