"""Check profile language coverage and Lua format arguments using CP's real catalogues."""

from pathlib import Path
import re
import unittest
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parents[2]
GLOBAL_SETTINGS = ("autoLoadSingleImplementProfile", "showImplementProfileSuggestions", "noImplementProfileSettings")


def is_profile_key(key):
    return key.startswith("CP_implementProfiles_") or any(
        key.startswith("CP_global_setting_" + name + "_") for name in GLOBAL_SETTINGS
    )


def format_arguments(text):
    # Lua string.format consumes arguments in order; translated text must retain their types.
    return re.findall(r"%[-+ #0]*\d*(?:\.\d+)?([cdiouxXeEfgGqs])", text.replace("%%", ""))


class ProfileTranslationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        master = ET.parse(ROOT / "config/MasterTranslations.xml")
        cls.english = {
            entry.attrib["name"]: entry.findtext("Text[@language='en']")
            for entry in master.findall(".//Translation") if is_profile_key(entry.attrib["name"])
        }

    def test_all_cp_languages_have_profile_text_and_matching_format_arguments(self):
        # Use CP's declared languages rather than assuming the files on disk are complete.
        updater = (ROOT / ".github/scripts/update-translations/updateTranslations.py").read_text(encoding="utf-8")
        declared = re.search(r"supportedLanguages\s*=\s*\[(.*?)\]", updater, re.S).group(1)
        for language in re.findall(r'"([a-z]+)"', declared):
            catalogue = ET.parse(ROOT / f"translations/translation_{language}.xml")
            entries = catalogue.findall("./texts/text")
            texts = {entry.attrib["name"]: entry.attrib["text"] for entry in entries}
            self.assertEqual(len(entries), len(texts), f"Duplicate keys in {language}")
            for key, english in self.english.items():
                with self.subTest(language=language, key=key):
                    self.assertTrue(english, f"Missing master English text: {key}")
                    self.assertTrue(texts.get(key), f"Missing translated text or fallback: {key}")
                    self.assertEqual(format_arguments(texts[key]), format_arguments(english))

    def test_literal_profile_keys_used_by_lua_and_xml_are_registered(self):
        for folder, pattern in (("scripts", "*.lua"), ("config", "*.xml")):
            for path in (ROOT / folder).rglob(pattern):
                if "test" in path.parts or path.name == "MasterTranslations.xml":
                    continue
                text = path.read_text(encoding="utf-8-sig")
                for key in re.findall(r"CP_implementProfiles_[A-Za-z0-9_]+", text):
                    # Prefixes are completed with validated group/error/action names at runtime.
                    if key.endswith("_"):
                        continue
                    with self.subTest(file=str(path.relative_to(ROOT)), key=key):
                        self.assertIn(key, self.english)


if __name__ == "__main__":
    unittest.main()
