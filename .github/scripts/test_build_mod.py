"""Regression tests for the shared development/release packager."""

from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from zipfile import ZipFile

from build_mod import ZIP_NAME, build_mod, is_runtime_file


class BuildModTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.files = {
            "modDesc.xml": '<modDesc><version>8.1.0.3</version><extraSourceFiles>'
                           '<sourceFile filename="scripts/worker.lua"/>'
                           '</extraSourceFiles></modDesc>',
            "Courseplay.lua": "-- entry point",
            "icon_courseplay.dds": "icon",
            "LICENSE": "licence",
            "scripts/worker.lua": "-- worker",
            "config/settings.xml": "<settings/>",
            "img/hud.dds": "image",
            "translations/en.xml": "<texts/>",
            "scripts/test/Example.lua": "-- test",
            "scripts/courseGenerator/test/Example.lua": "-- nested test",
            "scripts/reloadAI.bat": "development helper",
            ".github/workflows/build.yml": "workflow",
            "README.md": "readme",
        }
        for name, content in self.files.items():
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content, encoding="utf-8")
        tracked = ("\0".join(self.files) + "\0").encode()
        mock = patch("build_mod.subprocess.check_output", return_value=tracked)
        mock.start()
        self.addCleanup(mock.stop)
        self.output = self.root / "dist" / ZIP_NAME

    def test_installable_zip_contains_runtime_files_and_licence(self):
        self.assertEqual(build_mod(self.root, self.output), "8.1.0.3")
        with ZipFile(self.output) as archive:
            self.assertIsNone(archive.testzip())
            self.assertEqual(set(archive.namelist()), {
                "modDesc.xml", "Courseplay.lua", "icon_courseplay.dds", "LICENSE",
                "scripts/worker.lua", "config/settings.xml", "img/hud.dds", "translations/en.xml",
            })
            self.assertEqual(archive.read("scripts/worker.lua"), b"-- worker")

    def test_identical_sources_produce_identical_archives(self):
        build_mod(self.root, self.output)
        first = self.output.read_bytes()
        build_mod(self.root, self.output)
        self.assertEqual(first, self.output.read_bytes())

    def test_untracked_files_are_not_packaged(self):
        (self.root / "scripts" / "private.lua").write_text("not tracked")
        build_mod(self.root, self.output)
        with ZipFile(self.output) as archive:
            self.assertNotIn("scripts/private.lua", archive.namelist())

    def test_missing_manifest_script_fails_before_writing_zip(self):
        path = self.root / "modDesc.xml"
        path.write_text(path.read_text().replace("worker.lua", "missing.lua"))
        with self.assertRaisesRegex(ValueError, "Manifest script missing"):
            build_mod(self.root, self.output)
        self.assertFalse(self.output.exists())

    def test_invalid_version_is_rejected(self):
        path = self.root / "modDesc.xml"
        path.write_text(path.read_text().replace("8.1.0.3", "not-a-version"))
        with self.assertRaisesRegex(ValueError, "four-part numeric version"):
            build_mod(self.root, self.output)

    def test_development_files_excluded_at_every_depth(self):
        for name in ["scripts/test/a.lua", "scripts/pathfinder/test/a.lua",
                     "scripts/.secret", "scripts/__pycache__/a.pyc", "scripts/tool.ps1"]:
            with self.subTest(name=name):
                self.assertFalse(is_runtime_file(name))


if __name__ == "__main__":
    unittest.main()
