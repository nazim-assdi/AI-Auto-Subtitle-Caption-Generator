import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from subtitle_utils import ass_time, collect_word_items, escape_ass_text, make_ass, make_srt, split_into_phrases, srt_time


class SubtitleHelpersTest(unittest.TestCase):
    def setUp(self):
        self.segment = SimpleNamespace(
            start=0.0,
            end=1.5,
            text=" Hello world!",
            words=[
                SimpleNamespace(word=" Hello", start=0.0, end=0.55),
                SimpleNamespace(word=" world!", start=0.56, end=1.4),
            ],
        )

    def test_time_formats(self):
        self.assertEqual(ass_time(3661.25), "1:01:01.25")
        self.assertEqual(srt_time(3661.25), "01:01:01,250")

    def test_ass_text_escaping(self):
        self.assertEqual(escape_ass_text(r"{name}\\path"), r"\{name\}\\\\path")

    def test_word_timestamps_and_phrase_split(self):
        words = collect_word_items([self.segment])
        self.assertEqual([word["text"] for word in words], ["Hello", "world!"])
        self.assertEqual(len(split_into_phrases(words)), 1)

    def test_writes_srt_and_word_level_ass(self):
        with tempfile.TemporaryDirectory() as tmp:
            srt_path = Path(tmp) / "captions.srt"
            ass_path = Path(tmp) / "captions.ass"
            make_srt([self.segment], srt_path)
            make_ass([self.segment], 1080, 1920, "hormozi", ass_path)
            srt = srt_path.read_text(encoding="utf-8-sig")
            ass = ass_path.read_text(encoding="utf-8")
            self.assertIn("00:00:00,000 --> 00:00:01,500", srt)
            self.assertEqual(ass.count("Dialogue:"), 2)
            self.assertIn("40D7FF", ass)


if __name__ == "__main__":
    unittest.main()
