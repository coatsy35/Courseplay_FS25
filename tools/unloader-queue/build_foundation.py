"""Qualify unchanged main plus inactive queue foundations with the common release gates."""
import argparse
import subprocess
import xml.etree.ElementTree as ET
import build_baseline as release

FOUNDATION = {"scripts/ai/CpUnloaderQueuePolicy.lua", "scripts/ai/CpUnloaderQueueGeometry.lua"}
SUITES = release.SUITES + ("unloader-queue/test_policy.py", "unloader-queue/test_geometry.py",
                          "unloader-queue/test_native_contract.py")


def check_foundation(packager):
    current = subprocess.check_output(["git", "ls-files", "-z"], cwd=release.ROOT).decode().split("\0")
    baseline = subprocess.check_output(
        ["git", "ls-tree", "-r", "--name-only", "-z", release.BASE], cwd=release.ROOT).decode().split("\0")
    baseline_runtime = {p for p in baseline if p and packager.is_runtime_file(p)}
    if {p for p in current if p and packager.is_runtime_file(p)} != baseline_runtime | FOUNDATION:
        raise RuntimeError("Unexpected runtime additions or removals")
    subprocess.run(["git", "diff", "--exit-code", release.BASE, "--", *sorted(baseline_runtime)],
                   cwd=release.ROOT, check=True)
    manifest = ET.parse(release.ROOT / 'modDesc.xml').getroot()
    loaded = {e.attrib.get('filename') for e in manifest.iter('sourceFile')}
    if loaded & FOUNDATION:
        raise RuntimeError("Foundation build must not activate queue components")
    print("PASS: all existing runtime files match pinned main; queue components inactive", flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("build_number", type=int)
    release.build(parser.parse_args().build_number, qualification=check_foundation,
                  suites=SUITES, stage="queue-foundation-no-vehicle-control")
