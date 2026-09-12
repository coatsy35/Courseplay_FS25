"""Build the installable Courseplay ZIP from tracked runtime files."""

import argparse
import hashlib
import os
from pathlib import Path, PurePosixPath
import re
import subprocess
import xml.etree.ElementTree as ET
from zipfile import ZIP_DEFLATED, ZipFile, ZipInfo


ZIP_NAME = "FS25_Courseplay.zip"
ROOT_FILES = {"Courseplay.lua", "modDesc.xml", "icon_courseplay.dds", "LICENSE"}
RUNTIME_DIRECTORIES = {"config", "img", "scripts", "translations"}


def is_runtime_file(name):
    path = PurePosixPath(name)
    if any(part.startswith(".") or part in {"test", "tests", "__pycache__"} for part in path.parts):
        return False
    if path.suffix.lower() in {".bat", ".md", ".py", ".pyc", ".ps1", ".sh"}:
        return False
    return name in ROOT_FILES or path.parts[0] in RUNTIME_DIRECTORIES


def build_mod(source, output):
    tracked = subprocess.check_output(["git", "ls-files", "-z"], cwd=source).decode("utf-8").split("\0")
    names = sorted(name for name in tracked if name and is_runtime_file(name))
    missing = ROOT_FILES - set(names)
    if missing:
        raise ValueError(f"Missing required tracked files: {', '.join(sorted(missing))}")

    manifest = ET.parse(source / "modDesc.xml").getroot()
    version = (manifest.findtext("version") or "").strip()
    if not re.fullmatch(r"[0-9]+(?:\.[0-9]+){3}", version):
        raise ValueError("modDesc.xml must contain a four-part numeric version")
    for entry in manifest.findall("./extraSourceFiles/sourceFile"):
        name = entry.attrib["filename"]
        if name not in names:
            raise ValueError(f"Manifest script missing from package: {name}")
    for name in names:
        if (source / name).is_symlink() or not (source / name).is_file():
            raise ValueError(f"Package entry must be a regular file: {name}")

    output.parent.mkdir(parents=True, exist_ok=True)
    with ZipFile(output, "w", compression=ZIP_DEFLATED) as archive:
        for name in names:
            # Fixed timestamps and permissions make identical source builds reproducible.
            info = ZipInfo(name)
            info.create_system = 3
            info.external_attr = 0o100644 << 16
            info.compress_type = ZIP_DEFLATED
            archive.writestr(info, (source / name).read_bytes())
    with ZipFile(output) as archive:
        if archive.testzip() is not None:
            raise ValueError("ZIP integrity check failed")
    return version


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=Path("dist") / ZIP_NAME)
    args = parser.parse_args()
    source = Path(__file__).resolve().parents[2]
    version = build_mod(source, args.output)
    checksum = hashlib.sha256(args.output.read_bytes()).hexdigest()
    print(f"Built {args.output}: version {version}, SHA-256 {checksum}")
    if os.environ.get("GITHUB_OUTPUT"):
        with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as outputs:
            outputs.write(f"version={version}\n")


if __name__ == "__main__":
    main()
