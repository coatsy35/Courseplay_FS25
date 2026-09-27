"""Build a numbered, installable unloader-coordinator test ZIP without changing the live mod identity."""

import argparse
import hashlib
import importlib.util
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
from zipfile import ZipFile


ROOT = Path(__file__).resolve().parents[2]
OUTPUT = ROOT.parents[1] / "dist/unloader-coordinator/FS25_Courseplay_UnloaderCoordinatorTest.zip"
TITLE_SUFFIX = " - Unloader Coordinator Test"
LUA_REGRESSIONS = (
    "CpUtilStateIsolationTest", "FieldworkConnectingPathTest", "FieldWorkerTurnClearanceTest",
    "FieldworkBoundarySegmentTest", "PocketCoursePlanningTest", "UnloaderRecoveryTest",
    "UnloaderLifecycleTest", "UnloaderGridRoutingTest", "UnloaderCoordinatorTest",
    "UnloaderConnectorClearanceTest",
    "PathfinderTurnTravelTest",
)


def run(*args, cwd=ROOT):
    subprocess.run([sys.executable, "-B", *map(str, args)], cwd=cwd, check=True)


def check_lua(runtime):
    from lupa.lua51 import LuaRuntime

    compiler = LuaRuntime().eval("function(source) assert(loadstring(source)) end")
    scripts = list((runtime / "scripts").rglob("*.lua"))
    for path in scripts:
        compiler(path.read_text(encoding="utf-8-sig"))
    # Tests load production modules through dofile. Use the candidate as their working directory,
    # including when exercising extracted ZIP bytes; keep the test harness outside the mod archive.
    run("-c", "from pathlib import Path; from lupa.lua51 import LuaRuntime; "
        "[LuaRuntime().execute(Path(p).read_text(encoding='utf-8-sig')) for p in "
        + repr([str(ROOT / "scripts/test" / f"{name}.lua") for name in LUA_REGRESSIONS]) + "]",
        cwd=runtime)
    print(f"Lua 5.1: {len(scripts)} files compiled; {len(LUA_REGRESSIONS)} regression suites passed", flush=True)


def check_profiles(runtime):
    run("-c", "from lupa.lua51 import LuaRuntime; "
        "LuaRuntime().execute(open('ImplementProfileTest.lua', encoding='utf-8-sig').read())",
        cwd=runtime / "scripts/test")


def build(build_number: int) -> Path:
    # Publish only after the source and the actual packaged runtime pass the release gates.
    run("-m", "unittest", "discover", "-s", ".github/scripts", "-p", "test_*.py", "-q")
    check_lua(ROOT)
    check_profiles(ROOT)
    spec = importlib.util.spec_from_file_location("build_mod", ROOT / ".github/scripts/build_mod.py")
    packager = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(packager)
    with tempfile.TemporaryDirectory() as directory:
        temporary = Path(directory)
        raw = temporary / "FS25_Courseplay.zip"
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
            candidate = temporary / OUTPUT.name
            with ZipFile(candidate, "w") as target:
                for item in source.infolist():
                    target.writestr(item, title.encode("utf-8") if item.filename == "modDesc.xml" else source.read(item))
        extracted = temporary / "runtime"
        with ZipFile(candidate) as archive:
            if archive.testzip() is not None:
                raise ValueError("Test ZIP failed integrity verification")
            if archive.read("modDesc.xml").count(f"<version>8.1.0.{build_number}</version>".encode()) != 1:
                raise ValueError("Numbered test version missing from ZIP")
            for name in archive.namelist():
                if not packager.is_runtime_file(name):
                    raise ValueError(f"Development file in test ZIP: {name}")
                if name != "modDesc.xml" and archive.read(name) != (ROOT / name).read_bytes():
                    raise ValueError(f"Packaged file differs from source: {name}")
                if name.endswith(".xml"):
                    ET.fromstring(archive.read(name))
            archive.extractall(extracted)
        check_lua(extracted)
        (extracted / "scripts/test").mkdir()
        for name in ("luaunit.lua", "ImplementProfileTest.lua"):
            shutil.copy2(ROOT / "scripts/test" / name, extracted / "scripts/test" / name)
        check_profiles(extracted)
        for suite in ("course-headland-loop/test_setting.py", "combine-pocket/test_pocket.py",
                      "straight-entry/test_entry.py", "double-pivot/test_loops.py"):
            run(ROOT / "tools" / suite, extracted, "-q")
        # Keep the previous installable build available if any validation above fails.
        OUTPUT.parent.mkdir(parents=True, exist_ok=True)
        staged_output = OUTPUT.with_suffix(".zip.tmp")
        shutil.copyfile(candidate, staged_output)
        staged_output.replace(OUTPUT)
    print(f"{OUTPUT}: 8.1.0.{build_number}, SHA-256 {hashlib.sha256(OUTPUT.read_bytes()).hexdigest()}")
    return OUTPUT


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("build_number", type=int)
    build(parser.parse_args().build_number)
