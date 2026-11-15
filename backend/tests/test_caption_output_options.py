import sys
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import main


class CaptionOutputOptionsTest(unittest.TestCase):
    def test_caption_font_allowlist(self):
        self.assertEqual(main.validate_caption_font("Segoe UI"), "Segoe UI")
        self.assertEqual(main.validate_caption_font("Nirmala UI"), "Nirmala UI")
        with self.assertRaises(ValueError):
            main.validate_caption_font("Injected,Font")

    def test_output_translation_keeps_cue_timing_and_clears_source_word_alignment(self):
        class FakeTranslator:
            def translate(self, text):
                return f"translated: {text}"

        class FakeSource:
            code = "en"
            def get_translation(self, target):
                return FakeTranslator()

        class FakeTarget:
            code = "bn"

        class FakeArgos:
            @staticmethod
            def get_installed_languages():
                return [FakeSource(), FakeTarget()]

        source = [{
            "id": 4,
            "start": 1.25,
            "end": 2.75,
            "text": "Hello there",
            "words": [{"text": "Hello", "start": 1.25, "end": 1.8, "probability": 0.9}],
        }]
        with patch.object(main, "argos_translate", FakeArgos):
            result = main.translate_segment_data(source, "en", "bn")

        self.assertEqual(result[0]["text"], "translated: Hello there")
        self.assertEqual(result[0]["start"], 1.25)
        self.assertEqual(result[0]["end"], 2.75)
        self.assertEqual(result[0]["words"], [])
        self.assertEqual(source[0]["words"][0]["text"], "Hello")


if __name__ == "__main__":
    unittest.main()
