"""Build a numbered, installable unloader-coordinator test ZIP without changing the live mod identity."""

import argparse
import hashlib
import importlib.util
from pathlib import Path
import re
import tempfile
from zipfile import ZipFile


ROOT = Path(__file__).resolve().parents[2]
OUTPUT = ROOT.parents[1] / "dist/unloader-coordinator/FS25_Courseplay_UnloaderCoordinatorTest.zip"
TITLE_SUFFIX = " - Unloader Coordinator Test"


def build(build_number: int) -> Path:
    spec = importlib.util.spec_from_file_location("build_mod", ROOT / ".github/scripts/build_mod.py")
    packager = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(packager)
    with tempfile.TemporaryDirectory() as directory:
        raw = Path(directory) / "FS25_Courseplay.zip"
        packager.build_mod(ROOT, raw)
        with ZipFile(raw) as source:
            manifest = source.read("modDesc.xml").decode("utf-8")
            manifest, count = re.subn(r"<version>[^<]+</version>",
                    f"<version>8.1.0.{build_number}</version>", manifest, count=1)
            if count != 1:
                raise ValueError("Exactly one manifest version is required")
            title, count = re.subn(r"(<title>)(.*?)(</title>)",
                    lambda match: match[1] + re.sub(r"(<\w+>)([^<]+)(</\w+>)",
                            lambda name: name[1] + name[2] + TITLE_SUFFIX + name[3], match[2]) + match[3],
                    manifest, count=1, flags=re.S)
            if count != 1 or "<en>CoursePlay - Unloader Coordinator Test</en>" not in title:
                raise ValueError("Test title could not be verified")
            OUTPUT.parent.mkdir(parents=True, exist_ok=True)
            with ZipFile(OUTPUT, "w") as target:
                for item in source.infolist():
                    target.writestr(item, title.encode("utf-8") if item.filename == "modDesc.xml" else source.read(item))
    with ZipFile(OUTPUT) as archive:
        if archive.testzip() is not None:
            raise ValueError("Test ZIP failed integrity verification")
        if archive.read("modDesc.xml").count(f"<version>8.1.0.{build_number}</version>".encode()) != 1:
            raise ValueError("Numbered test version missing from ZIP")
    print(f"{OUTPUT}: 8.1.0.{build_number}, SHA-256 {hashlib.sha256(OUTPUT.read_bytes()).hexdigest()}")
    return OUTPUT


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("build_number", type=int)
    build(parser.parse_args().build_number)
