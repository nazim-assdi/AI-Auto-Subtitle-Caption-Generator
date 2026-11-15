import sys
import tempfile
import unittest
from pathlib import Path

from docx import Document
from openpyxl import load_workbook

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from export_utils import make_all_exports


class ExportCenterTest(unittest.TestCase):
    def setUp(self):
        self.segments = [
            {
                "id": 0, "start": 0.0, "end": 1.25, "text": "Hello world!",
                "avg_logprob": -0.2, "no_speech_prob": 0.01,
                "words": [
                    {"text": "Hello", "start": 0.0, "end": 0.5, "probability": 0.9},
                    {"text": "world!", "start": 0.51, "end": 1.2, "probability": 0.8},
                ],
            },
            {
                "id": 1, "start": 2.0, "end": 3.0, "text": "This is a test.",
                "avg_logprob": -0.15, "no_speech_prob": 0.02,
                "words": [
                    {"text": "This", "start": 2.0, "end": 2.2, "probability": 0.95},
                    {"text": "is", "start": 2.2, "end": 2.4, "probability": 0.9},
                    {"text": "a", "start": 2.4, "end": 2.5, "probability": 0.9},
                    {"text": "test.", "start": 2.5, "end": 3.0, "probability": 0.9},
                ],
            },
        ]
        self.insights = {
            "word_count": 6,
            "duration_seconds": 3.0,
            "speaking_rate_wpm": 120.0,
            "pause_count_over_1_2s": 1,
            "filler_word_counts": {},
            "long_pauses": [{"start": 1.25, "end": 2.0, "seconds": 0.75}],
            "low_alignment_probability_words": [],
            "hook_moment_suggestions": [],
        }

    def test_all_office_and_text_exports_are_created(self):
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp)
            make_all_exports(folder, self.segments, self.insights, "en")
            expected = [
                "transcript.txt", "transcript-timecoded.txt", "captions.csv",
                "captions.tsv", "captions.sbv", "captions.ssa", "captions.xlsx",
                "transcript.docx", "transcript.md", "transcript.html", "all-exports.zip",
            ]
            for name in expected:
                self.assertTrue((folder / name).exists(), name)
                self.assertGreater((folder / name).stat().st_size, 0, name)

            self.assertIn("Hello world!", (folder / "transcript.txt").read_text(encoding="utf-8-sig"))
            self.assertIn("00:00:00", (folder / "transcript-timecoded.txt").read_text(encoding="utf-8-sig"))
            self.assertIn("0:00:00.000", (folder / "captions.sbv").read_text(encoding="utf-8-sig"))
            self.assertIn("[V4 Styles]", (folder / "captions.ssa").read_text(encoding="utf-8"))

            workbook = load_workbook(folder / "captions.xlsx", read_only=True)
            self.assertEqual(workbook.sheetnames, ["Captions", "Word Timing", "Creator Pulse"])
            self.assertEqual(workbook["Captions"].max_row, 3)
            self.assertEqual(workbook["Word Timing"].max_row, 7)
            self.assertEqual(workbook["Creator Pulse"]["B2"].value, "en")

            document = Document(folder / "transcript.docx")
            self.assertIn("Video Transcript", document.paragraphs[0].text)
            self.assertEqual(len(document.tables[0].rows), 3)
            self.assertIn("Hello world!", document.tables[0].rows[1].cells[3].text)
            import zipfile
            with zipfile.ZipFile(folder / "all-exports.zip") as archive:
                self.assertIn("captions.xlsx", archive.namelist())
                self.assertIn("transcript.docx", archive.namelist())


if __name__ == "__main__":
    unittest.main()
