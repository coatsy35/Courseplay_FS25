"""Build a distinctly named envelope-turn test mod from tracked runtime files.

The shared release builder remains unchanged. Only the packaged manifest title,
version, description and experimental setting default differ from source;
all Lua is packaged verbatim.
No live mod or implement-directory test archive is overwritten.
"""
import argparse
import hashlib
import importlib.util
import re
from pathlib import Path
import tempfile
import xml.etree.ElementTree as ET
from zipfile import ZipFile

ROOT = Path(__file__).resolve().parents[2]
ZIP_NAME = 'FS25_Courseplay_EnvelopeTurnsTest.zip'
TEST_VERSION = re.search(r"EnvelopeCourseTurn.TEST_VERSION = '([0-9.]+)'",
    (ROOT/'scripts/ai/turns/EnvelopeCourseTurn.lua').read_text(encoding='utf-8')).group(1)
TEST_TITLE = f'CoursePlay - Envelope Turns Test v{TEST_VERSION}'
# Separate numeric mod version also appears in GIANTS' available-mod log.
MOD_VERSION = '8.1.0.' + str(100 + int(TEST_VERSION.split('.')[-1]))
spec = importlib.util.spec_from_file_location('cp_build_mod', ROOT / '.github/scripts/build_mod.py')
builder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(builder)


def test_manifest(data):
    root = ET.fromstring(data)
    for title in root.findall('./title/*'):
        title.text = (title.text or 'CoursePlay') + f' - Envelope Turns Test v{TEST_VERSION}'
    root.find('version').text = MOD_VERSION
    description = root.find('./description/en')
    if description is not None:
        description.text = ('Experimental envelope-aligned row turns. Enable only this Courseplay version '
                            'for the test save. See CP implement settings and [CP envelope] in log.txt.\n\n'
                            + (description.text or ''))
    return ET.tostring(root, encoding='utf-8', xml_declaration=True)


def test_settings(data):
    root = ET.fromstring(data)
    setting = root.find(".//Setting[@name='envelopeAlignedTurns']")
    if setting is None:
        raise ValueError('Envelope turn setting is missing; refusing to label a stock build as the test')
    setting.set('defaultBool', 'true')
    return ET.tostring(root, encoding='utf-8', xml_declaration=True)


def build(output):
    output = Path(output)
    if output.name != ZIP_NAME:
        raise ValueError(f'Use the stable test mod identity {ZIP_NAME}')
    output.parent.mkdir(parents=True, exist_ok=True)
    # Both temporary archives stay outside the install directory. The completed
    # ZIP replaces only this test filename, after all consistency checks pass.
    with tempfile.TemporaryDirectory(dir=output.parent, prefix='envelope-build-') as temporary:
        raw, ready = Path(temporary)/'source.zip', Path(temporary)/ZIP_NAME
        version = builder.build_mod(ROOT, raw)
        with ZipFile(raw) as source, ZipFile(ready, 'w') as result:
            for entry in source.infolist():
                data = source.read(entry.filename)
                if entry.filename == 'modDesc.xml':
                    data = test_manifest(data)
                elif entry.filename == 'config/VehicleSettingsSetup.xml':
                    data = test_settings(data)
                result.writestr(entry, data)
        with ZipFile(ready) as result:
            assert result.testzip() is None
            assert not any('implementprofile' in name.lower() for name in result.namelist()), 'Directory code must remain on its separate branch'
            manifest = ET.fromstring(result.read('modDesc.xml'))
            assert manifest.findtext('title/en') == TEST_TITLE
            assert manifest.findtext('version') == MOD_VERSION
            for name in ('EnvelopeTurnPlanner', 'EnvelopeTurnGeometry', 'EnvelopeCourseTurn', 'EnvelopeKTurn'):
                path = f'scripts/ai/turns/{name}.lua'
                assert result.read(path) == (ROOT/path).read_bytes()
            for entry in manifest.findall('./extraSourceFiles/sourceFile'):
                assert entry.get('filename') in result.namelist(), entry.get('filename')
            for name in result.namelist():
                if name.endswith('.xml'):
                    ET.fromstring(result.read(name))
        # A byte-correct archive is not a working vehicle. Qualify this exact
        # candidate before replacing the user's test ZIP. The report remains
        # available even when qualification fails; no bypass flag is provided.
        from audit_envelope_build import audit
        report_path=output.with_suffix('.qualification.json')
        report=audit(ready,report_path)
        if not report.get('qualified'):
            raise RuntimeError(f'Envelope build failed execution qualification; existing ZIP unchanged. See {report_path}')
        ready.replace(output)
    checksum = hashlib.sha256(output.read_bytes()).hexdigest()
    return {'file': str(output), 'test_version': TEST_VERSION, 'version': MOD_VERSION, 'source_version': version, 'sha256': checksum}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=ROOT/'dist/envelope-turns'/ZIP_NAME)
    args = parser.parse_args()
    print(build(args.output))
