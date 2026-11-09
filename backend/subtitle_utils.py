from __future__ import annotations

import os
import re
from pathlib import Path
from typing import Any

STYLE_COLORS = {
    # ASS inline colours are BBGGRR (without alpha).
    "hormozi": "40D7FF",  # warm yellow
    "clean": "FFE500",    # cyan
    "neon": "A34FFF",     # pink
}


def ass_time(seconds: float) -> str:
    seconds = max(0.0, seconds)
    centiseconds = int(round(seconds * 100))
    hours, remainder = divmod(centiseconds, 360000)
    minutes, remainder = divmod(remainder, 6000)
    whole_seconds, cs = divmod(remainder, 100)
    return f"{hours}:{minutes:02d}:{whole_seconds:02d}.{cs:02d}"


def srt_time(seconds: float) -> str:
    milliseconds = int(round(max(0.0, seconds) * 1000))
    hours, remainder = divmod(milliseconds, 3_600_000)
    minutes, remainder = divmod(remainder, 60_000)
    whole_seconds, ms = divmod(remainder, 1000)
    return f"{hours:02d}:{minutes:02d}:{whole_seconds:02d},{ms:03d}"


def escape_ass_text(text: str) -> str:
    # ASS uses braces for inline style overrides.
    return text.replace("\\", "\\\\").replace("{", "\\{").replace("}", "\\}").replace("\n", " ").strip()


def collect_word_items(segments: list[Any]) -> list[dict[str, Any]]:
    items: list[dict[str, Any]] = []
    for segment in segments:
        words = getattr(segment, "words", None) or []
        if words:
            for word in words:
                token = (getattr(word, "word", "") or "").strip()
                if not token:
                    continue
                start = getattr(word, "start", None)
                end = getattr(word, "end", None)
                if start is None or end is None:
                    continue
                items.append({"text": token, "start": float(start), "end": max(float(end), float(start) + 0.06)})
        else:
            # Fallback for models/segments that do not return word timestamps.
            tokens = re.findall(r"\S+", (getattr(segment, "text", "") or "").strip())
            if not tokens:
                continue
            start = float(segment.start)
            end = max(float(segment.end), start + 0.1)
            weights = [max(1, len(token)) for token in tokens]
            total = sum(weights)
            cursor = start
            for token, weight in zip(tokens, weights):
                token_end = cursor + (end - start) * weight / total
                items.append({"text": token, "start": cursor, "end": max(token_end, cursor + 0.06)})
                cursor = token_end
    items.sort(key=lambda item: (item["start"], item["end"]))
    return items


def split_into_phrases(words: list[dict[str, Any]], max_words: int = 4) -> list[list[dict[str, Any]]]:
    phrases: list[list[dict[str, Any]]] = []
    current: list[dict[str, Any]] = []
    punctuation = (".", "?", "!", ",", ":", ";", "।", "؟")
    for word in words:
        if current and (len(current) >= max_words or current[-1]["text"].endswith(punctuation)
                        or word["start"] - current[-1]["end"] > 1.0
                        or word["end"] - current[0]["start"] > 3.8):
            phrases.append(current)
            current = []
        current.append(word)
    if current:
        phrases.append(current)
    return phrases


def make_ass(segments: list[Any], width: int, height: int, style: str, target_path: Path) -> None:
    phrases = split_into_phrases(collect_word_items(segments))
    font_size = max(30, min(64, int(height * 0.047)))
    outline = 4 if style == "hormozi" else 2 if style == "clean" else 3
    active_color = STYLE_COLORS.get(style, STYLE_COLORS["hormozi"])
    font_name = "Nirmala UI" if os.name == "nt" else "Noto Sans Bengali"
    margin_v = max(55, int(height * 0.075))

    lines = [
        "[Script Info]",
        "ScriptType: v4.00+",
        f"PlayResX: {width}",
        f"PlayResY: {height}",
        "WrapStyle: 2",
        "ScaledBorderAndShadow: yes",
        "YCbCr Matrix: TV.709",
        "",
        "[V4+ Styles]",
        "Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding",
        f"Style: Default,{font_name},{font_size},&H00FFFFFF,&H000000FF,&H00000000,&H64000000,-1,0,0,0,100,100,0,0,1,{outline},2,2,50,50,{margin_v},1",
        "",
        "[Events]",
        "Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text",
    ]

    for phrase in phrases:
        phrase_texts = [word["text"] for word in phrase]
        for index, word in enumerate(phrase):
            end = phrase[index + 1]["start"] if index + 1 < len(phrase) else word["end"]
            end = max(float(end), float(word["start"]) + 0.08)
            styled_parts: list[str] = []
            for part_index, text in enumerate(phrase_texts):
                color = active_color if part_index == index else "FFFFFF"
                styled_parts.append(r"{\c&H" + color + "&}" + escape_ass_text(text) + r"{\c&HFFFFFF&}")
            caption = " ".join(styled_parts)
            lines.append(
                f"Dialogue: 0,{ass_time(word['start'])},{ass_time(end)},Default,,0,0,0,,{caption}"
            )

    # If transcription did not produce any word tokens, keep segment subtitles visible.
    if not phrases:
        for segment in segments:
            text = escape_ass_text(getattr(segment, "text", "") or "")
            if text:
                lines.append(f"Dialogue: 0,{ass_time(float(segment.start))},{ass_time(float(segment.end))},Default,,0,0,0,,{text}")

    target_path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def make_srt(segments: list[Any], target_path: Path) -> None:
    entries: list[str] = []
    index = 1
    for segment in segments:
        text = (getattr(segment, "text", "") or "").strip()
        if not text:
            continue
        entries.append(
            f"{index}\n{srt_time(float(segment.start))} --> {srt_time(float(segment.end))}\n{text}"
        )
        index += 1
    target_path.write_text("\n\n".join(entries) + ("\n" if entries else ""), encoding="utf-8-sig")


