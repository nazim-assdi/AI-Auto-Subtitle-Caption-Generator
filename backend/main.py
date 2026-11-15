from __future__ import annotations

import json
import math
import os
import re
import shutil
import subprocess
import threading
import uuid
from pathlib import Path
from statistics import mean
from types import SimpleNamespace
from typing import Any, Optional

from fastapi import BackgroundTasks, FastAPI, File, Form, HTTPException, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse
from faster_whisper import WhisperModel
from faster_whisper.tokenizer import _LANGUAGE_CODES
from pydantic import BaseModel, Field

try:
    import argostranslate.package as argos_package
    import argostranslate.translate as argos_translate
except ImportError:
    argos_package = None
    argos_translate = None

from subtitle_utils import STYLE_COLORS, collect_word_items, make_ass, make_srt, make_vtt
from export_utils import make_all_exports

BASE_DIR = Path(__file__).resolve().parent
DATA_DIR = Path(os.getenv("AI_SUBTITLE_DATA_DIR", str(BASE_DIR / "data"))).expanduser().resolve()
JOBS_DIR = DATA_DIR / "jobs"
MODEL_DIR = DATA_DIR / "models"
for folder in (DATA_DIR, JOBS_DIR, MODEL_DIR):
    folder.mkdir(parents=True, exist_ok=True)

MAX_UPLOAD_MB = int(os.getenv("MAX_UPLOAD_MB", "500"))
MAX_UPLOAD_BYTES = MAX_UPLOAD_MB * 1024 * 1024
CPU_THREADS = max(1, min(os.cpu_count() or 4, int(os.getenv("CPU_THREADS", "4"))))
ALLOWED_EXTENSIONS = {".mp4", ".mov", ".mkv", ".webm", ".avi", ".m4v"}
ALLOWED_LANGUAGES = {"auto", *_LANGUAGE_CODES}
ALLOWED_MODELS = {"tiny", "base", "small"}
CAPTION_FONT_FAMILIES = {"Segoe UI", "Arial", "Nirmala UI", "Verdana", "Georgia", "Impact", "Tahoma", "Trebuchet MS"}
FILLER_WORDS = {
    "en": {"uh", "um", "erm", "hmm", "you know", "i mean", "basically", "actually"},
    "bn": {"মানে", "উম", "আসলে", "এইযে", "তো", "হ্যাঁ মানে"},
    "hi": {"मतलब", "उम", "आह", "यानी"},
    "es": {"eh", "este", "pues", "o sea"},
    "fr": {"euh", "bah", "ben", "en fait"},
}
LANGUAGE_NAMES = {
    "af": "Afrikaans", "am": "Amharic", "ar": "Arabic", "as": "Assamese", "az": "Azerbaijani",
    "ba": "Bashkir", "be": "Belarusian", "bg": "Bulgarian", "bn": "Bengali", "bo": "Tibetan",
    "br": "Breton", "bs": "Bosnian", "ca": "Catalan", "cs": "Czech", "cy": "Welsh",
    "da": "Danish", "de": "German", "el": "Greek", "en": "English", "es": "Spanish",
    "et": "Estonian", "eu": "Basque", "fa": "Persian", "fi": "Finnish", "fo": "Faroese",
    "fr": "French", "gl": "Galician", "gu": "Gujarati", "ha": "Hausa", "haw": "Hawaiian",
    "he": "Hebrew", "hi": "Hindi", "hr": "Croatian", "ht": "Haitian Creole", "hu": "Hungarian",
    "hy": "Armenian", "id": "Indonesian", "is": "Icelandic", "it": "Italian", "ja": "Japanese",
    "jw": "Javanese", "ka": "Georgian", "kk": "Kazakh", "km": "Khmer", "kn": "Kannada",
    "ko": "Korean", "la": "Latin", "lb": "Luxembourgish", "ln": "Lingala", "lo": "Lao",
    "lt": "Lithuanian", "lv": "Latvian", "mg": "Malagasy", "mi": "Maori", "mk": "Macedonian",
    "ml": "Malayalam", "mn": "Mongolian", "mr": "Marathi", "ms": "Malay", "mt": "Maltese",
    "my": "Myanmar", "ne": "Nepali", "nl": "Dutch", "nn": "Norwegian Nynorsk", "no": "Norwegian",
    "oc": "Occitan", "pa": "Punjabi", "pl": "Polish", "ps": "Pashto", "pt": "Portuguese",
    "ro": "Romanian", "ru": "Russian", "sa": "Sanskrit", "sd": "Sindhi", "si": "Sinhala",
    "sk": "Slovak", "sl": "Slovenian", "sn": "Shona", "so": "Somali", "sq": "Albanian",
    "sr": "Serbian", "su": "Sundanese", "sv": "Swedish", "sw": "Swahili", "ta": "Tamil",
    "te": "Telugu", "tg": "Tajik", "th": "Thai", "tk": "Turkmen", "tl": "Tagalog",
    "tr": "Turkish", "tt": "Tatar", "uk": "Ukrainian", "ur": "Urdu", "uz": "Uzbek",
    "vi": "Vietnamese", "yi": "Yiddish", "yo": "Yoruba", "zh": "Chinese", "yue": "Cantonese",
}

app = FastAPI(title="AI Auto Subtitle Generator API", version="2.0.0")
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=False,
    allow_methods=["GET", "POST", "PUT", "DELETE", "OPTIONS"],
    allow_headers=["*"],
)

jobs: dict[str, dict[str, Any]] = {}
jobs_lock = threading.Lock()
model_lock = threading.RLock()
loaded_model: Optional[WhisperModel] = None
loaded_model_size: Optional[str] = None


class TranscriptUpdate(BaseModel):
    texts: list[str] = Field(min_length=1, max_length=5000)
    style: str | None = None
    words_per_line: int | None = Field(default=None, ge=2, le=8)
    position: str | None = None
    font_family: str | None = Field(default=None, max_length=48)


class TranslationRequest(BaseModel):
    target_language: str = Field(min_length=2, max_length=16)


class TrimRequest(BaseModel):
    start_seconds: float = Field(ge=0)
    end_seconds: float = Field(gt=0)


def validate_trim_range(start_seconds: float, end_seconds: float, video_duration: float) -> float:
    values = (start_seconds, end_seconds, video_duration)
    if not all(math.isfinite(value) for value in values):
        raise ValueError("Trim time values must be finite numbers.")
    if start_seconds < 0 or end_seconds <= start_seconds:
        raise ValueError("End time must be later than start time.")
    if video_duration <= 0 or start_seconds >= video_duration or end_seconds > video_duration + 0.15:
        raise ValueError("The selected trim range is outside the video duration.")
    duration = end_seconds - start_seconds
    if duration < 0.25:
        raise ValueError("Select a segment of at least 0.25 seconds.")
    return round(duration, 3)


def update_job(job_id: str, **changes: Any) -> None:
    with jobs_lock:
        if job_id in jobs:
            jobs[job_id].update(changes)


def get_job(job_id: str) -> dict[str, Any]:
    with jobs_lock:
        job = jobs.get(job_id)
        if not job:
            raise HTTPException(status_code=404, detail="Job not found. Its status may no longer be available after the AI engine restarts.")
        return dict(job)


def get_model(model_size: str) -> WhisperModel:
    global loaded_model, loaded_model_size
    if loaded_model is not None and loaded_model_size == model_size:
        return loaded_model
    with model_lock:
        if loaded_model is None or loaded_model_size != model_size:
            loaded_model = None
            loaded_model_size = None
            loaded_model = WhisperModel(
                model_size, device="cpu", compute_type="int8",
                cpu_threads=CPU_THREADS, num_workers=1, download_root=str(MODEL_DIR),
            )
            loaded_model_size = model_size
    return loaded_model



def validate_caption_font(font_family: str) -> str:
    selected = font_family.strip()
    if selected not in CAPTION_FONT_FAMILIES:
        raise ValueError("Unsupported caption font family.")
    return selected


def translate_segment_data(
    segment_data: list[dict[str, Any]], source_code: str, target_code: str
) -> list[dict[str, Any]]:
    """Translate complete ASR cues while retaining each cue's original timing."""
    if argos_translate is None:
        raise RuntimeError(
            "Offline translation is not installed. Install the Argos translation engine "
            "and the requested source-to-target language pair, then retry."
        )
    installed = {language.code: language for language in argos_translate.get_installed_languages()}
    source = installed.get(source_code)
    target = installed.get(target_code)
    if source is None or target is None:
        raise RuntimeError(
            f"The offline translation pair {source_code} → {target_code} is not installed. "
            "Install that pair with the translation model installer, then retry."
        )
    translator = source.get_translation(target)
    if translator is None:
        raise RuntimeError(
            f"No offline translation path is installed for {source_code} → {target_code}."
        )
    translated: list[dict[str, Any]] = []
    for item in segment_data:
        copy = dict(item)
        original_text = str(item.get("text", "") or "")
        copy["text"] = translator.translate(original_text) if original_text.strip() else ""
        # Source word timestamps do not map onto translated word order. The ASS
        # writer distributes translated words across the original cue timing.
        copy["words"] = []
        translated.append(copy)
    return translated

def parse_ffmpeg_filters(output: str) -> set[str]:
    """Extract FFmpeg filter names from the human-readable -filters table."""
    available: set[str] = set()
    for line in output.splitlines():
        columns = line.split()
        if len(columns) >= 2 and len(columns[0]) == 3 and set(columns[0]) <= {".", "A", "C", "V", "S", "N", "T"}:
            available.add(columns[1])
    return available


def get_ffmpeg_capabilities() -> dict[str, Any]:
    ffmpeg_path = shutil.which("ffmpeg")
    ffprobe_path = shutil.which("ffprobe")
    result: dict[str, Any] = {
        "ffmpeg_ready": bool(ffmpeg_path and ffprobe_path),
        "ffmpeg_path": ffmpeg_path,
        "ffprobe_path": ffprobe_path,
        "ass_filter_ready": False,
        "subtitles_filter_ready": False,
        "ffmpeg_version": None,
    }
    if not ffmpeg_path:
        result["diagnostic"] = "FFmpeg was not found on the system PATH."
        return result
    try:
        version = subprocess.run([ffmpeg_path, "-version"], capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=10)
        result["ffmpeg_version"] = (version.stdout.splitlines() or [""])[0]
        filters = subprocess.run([ffmpeg_path, "-hide_banner", "-filters"], capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=15)
        available = parse_ffmpeg_filters((filters.stdout or "") + "\\n" + (filters.stderr or ""))
        result["ass_filter_ready"] = "ass" in available
        result["subtitles_filter_ready"] = "subtitles" in available
        if not ffprobe_path:
            result["diagnostic"] = "FFprobe was not found. Install FFprobe from the same FFmpeg distribution."
        elif not result["ass_filter_ready"]:
            result["diagnostic"] = "The FFmpeg build does not include the ASS/libass filter. Install a full FFmpeg build with libass support."
        else:
            result["diagnostic"] = "FFmpeg, FFprobe and the ASS subtitle renderer are ready."
    except Exception as exc:
        result["diagnostic"] = f"FFmpeg diagnostics failed: {exc}"
    return result


def run_command(command: list[str], cwd: Optional[Path] = None) -> subprocess.CompletedProcess[str]:
    try:
        result = subprocess.run(
            command, cwd=str(cwd) if cwd else None, capture_output=True,
            text=True, encoding="utf-8", errors="replace", check=False,
        )
    except FileNotFoundError as exc:
        raise RuntimeError("FFmpeg was not found. Install FFmpeg and add it to PATH.") from exc
    if result.returncode != 0:
        message = (result.stderr or result.stdout or "Unknown FFmpeg error").strip()
        raise RuntimeError(message[-5000:])
    return result


def probe_video(ffprobe: str, input_path: Path) -> tuple[int, int]:
    result = run_command([
        ffprobe, "-v", "error", "-select_streams", "v:0",
        "-show_entries", "stream=width,height", "-of", "json", input_path.name,
    ], cwd=input_path.parent)
    streams = json.loads(result.stdout or "{}").get("streams") or []
    if not streams:
        raise RuntimeError("No video stream was found in the selected file.")
    return int(streams[0].get("width", 1080)), int(streams[0].get("height", 1920))


def serialize_segments(segments: list[Any]) -> list[dict[str, Any]]:
    data = []
    for segment in segments:
        words = []
        for word in getattr(segment, "words", None) or []:
            words.append({
                "text": getattr(word, "word", ""),
                "start": float(word.start),
                "end": float(word.end),
                "probability": float(getattr(word, "probability", 0.0) or 0.0),
            })
        data.append({
            "id": int(getattr(segment, "id", len(data))),
            "start": float(segment.start),
            "end": float(segment.end),
            "text": (getattr(segment, "text", "") or "").strip(),
            "avg_logprob": float(getattr(segment, "avg_logprob", 0.0) or 0.0),
            "no_speech_prob": float(getattr(segment, "no_speech_prob", 0.0) or 0.0),
            "words": words,
        })
    return data


def hydrate_segments(data: list[dict[str, Any]]) -> list[SimpleNamespace]:
    segments = []
    for item in data:
        words = [
            SimpleNamespace(
                word=word["text"], start=float(word["start"]), end=float(word["end"]),
                probability=float(word.get("probability", 0.0)),
            )
            for word in item.get("words", [])
        ]
        segments.append(SimpleNamespace(
            id=int(item.get("id", len(segments))),
            start=float(item["start"]), end=float(item["end"]),
            text=str(item.get("text", "")), words=words,
            avg_logprob=float(item.get("avg_logprob", 0.0)),
            no_speech_prob=float(item.get("no_speech_prob", 0.0)),
        ))
    return segments


def build_insights(segment_data: list[dict[str, Any]], language: str) -> dict[str, Any]:
    words = []
    for item in segment_data:
        words.extend(re.findall(r"\S+", item.get("text", "")))
    total_words = len(words)
    start = min((float(x["start"]) for x in segment_data), default=0.0)
    end = max((float(x["end"]) for x in segment_data), default=0.0)
    duration = max(0.0, end - start)
    spoken = sum(max(0.0, min(float(x["end"]), end) - max(float(x["start"]), start)) for x in segment_data)
    wpm = round(total_words / (spoken / 60.0), 1) if spoken > 0 else 0.0
    pauses = []
    ordered = sorted(segment_data, key=lambda x: float(x["start"]))
    for previous, current in zip(ordered, ordered[1:]):
        gap = float(current["start"]) - float(previous["end"])
        if gap >= 1.2:
            pauses.append({"start": round(float(previous["end"]), 2), "end": round(float(current["start"]), 2), "seconds": round(gap, 2)})
    probabilities = [
        float(word.get("probability", 0.0))
        for item in segment_data for word in item.get("words", [])
        if word.get("probability") is not None
    ]
    low_words = [
        {"text": word.get("text", "").strip(), "start": round(float(word["start"]), 2), "probability": round(float(word.get("probability", 0.0)), 3)}
        for item in segment_data for word in item.get("words", [])
        if word.get("probability") is not None and float(word.get("probability", 0.0)) < 0.45
    ]
    filler_set = FILLER_WORDS.get(language, set())
    normalized = [word.lower().strip(".,!?;:()[]{}\"'“”‘’") for word in words]
    normalized_text = " ".join(normalized)
    filler_counts = {
        filler: (normalized_text.count(filler) if " " in filler else normalized.count(filler))
        for filler in sorted(filler_set)
        if (normalized_text.count(filler) if " " in filler else normalized.count(filler))
    }
    hook_candidates = []
    for item in segment_data:
        text = item.get("text", "").strip()
        if not text:
            continue
        score = 0
        if "?" in text or "？" in text or "।" in text:
            score += 1
        if "!" in text or "！" in text:
            score += 1
        if 5 <= len(text.split()) <= 18:
            score += 1
        if score >= 2:
            hook_candidates.append({
                "start": round(float(item["start"]), 2),
                "end": round(float(item["end"]), 2),
                "text": text,
                "reason": "Heuristic hook suggestion — review this moment before publishing.",
                "heuristic_score": score,
            })
    return {
        "word_count": total_words,
        "duration_seconds": round(duration, 2),
        "speaking_rate_wpm": wpm,
        "pause_count_over_1_2s": len(pauses),
        "long_pauses": pauses[:100],
        "filler_word_counts": filler_counts,
        "word_alignment_probability_mean": round(mean(probabilities), 3) if probabilities else None,
        "low_alignment_probability_words": low_words[:200],
        "hook_moment_suggestions": hook_candidates[:20],
        "notes": [
            "Word probability is an alignment signal, not proof that a word is correct.",
            "Hook suggestions are simple heuristics; review the video before publishing.",
            "Filler-word detection is language-specific and intentionally conservative.",
        ],
    }


def write_project_exports(job_dir: Path, segment_data: list[dict[str, Any]], style: str, words_per_line: int, position: str, language: str = "auto", font_family: str = "Segoe UI") -> dict[str, Any]:
    segments = hydrate_segments(segment_data)
    width, height = probe_video(shutil.which("ffprobe") or "ffprobe", next(job_dir.glob("source.*")))
    ass_path = job_dir / "captions.ass"
    make_ass(segments, width, height, style, ass_path, words_per_line=words_per_line, position=position, font_family=font_family)
    make_srt(segments, job_dir / "captions.srt")
    make_vtt(segments, job_dir / "captions.vtt")
    (job_dir / "transcript.txt").write_text(
        "\n".join((item.get("text", "") or "").strip() for item in segment_data).strip() + "\n",
        encoding="utf-8-sig",
    )
    (job_dir / "transcript.json").write_text(
        json.dumps({"segments": segment_data}, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    insights = build_insights(segment_data, language)
    (job_dir / "creator_report.json").write_text(
        json.dumps(insights, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    make_all_exports(job_dir, segment_data, insights=insights, language=language)
    return insights


def render_video(job_id: str, source_path: Path, job_dir: Path, style: str) -> int:
    ffmpeg = shutil.which("ffmpeg")
    if not ffmpeg:
        raise RuntimeError("FFmpeg was not found.")
    temp_output = job_dir / "captioned_video.next.mp4"
    run_command([
        ffmpeg, "-y", "-i", source_path.name, "-vf", "ass=captions.ass:shaping=complex",
        "-map", "0:v:0", "-map", "0:a:0?", "-c:v", "libx264", "-preset", "veryfast",
        "-crf", "23", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "192k",
        "-movflags", "+faststart", temp_output.name,
    ], cwd=job_dir)
    if not temp_output.exists() or temp_output.stat().st_size == 0:
        raise RuntimeError("FFmpeg could not create the output video.")
    final_output = job_dir / "captioned_video.mp4"
    temp_output.replace(final_output)
    return final_output.stat().st_size


def process_job(job_id: str, source_path: Path, model_size: str, language: str, style: str, hotwords: str, words_per_line: int, position: str, target_language: str = "same", font_family: str = "Segoe UI") -> None:
    job_dir = source_path.parent
    audio_path = job_dir / "speech.wav"
    try:
        capabilities = get_ffmpeg_capabilities()
        if not capabilities["ffmpeg_ready"]:
            raise RuntimeError(str(capabilities.get("diagnostic") or "FFmpeg or FFprobe is not installed."))
        if not capabilities["ass_filter_ready"]:
            raise RuntimeError("This FFmpeg build does not include the ASS/libass subtitle renderer. Install a full/shared FFmpeg build. Diagnostics: " + str(capabilities.get("diagnostic")))
        update_job(job_id, status="processing", progress=8, stage="Preparing audio from video")
        run_command([
            shutil.which("ffmpeg") or "ffmpeg", "-y", "-i", source_path.name, "-vn",
            "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le", audio_path.name,
        ], cwd=job_dir)
        update_job(job_id, progress=20, stage="Transcribing speech with Whisper")
        with model_lock:
            model = get_model(model_size)
            transcribe_args: dict[str, Any] = {
                "language": None if language == "auto" else language,
                "word_timestamps": True,
                "vad_filter": True,
                "beam_size": 3,
                "condition_on_previous_text": False,
            }
            if hotwords.strip():
                transcribe_args["hotwords"] = hotwords.strip()
            segments_iter, info = model.transcribe(str(audio_path), **transcribe_args)
            raw_segments = []
            duration = float(getattr(info, "duration", 0.0) or 0.0)
            for segment in segments_iter:
                raw_segments.append(segment)
                if duration > 0:
                    fraction = min(1.0, float(getattr(segment, "end", 0.0)) / duration)
                    update_job(job_id, progress=20 + int(fraction * 36), stage="Transcribing speech with Whisper")
        if not raw_segments:
            raise RuntimeError("No speech could be detected in the video. Try another video or check the audio track.")
        source_segments = serialize_segments(raw_segments)
        detected_language = str(getattr(info, "language", "auto") or "auto").lower()
        output_language = detected_language
        segment_data = source_segments
        if target_language != "same" and target_language != detected_language:
            update_job(job_id, progress=58, stage=f"Translating captions: {detected_language} → {target_language}")
            # Preserve the original transcript so bilingual/secondary translations remain possible.
            (job_dir / "original_segments.json").write_text(
                json.dumps(source_segments, ensure_ascii=False, indent=2), encoding="utf-8"
            )
            segment_data = translate_segment_data(source_segments, detected_language, target_language)
            output_language = target_language
        (job_dir / "segments.json").write_text(json.dumps(segment_data, ensure_ascii=False, indent=2), encoding="utf-8")
        update_job(job_id, progress=60, stage="Preparing transcript and creator report")
        insights = write_project_exports(job_dir, segment_data, style, words_per_line, position, output_language, font_family)
        transcript = "\n".join(item["text"] for item in segment_data).strip()
        update_job(
            job_id,
            progress=70,
            stage="Rendering animated word-by-word captions",
            detected_language=detected_language,
            subtitle_language=output_language,
            font_family=font_family,
            language_probability=round(float(getattr(info, "language_probability", 0.0) or 0.0), 3),
            transcript_preview=transcript[:500],
            insights_summary={
                "word_count": insights["word_count"],
                "speaking_rate_wpm": insights["speaking_rate_wpm"],
                "pause_count_over_1_2s": insights["pause_count_over_1_2s"],
                "low_alignment_probability_count": len(insights["low_alignment_probability_words"]),
            },
        )
        output_size = render_video(job_id, source_path, job_dir, style)
        update_job(job_id, status="completed", progress=100, stage="Subtitle rendering complete — your video and exports are ready", output_size=output_size)
    except Exception as exc:
        update_job(job_id, status="failed", progress=0, stage="Processing failed", error=str(exc)[-5000:])
        for filename in ("captioned_video.mp4", "captioned_video.next.mp4", "captions.srt", "captions.vtt", "captions.ass"):
            try:
                (job_dir / filename).unlink(missing_ok=True)
            except OSError:
                pass
    finally:
        try:
            audio_path.unlink(missing_ok=True)
        except OSError:
            pass


def rerender_job(job_id: str, style: str, words_per_line: int, position: str, font_family: str = "Segoe UI") -> None:
    job = get_job(job_id)
    job_dir = Path(job["job_dir"])
    source_path = Path(job["source_path"])
    try:
        update_job(job_id, status="rendering", progress=76, stage="Rendering the edited transcript")
        segment_data = json.loads((job_dir / "segments.json").read_text(encoding="utf-8"))
        output_language = job.get("subtitle_language") or job.get("detected_language", "auto") or "auto"
        insights = write_project_exports(job_dir, segment_data, style, words_per_line, position, output_language, font_family)
        output_size = render_video(job_id, source_path, job_dir, style)
        update_job(
            job_id, status="completed", progress=100, stage="Updated captions rendered successfully",
            style=style, words_per_line=words_per_line, position=position, font_family=font_family,
            output_size=output_size,
            insights_summary={
                "word_count": insights["word_count"],
                "speaking_rate_wpm": insights["speaking_rate_wpm"],
                "pause_count_over_1_2s": insights["pause_count_over_1_2s"],
                "low_alignment_probability_count": len(insights["low_alignment_probability_words"]),
            },
        )
    except Exception as exc:
        update_job(job_id, status="failed", progress=0, stage="Re-render failed", error=str(exc)[-5000:])


@app.get("/health")
def health() -> dict[str, Any]:
    return {
        "ok": True,
        "service": "AI Auto Subtitle Creator Studio",
        "version": app.version,
        "max_upload_mb": MAX_UPLOAD_MB,
        "default_model": "base",
        **get_ffmpeg_capabilities(),
    }


@app.get("/languages")
def supported_languages() -> dict[str, Any]:
    languages = [{"code": "auto", "name": "Auto detect"}]
    languages.extend({"code": code, "name": LANGUAGE_NAMES.get(code, code.upper())} for code in _LANGUAGE_CODES)
    return {"count": len(_LANGUAGE_CODES), "languages": languages}


@app.get("/translation/status")
def translation_status() -> dict[str, Any]:
    if argos_translate is None or argos_package is None:
        return {"enabled": False, "installed_languages": [], "installed_pairs": [], "message": "The optional offline translation engine is not installed."}
    languages = argos_translate.get_installed_languages()
    packages = argos_package.get_installed_packages()
    return {
        "enabled": True,
        "installed_languages": [{"code": language.code, "name": language.name} for language in languages],
        "installed_pairs": [{"from": package.from_code, "to": package.to_code} for package in packages],
        "message": "Offline translation is enabled for installed language models.",
    }


@app.get("/jobs/{job_id}/translation-options")
def translation_options(job_id: str) -> dict[str, Any]:
    job = get_job(job_id)
    if job.get("status") != "completed":
        raise HTTPException(status_code=409, detail="Transcription must finish first.")
    source_code = str(job.get("detected_language") or "").lower()
    if not source_code or source_code == "auto":
        return {"enabled": False, "source_language": source_code, "targets": []}
    if argos_translate is None:
        return {"enabled": False, "source_language": source_code, "targets": []}
    installed = {language.code: language for language in argos_translate.get_installed_languages()}
    source = installed.get(source_code)
    if source is None:
        return {"enabled": False, "source_language": source_code, "targets": []}
    targets = []
    for code, target in installed.items():
        if code == source_code:
            continue
        try:
            translation = source.get_translation(target)
        except Exception:
            translation = None
        if translation is not None:
            targets.append({"code": code, "name": LANGUAGE_NAMES.get(code, target.name)})
    return {"enabled": bool(targets), "source_language": source_code, "targets": targets}


@app.post("/jobs", status_code=202)
async def create_job(
    background_tasks: BackgroundTasks,
    file: UploadFile = File(...),
    language: str = Form("auto"),
    style: str = Form("hormozi"),
    model_size: str = Form("base"),
    hotwords: str = Form(""),
    words_per_line: int = Form(4),
    position: str = Form("bottom"),
    target_language: str = Form("same"),
    font_family: str = Form("Segoe UI"),
) -> dict[str, Any]:
    if not file.filename:
        raise HTTPException(status_code=400, detail="The uploaded file name is missing.")
    extension = Path(file.filename).suffix.lower()
    if extension not in ALLOWED_EXTENSIONS:
        raise HTTPException(status_code=400, detail="Upload an MP4, MOV, MKV, WEBM, AVI or M4V video.")
    language = language.strip().lower()
    if language not in ALLOWED_LANGUAGES:
        raise HTTPException(status_code=400, detail="The selected recognition language is not supported.")
    if model_size not in ALLOWED_MODELS:
        raise HTTPException(status_code=400, detail="Select the tiny, base or small model.")
    if style not in STYLE_COLORS:
        raise HTTPException(status_code=400, detail="Unknown caption style.")
    if not 2 <= words_per_line <= 8:
        raise HTTPException(status_code=400, detail="Choose between 2 and 8 words per caption line.")
    if position not in {"bottom", "top", "middle"}:
        raise HTTPException(status_code=400, detail="Caption position must be bottom, top or middle.")
    target_language = target_language.strip().lower()
    if target_language != "same" and target_language not in _LANGUAGE_CODES:
        raise HTTPException(status_code=400, detail="The selected subtitle output language is not supported.")
    try:
        font_family = validate_caption_font(font_family)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    if len(hotwords) > 1000:
        raise HTTPException(status_code=400, detail="Vocabulary hints can contain up to 1,000 characters.")

    job_id = uuid.uuid4().hex
    job_dir = JOBS_DIR / job_id
    job_dir.mkdir(parents=True, exist_ok=True)
    source_path = job_dir / f"source{extension}"
    copied = 0
    try:
        with source_path.open("wb") as destination:
            while True:
                chunk = await file.read(1024 * 1024)
                if not chunk:
                    break
                copied += len(chunk)
                if copied > MAX_UPLOAD_BYTES:
                    raise HTTPException(status_code=413, detail=f"Maximum video size: {MAX_UPLOAD_MB} MB।")
                destination.write(chunk)
    except Exception:
        shutil.rmtree(job_dir, ignore_errors=True)
        raise
    finally:
        await file.close()
    if copied == 0:
        shutil.rmtree(job_dir, ignore_errors=True)
        raise HTTPException(status_code=400, detail="The uploaded video file is empty.")

    with jobs_lock:
        jobs[job_id] = {
            "job_id": job_id, "status": "queued", "progress": 2,
            "stage": "Added to the processing queue", "error": None,
            "created_file": file.filename, "detected_language": None, "output_size": 0,
            "job_dir": str(job_dir), "source_path": str(source_path),
            "style": style, "words_per_line": words_per_line, "position": position,
            "target_language": target_language, "subtitle_language": None, "font_family": font_family,
        }
    background_tasks.add_task(process_job, job_id, source_path, model_size, language, style, hotwords, words_per_line, position, target_language, font_family)
    return {"job_id": job_id, "status": "queued", "message": "AI subtitle generation has started."}


@app.get("/jobs/{job_id}")
def job_status(job_id: str) -> dict[str, Any]:
    job = get_job(job_id)
    return {key: value for key, value in job.items() if key not in {"job_dir", "source_path"}}


@app.get("/jobs/{job_id}/transcript")
def get_transcript(job_id: str) -> dict[str, Any]:
    job = get_job(job_id)
    if job.get("status") != "completed":
        raise HTTPException(status_code=409, detail="Transcription and rendering must finish first.")
    path = Path(job["job_dir"]) / "segments.json"
    if not path.exists():
        raise HTTPException(status_code=404, detail="Transcript not found.")
    segments = json.loads(path.read_text(encoding="utf-8"))
    return {"segments": [{"id": x["id"], "start": x["start"], "end": x["end"], "text": x["text"]} for x in segments]}


@app.put("/jobs/{job_id}/transcript", status_code=202)
def update_transcript(job_id: str, payload: TranscriptUpdate, background_tasks: BackgroundTasks) -> dict[str, Any]:
    job = get_job(job_id)
    if job.get("status") != "completed":
        raise HTTPException(status_code=409, detail="This job cannot be edited in its current state.")
    job_dir = Path(job["job_dir"])
    source_path = Path(job["source_path"])
    if not source_path.exists():
        raise HTTPException(status_code=404, detail="The original video is missing. The job may have been deleted.")
    data_path = job_dir / "segments.json"
    segment_data = json.loads(data_path.read_text(encoding="utf-8"))
    if len(payload.texts) != len(segment_data):
        raise HTTPException(status_code=400, detail=f"The number of transcript lines cannot change. Exactly {len(segment_data)} lines must be submitted.")
    for item, new_text in zip(segment_data, payload.texts):
        clean = new_text.strip().replace("\n", " ")
        if len(clean) > 1000:
            raise HTTPException(status_code=400, detail="Each caption line can contain at most 1,000 characters.")
        if clean != item["text"]:
            item["text"] = clean
            # Rebuild a changed cue's word timing proportionally from the edited text.
            item["words"] = []
    style = payload.style or job.get("style", "hormozi")
    if style not in STYLE_COLORS:
        raise HTTPException(status_code=400, detail="Unknown caption style.")
    words_per_line = payload.words_per_line or int(job.get("words_per_line", 4))
    position = payload.position or job.get("position", "bottom")
    try:
        font_family = validate_caption_font(payload.font_family or job.get("font_family", "Segoe UI"))
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    if not 2 <= words_per_line <= 8 or position not in {"bottom", "top", "middle"}:
        raise HTTPException(status_code=400, detail="Caption layout settings are invalid.")
    data_path.write_text(json.dumps(segment_data, ensure_ascii=False, indent=2), encoding="utf-8")
    update_job(job_id, status="rendering", progress=76, stage="Saving transcript edits and rendering updated captions")
    background_tasks.add_task(rerender_job, job_id, style, words_per_line, position, font_family)
    return {"job_id": job_id, "status": "rendering", "message": "Edited captions are rendering."}


@app.get("/jobs/{job_id}/insights")
def job_insights(job_id: str) -> dict[str, Any]:
    job = get_job(job_id)
    if job.get("status") != "completed":
        raise HTTPException(status_code=409, detail="Processing must finish first.")
    path = Path(job["job_dir"]) / "creator_report.json"
    if not path.exists():
        raise HTTPException(status_code=404, detail="Creator report not found.")
    return json.loads(path.read_text(encoding="utf-8"))


@app.post("/jobs/{job_id}/translate", status_code=201)
def translate_job(job_id: str, payload: TranslationRequest) -> dict[str, Any]:
    if argos_translate is None:
        raise HTTPException(status_code=503, detail="The offline translation engine is unavailable. Install the Argos engine and the required language pair using the translation model installer.")
    job = get_job(job_id)
    if job.get("status") != "completed":
        raise HTTPException(status_code=409, detail="Transcription and rendering must finish first.")
    source_code = str(job.get("detected_language") or "").lower()
    target_code = payload.target_language.strip().lower()
    if not source_code or source_code == "auto":
        raise HTTPException(status_code=400, detail="The source language was not detected. Select a specific recognition language and transcribe again.")
    if source_code == target_code:
        raise HTTPException(status_code=400, detail="The source and target languages are the same.")
    installed = {language.code: language for language in argos_translate.get_installed_languages()}
    source = installed.get(source_code)
    target = installed.get(target_code)
    if source is None or target is None:
        raise HTTPException(status_code=409, detail=f"Argos does not have the language model for {source_code} → {target_code}  installed. Install the required pair with the translation model installer.")
    translator = source.get_translation(target)
    if translator is None:
        raise HTTPException(status_code=409, detail=f"{source_code} → {target_code}  translation path is not installed.")

    job_dir = Path(job["job_dir"])
    source_path = job_dir / "original_segments.json"
    if not source_path.exists():
        source_path = job_dir / "segments.json"
    source_data = json.loads(source_path.read_text(encoding="utf-8"))
    translated_data = []
    for item in source_data:
        translated_data.append({
            "id": item["id"],
            "start": float(item["start"]),
            "end": float(item["end"]),
            "text": translator.translate(item.get("text", "")) if item.get("text", "").strip() else "",
        })
    translated_segments = hydrate_segments(translated_data)
    make_srt(translated_segments, job_dir / "translated.srt")
    make_vtt(translated_segments, job_dir / "translated.vtt")
    bilingual = []
    for index, (original, translated) in enumerate(zip(source_data, translated_data), start=1):
        original_text = original.get("text", "").strip()
        translated_text = translated.get("text", "").strip()
        if original_text or translated_text:
            bilingual.append(
                f"{index}\n{srt_time(float(original['start']))} --> {srt_time(float(original['end']))}\n{original_text}\n{translated_text}"
            )
    (job_dir / "bilingual.srt").write_text("\ufeff" + "\n\n".join(bilingual) + ("\n" if bilingual else ""), encoding="utf-8")
    (job_dir / "translation.json").write_text(
        json.dumps({"source_language": source_code, "target_language": target_code, "segments": translated_data}, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    update_job(job_id, translation_target=target_code)
    return {
        "job_id": job_id,
        "source_language": source_code,
        "target_language": target_code,
        "segments": len(translated_data),
        "exports": ["translated.srt", "translated.vtt", "bilingual.srt", "translation.json"],
    }


@app.post("/jobs/{job_id}/trim", status_code=201)
def trim_video(job_id: str, payload: TrimRequest) -> dict[str, Any]:
    job = get_job(job_id)
    if job.get("status") != "completed":
        raise HTTPException(status_code=409, detail="Caption rendering must finish first.")

    job_dir = Path(job["job_dir"])
    source_path = job_dir / "captioned_video.mp4"
    if not source_path.exists():
        raise HTTPException(status_code=404, detail="Captioned video not found.")

    ffmpeg = shutil.which("ffmpeg")
    ffprobe = shutil.which("ffprobe")
    if not ffmpeg or not ffprobe:
        raise HTTPException(status_code=503, detail="FFmpeg/FFprobe is unavailable. Check engine diagnostics.")

    try:
        probe = run_command([
            ffprobe, "-v", "error", "-show_entries", "format=duration",
            "-of", "default=noprint_wrappers=1:nokey=1", source_path.name,
        ], cwd=job_dir)
        video_duration = float((probe.stdout or "").strip())
    except (RuntimeError, ValueError) as exc:
        raise HTTPException(status_code=500, detail=f"Could not read the video duration: {exc}") from exc

    try:
        trim_duration = validate_trim_range(payload.start_seconds, payload.end_seconds, video_duration)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc

    temporary_output = job_dir / "trimmed_video.next.mp4"
    trimmed_output = job_dir / "trimmed_video.mp4"
    try:
        run_command([
            ffmpeg, "-y", "-ss", f"{payload.start_seconds:.3f}", "-i", source_path.name,
            "-t", f"{trim_duration:.3f}", "-map", "0:v:0", "-map", "0:a:0?",
            "-c:v", "libx264", "-preset", "veryfast", "-crf", "23",
            "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "192k",
            "-movflags", "+faststart", temporary_output.name,
        ], cwd=job_dir)
        if not temporary_output.exists() or temporary_output.stat().st_size == 0:
            raise RuntimeError("FFmpeg could not create the trimmed MP4.")
        temporary_output.replace(trimmed_output)
    except RuntimeError as exc:
        temporary_output.unlink(missing_ok=True)
        raise HTTPException(status_code=500, detail=f"Could not trim the video: {exc}") from exc

    update_job(
        job_id,
        trim_start_seconds=round(payload.start_seconds, 3),
        trim_end_seconds=round(payload.end_seconds, 3),
        trimmed_output_size=trimmed_output.stat().st_size,
    )
    return {
        "job_id": job_id,
        "status": "completed",
        "kind": "trimmed-video",
        "start_seconds": round(payload.start_seconds, 3),
        "end_seconds": round(payload.end_seconds, 3),
        "duration_seconds": trim_duration,
        "output_size": trimmed_output.stat().st_size,
    }


def output_file(job_id: str, kind: str) -> tuple[Path, str, str]:
    job = get_job(job_id)
    if job.get("status") != "completed":
        raise HTTPException(status_code=409, detail="The job has not completed yet.")
    job_dir = Path(job["job_dir"])
    choices = {
        "video": ("captioned_video.mp4", "video/mp4", "captioned_video.mp4"),
        "trimmed-video": ("trimmed_video.mp4", "video/mp4", "trimmed_video.mp4"),
        "srt": ("captions.srt", "application/x-subrip", "captions.srt"),
        "vtt": ("captions.vtt", "text/vtt", "captions.vtt"),
        "ass": ("captions.ass", "text/plain", "captions.ass"),
        "txt": ("transcript.txt", "text/plain; charset=utf-8", "transcript.txt"),
        "json": ("transcript.json", "application/json", "transcript.json"),
        "insights": ("creator_report.json", "application/json", "creator_report.json"),
        "sbv": ("captions.sbv", "text/plain; charset=utf-8", "captions.sbv"),
        "ssa": ("captions.ssa", "text/plain; charset=utf-8", "captions.ssa"),
        "csv": ("captions.csv", "text/csv; charset=utf-8", "captions.csv"),
        "tsv": ("captions.tsv", "text/tab-separated-values; charset=utf-8", "captions.tsv"),
        "xlsx": ("captions.xlsx", "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", "captions.xlsx"),
        "docx": ("transcript.docx", "application/vnd.openxmlformats-officedocument.wordprocessingml.document", "transcript.docx"),
        "timecoded-txt": ("transcript-timecoded.txt", "text/plain; charset=utf-8", "transcript-timecoded.txt"),
        "md": ("transcript.md", "text/markdown; charset=utf-8", "transcript.md"),
        "html": ("transcript.html", "text/html; charset=utf-8", "transcript.html"),
        "all-exports": ("all-exports.zip", "application/zip", "AI_Subtitle_All_Exports.zip"),
        "translated-srt": ("translated.srt", "application/x-subrip", "translated.srt"),
        "translated-vtt": ("translated.vtt", "text/vtt", "translated.vtt"),
        "bilingual-srt": ("bilingual.srt", "application/x-subrip", "bilingual.srt"),
        "translation-json": ("translation.json", "application/json", "translation.json"),
    }
    if kind not in choices:
        raise HTTPException(status_code=400, detail="kind: video, trimmed-video, srt, vtt, ass, ssa, sbv, txt, timecoded-txt, csv, tsv, xlsx, docx, md, html, json, insights, all-exports, translated-srt, translated-vtt, bilingual-srt or translation-json.")
    filename, media_type, download_name = choices[kind]
    path = job_dir / filename
    if not path.exists():
        raise HTTPException(status_code=404, detail="The requested file was not found.")
    return path, media_type, download_name


@app.get("/jobs/{job_id}/stream")
def stream_video(job_id: str, kind: str = "video") -> FileResponse:
    path, media_type, filename = output_file(job_id, kind)
    return FileResponse(path, media_type=media_type, filename=filename)


@app.get("/jobs/{job_id}/download")
def download_output(job_id: str, kind: str = "video") -> FileResponse:
    path, media_type, filename = output_file(job_id, kind)
    return FileResponse(path, media_type=media_type, filename=filename)


@app.delete("/jobs/{job_id}", status_code=200)
def delete_job(job_id: str) -> dict[str, Any]:
    job = get_job(job_id)
    if job.get("status") in {"processing", "rendering", "queued"}:
        raise HTTPException(status_code=409, detail="A running job cannot be deleted.")
    shutil.rmtree(Path(job["job_dir"]), ignore_errors=False)
    with jobs_lock:
        jobs.pop(job_id, None)
    return {"ok": True, "deleted": job_id}
