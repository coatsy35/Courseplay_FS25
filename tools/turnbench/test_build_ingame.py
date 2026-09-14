"""Package identity, opt-in isolation and Lua 5.1 syntax for the test build."""
from pathlib import Path
import unittest
import xml.etree.ElementTree as ET
from lupa.lua51 import LuaRuntime
from build_ingame_test import ROOT, ZIP_NAME, TEST_TITLE, MOD_VERSION, build, test_manifest, test_settings


class EnvelopePackageTests(unittest.TestCase):
    def test_distinct_title_and_default_do_not_change_sources(self):
        manifest = (ROOT/'modDesc.xml').read_bytes()
        settings = (ROOT/'config/VehicleSettingsSetup.xml').read_bytes()
        patched = ET.fromstring(test_manifest(manifest))
        self.assertEqual(patched.findtext('title/en'), TEST_TITLE)
        self.assertEqual(patched.findtext('version'), MOD_VERSION)
        self.assertEqual(ET.fromstring(manifest).findtext('title/en'), 'CoursePlay')
        path = ".//Setting[@name='envelopeAlignedTurns']"
        self.assertEqual(ET.fromstring(test_settings(settings)).find(path).get('defaultBool'), 'true')
        self.assertEqual(ET.fromstring(settings).find(path).get('defaultBool'), 'false')
        self.assertEqual((ROOT/'modDesc.xml').read_bytes(), manifest)
        self.assertEqual((ROOT/'config/VehicleSettingsSetup.xml').read_bytes(), settings)

    def test_will_not_overwrite_live_or_directory_build(self):
        for name in ('FS25_Courseplay.zip', 'FS25_Courseplay_ImplementProfilesTest.zip'):
            with self.assertRaises(ValueError):
                build(ROOT/'out'/name)

    def test_runtime_sources_compile_with_lua51(self):
        lua = LuaRuntime(unpack_returned_tuples=True)
        compile_source = lua.eval('function(text,name) local fn,err=loadstring(text,name); return fn~=nil,err end')
        manifest=ET.parse(ROOT/'modDesc.xml').getroot()
        names=['Courseplay.lua']+[e.get('filename') for e in manifest.findall('./extraSourceFiles/sourceFile')]
        for name in names:
            with self.subTest(name=name):
                ok,error=compile_source((ROOT/name).read_text(encoding='utf-8-sig'),name)
                self.assertTrue(ok,error)

if __name__ == '__main__':
    unittest.main()
