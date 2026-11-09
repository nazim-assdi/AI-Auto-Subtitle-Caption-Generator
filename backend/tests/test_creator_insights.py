import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from main import build_insights


class CreatorInsightsTest(unittest.TestCase):
    def test_pace_pauses_fillers_and_review_words(self):
        data = [
            {
                "id": 0, "start": 0.0, "end": 4.0, "text": "You know this is amazing?",
                "words": [
                    {"text": "You", "start": 0.0, "end": 0.3, "probability": 0.2},
                    {"text": "know", "start": 0.3, "end": 0.6, "probability": 0.9},
                    {"text": "this", "start": 0.7, "end": 1.0, "probability": 0.8},
                ],
            },
            {
                "id": 1, "start": 6.0, "end": 10.0, "text": "Actually this works!",
                "words": [
                    {"text": "Actually", "start": 6.0, "end": 6.6, "probability": 0.3},
                    {"text": "this", "start": 6.7, "end": 7.0, "probability": 0.8},
                    {"text": "works!", "start": 7.0, "end": 7.5, "probability": 0.9},
                ],
            },
        ]
        report = build_insights(data, "en")
        self.assertEqual(report["word_count"], 8)
        self.assertEqual(report["pause_count_over_1_2s"], 1)
        self.assertEqual(report["filler_word_counts"]["you know"], 1)
        self.assertEqual(report["filler_word_counts"]["actually"], 1)
        self.assertEqual(report["speaking_rate_wpm"], 60.0)
        self.assertEqual(len(report["low_alignment_probability_words"]), 2)
        self.assertTrue(report["hook_moment_suggestions"])


if __name__ == "__main__":
    unittest.main()
