import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from subtitle_utils import (
    ass_time, collect_word_items, escape_ass_text, make_ass, make_srt,
    make_vtt, split_into_phrases, srt_time, vtt_time,
)


class SubtitleHelpersTest(unittest.TestCase):
    def setUp(self):
        self.segment = SimpleNamespace(
            start=0.0, end=1.5, text=" Hello world!",
            words=[
                SimpleNamespace(word=" Hello", start=0.0, end=0.55, probability=0.9),
                SimpleNamespace(word=" world!", start=0.56, end=1.4, probability=0.8),
            ],
        )

    def test_time_formats(self):
        self.assertEqual(ass_time(3661.25), "1:01:01.25")
        self.assertEqual(srt_time(3661.25), "01:01:01,250")
        self.assertEqual(vtt_time(3661.25), "01:01:01.250")

    def test_ass_text_escaping(self):
        self.assertEqual(escape_ass_text(r"{name}\\path"), r"\{name\}\\\\path")

    def test_word_timestamps_and_phrase_split(self):
        words = collect_word_items([self.segment])
        self.assertEqual([word["text"] for word in words], ["Hello", "world!"])
        self.assertEqual(words[0]["probability"], 0.9)
        self.assertEqual(len(split_into_phrases(words)), 1)

    def test_writes_srt_vtt_and_word_level_ass(self):
        with tempfile.TemporaryDirectory() as tmp:
            srt_path = Path(tmp) / "captions.srt"
            vtt_path = Path(tmp) / "captions.vtt"
            ass_path = Path(tmp) / "captions.ass"
            make_srt([self.segment], srt_path)
            make_vtt([self.segment], vtt_path)
            make_ass([self.segment], 1080, 1920, "hormozi", ass_path)
            srt = srt_path.read_text(encoding="utf-8-sig")
            vtt = vtt_path.read_text(encoding="utf-8")
            ass = ass_path.read_text(encoding="utf-8")
            self.assertIn("00:00:00,000 --> 00:00:01,500", srt)
            self.assertIn("WEBVTT", vtt)
            self.assertIn("00:00:00.000 --> 00:00:01.500", vtt)
            self.assertEqual(ass.count("Dialogue:"), 2)
            self.assertIn("40D7FF", ass)

    def test_phrase_limits(self):
        words = [
            {"text": f"word{i}", "start": i * 0.2, "end": i * 0.2 + 0.15}
            for i in range(7)
        ]
        self.assertEqual([len(x) for x in split_into_phrases(words, max_words=3)], [3, 3, 1])


if __name__ == "__main__":
    unittest.main()
