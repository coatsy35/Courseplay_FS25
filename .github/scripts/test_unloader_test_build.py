"""A failed coordinator release must preserve the user's previous installable test ZIP."""

import contextlib
import importlib.util
import io
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("unloader_test_build", ROOT / "tools/unloader-coordinator/build_test.py")
builder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(builder)


class UnloaderReleaseTests(unittest.TestCase):
    def assert_failed_release_preserves_previous_zip(self, packaged):
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory) / "FS25_Courseplay_UnloaderCoordinatorTest.zip"
            previous = b"previous verified test build"
            destination.write_bytes(previous)
            checked = []

            def check_lua(runtime):
                checked.append(runtime)
                if (runtime != ROOT) == packaged:
                    raise RuntimeError("regression failed")

            # Packaging and byte/integrity checks are real; replace costly runtime suites with a controlled
            # failure at the selected gate so this test cannot recursively launch the release test runner.
            with patch.object(builder, "OUTPUT", destination), patch.object(builder, "run"), \
                    patch.object(builder, "check_profiles"), patch.object(builder, "check_lua", check_lua), \
                    contextlib.redirect_stdout(io.StringIO()):
                with self.assertRaisesRegex(RuntimeError, "regression failed"):
                    builder.build(2962)
            self.assertEqual(destination.read_bytes(), previous)
            self.assertEqual(len(checked), 2 if packaged else 1)
            self.assertFalse(destination.with_suffix(".zip.tmp").exists())

    def test_failed_source_regression_keeps_previous_zip(self):
        self.assert_failed_release_preserves_previous_zip(False)

    def test_failed_packaged_regression_keeps_previous_zip(self):
        self.assert_failed_release_preserves_previous_zip(True)


if __name__ == "__main__":
    unittest.main()
