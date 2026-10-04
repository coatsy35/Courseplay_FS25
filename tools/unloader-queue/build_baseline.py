"""Qualify the clean main baseline under the established unloader test identity."""
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
BASE = "8b707fa907c236b9b1b98a5608267975c3c764d3"
NAME = "FS25_Courseplay_UnloaderCoordinatorTest.zip"
TITLE = "CoursePlay - Unloader Coordinator Test"
RUNTIME_PATHS = ("Courseplay.lua", "modDesc.xml", "icon_courseplay.dds", "LICENSE",
                 "config", "img", "scripts", "translations")
DESTINATION = ROOT.parents[1] / "dist/unloader-coordinator"
SUITES = ("course-headland-loop/test_setting.py", "combine-pocket/test_pocket.py",
          "straight-entry/test_entry.py", "double-pivot/test_loops.py")


def run(*args, cwd=ROOT):
    subprocess.run([sys.executable, "-B", *map(str, args)], cwd=cwd, check=True)


def revision():
    status = subprocess.check_output(
        ["git", "status", "--porcelain", "--untracked-files=all"], cwd=ROOT, text=True)
    if status.strip():
        raise RuntimeError("Commit the restart before building:\n" + status)
    return subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()


def check_main_parity(packager):
    subprocess.run(["git", "diff", "--exit-code", BASE, "--", *RUNTIME_PATHS],
                   cwd=ROOT, check=True)
    current = subprocess.check_output(["git", "ls-files", "-z"], cwd=ROOT).decode().split("\0")
    baseline = subprocess.check_output(
        ["git", "ls-tree", "-r", "--name-only", "-z", BASE], cwd=ROOT).decode().split("\0")
    if {p for p in current if p and packager.is_runtime_file(p)} != {
            p for p in baseline if p and packager.is_runtime_file(p)}:
        raise RuntimeError("Runtime file inventory differs from main")
    print("PASS: every runtime file matches pinned main; no coordinator code", flush=True)


def check_lua(runtime):
    from lupa.lua51 import LuaRuntime
    compiler = LuaRuntime().eval("function(source) assert(loadstring(source)) end")
    files = list((runtime / "scripts").rglob("*.lua")) + [runtime / "Courseplay.lua"]
    for path in files:
        compiler(path.read_text(encoding="utf-8-sig"))
    print(f"PASS: {len(files)} Lua files compile: {runtime}", flush=True)


def profiles(runtime):
    run("-c", "from lupa.lua51 import LuaRuntime; "
        "LuaRuntime().execute(open('ImplementProfileTest.lua', encoding='utf-8-sig').read())",
        cwd=runtime / "scripts/test")


def build(number, *, qualification=check_main_parity, suites=SUITES,
          stage="main-baseline-no-queue-feature"):
    if number <= 2989:
        raise ValueError("Restart builds must follow the archived build 2989")
    commit = revision()
    version = f"8.1.0.{number}"
    history = DESTINATION / "history" / version
    if history.exists():
        raise RuntimeError("This numbered release already exists; use a new number")
    spec = importlib.util.spec_from_file_location("package_mod", ROOT / ".github/scripts/build_mod.py")
    packager = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(packager)
    qualification(packager)
    subprocess.run(["git", "diff", "--check", BASE], cwd=ROOT, check=True)
    run("-m", "unittest", "discover", "-s", ".github/scripts", "-p", "test_*.py", "-q")
    check_lua(ROOT)
    profiles(ROOT)
    for suite in suites:
        run(ROOT / "tools" / suite, "-q")
    staging = ROOT / "out"
    staging.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="unloader-main-baseline-", dir=staging) as temporary:
        temporary = Path(temporary)
        raw, repeat = temporary / "source.zip", temporary / "repeat.zip"
        packager.build_mod(ROOT, raw)
        packager.build_mod(ROOT, repeat)
        if raw.read_bytes() != repeat.read_bytes():
            raise RuntimeError("Package is not reproducible")
        candidate = temporary / NAME
        with ZipFile(raw) as original, ZipFile(candidate, "w") as archive:
            runtime_names = original.namelist()
            original_manifest = original.read("modDesc.xml")
            manifest = ET.fromstring(original_manifest)
            title = "<title>" + "".join(f"<{e.tag}>{TITLE}</{e.tag}>"
                                        for e in manifest.find("title")) + "</title>"
            replacement, count = re.subn(rb"<title>.*?</title>", title.encode(),
                                         original_manifest, count=1, flags=re.S)
            if count != 1:
                raise RuntimeError("Test title replacement failed")
            replacement, count = re.subn(rb"<version>.*?</version>",
                f"<version>{version}</version>".encode(), replacement, count=1)
            if count != 1:
                raise RuntimeError("Test version replacement failed")
            for info in original.infolist():
                archive.writestr(info, replacement if info.filename == "modDesc.xml"
                                 else original.read(info.filename))
        extracted = temporary / "extracted"
        with ZipFile(candidate) as archive:
            if archive.testzip() is not None:
                raise RuntimeError("ZIP integrity check failed")
            if archive.namelist() != runtime_names:
                raise RuntimeError("Runtime inventory changed during packaging")
            packaged_manifest = ET.fromstring(archive.read("modDesc.xml"))
            if packaged_manifest.findtext("version") != version or any(
                    e.text != TITLE for e in packaged_manifest.find("title")):
                raise RuntimeError("Incorrect test identity")
            for name in archive.namelist():
                if not packager.is_runtime_file(name):
                    raise RuntimeError(f"Development file included: {name}")
                if name != "modDesc.xml" and archive.read(name) != (ROOT / name).read_bytes():
                    raise RuntimeError(f"Packaged file differs from main source: {name}")
                if name.endswith(".xml"):
                    ET.fromstring(archive.read(name))
            archive.extractall(extracted)
        check_lua(extracted)
        for suite in suites:
            run(ROOT / "tools" / suite, extracted, "-q")
        (extracted / "scripts/test").mkdir()
        for name in ("luaunit.lua", "ImplementProfileTest.lua"):
            shutil.copy2(ROOT / "scripts/test" / name, extracted / "scripts/test" / name)
        profiles(extracted)
        if revision() != commit:
            raise RuntimeError("Source changed during qualification")
        qualification(packager)
        data = candidate.read_bytes()
        metadata = {"version": version, "commit": commit, "base": BASE,
                    "stage": stage,
                    "sha256": hashlib.sha256(data).hexdigest()}
        history.mkdir(parents=True)
        (history / NAME).write_bytes(data)
        (history / "build.json").write_text(json.dumps(metadata, indent=2) + "\n", encoding="utf-8")
        latest = DESTINATION / NAME
        staged = latest.with_suffix(".zip.tmp")
        staged.write_bytes(data)
        staged.replace(latest)
        print(f"PASS: {stage} {version}\n{history / NAME}\nSHA-256: {metadata['sha256']}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("build_number", type=int)
    build(parser.parse_args().build_number)
