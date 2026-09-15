"""Build the standalone capture mod without altering a Courseplay package or installing it."""
from pathlib import Path
import argparse
import hashlib
import json
import zipfile
import xml.etree.ElementTree as ET

ROOT=Path(__file__).resolve().parents[2]
SOURCE=Path(__file__).parent/'mod'
OUTPUT=ROOT/'dist'/'geometry-capture'/'FS25_VehicleGeometryCapture.zip'


def build(output=OUTPUT):
    descriptor=ET.parse(SOURCE/'modDesc.xml').getroot()
    names=['modDesc.xml']+[node.attrib['filename'] for node in descriptor.findall('./extraSourceFiles/sourceFile')]
    files={name:(SOURCE/name).read_bytes() for name in names}
    files['icon.dds']=(ROOT/'icon_courseplay.dds').read_bytes()
    files['README.txt']=(SOURCE.parent/'README.md').read_bytes()
    assert files['icon.dds'].startswith(b'DDS ')
    output.parent.mkdir(parents=True,exist_ok=True)
    temporary=output.with_suffix('.zip.tmp')
    with zipfile.ZipFile(temporary,'w',compression=zipfile.ZIP_DEFLATED) as archive:
        for name,data in sorted(files.items()):
            info=zipfile.ZipInfo(name,date_time=(2026,9,13,0,0,0))
            info.compress_type=zipfile.ZIP_DEFLATED
            archive.writestr(info,data)
    with zipfile.ZipFile(temporary) as archive:
        assert archive.testzip() is None
        assert set(archive.namelist())==set(files)
    temporary.replace(output)
    manifest={name:hashlib.sha256(data).hexdigest() for name,data in files.items()}
    manifest['archiveSha256']=hashlib.sha256(output.read_bytes()).hexdigest()
    output.with_suffix('.manifest.json').write_text(json.dumps(manifest,indent=2),encoding='utf-8')
    print(output)


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output',type=Path,default=OUTPUT)
    build(parser.parse_args().output)
