from __future__ import annotations

import json
import os
import shutil
import subprocess
import threading
import uuid
from pathlib import Path
from typing import Any, Optional

from fastapi import BackgroundTasks, FastAPI, File, Form, HTTPException, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse
from faster_whisper import WhisperModel

from subtitle_utils import STYLE_COLORS, make_ass, make_srt

BASE_DIR = Path(__file__).resolve().parent
DATA_DIR = BASE_DIR / "data"
JOBS_DIR = DATA_DIR / "jobs"
MODEL_DIR = DATA_DIR / "models"
for folder in (DATA_DIR, JOBS_DIR, MODEL_DIR):
    folder.mkdir(parents=True, exist_ok=True)

MAX_UPLOAD_MB = int(os.getenv("MAX_UPLOAD_MB", "500"))
MAX_UPLOAD_BYTES = MAX_UPLOAD_MB * 1024 * 1024
CPU_THREADS = max(1, min(os.cpu_count() or 4, int(os.getenv("CPU_THREADS", "4"))))
ALLOWED_EXTENSIONS = {".mp4", ".mov", ".mkv", ".webm", ".avi", ".m4v"}
ALLOWED_LANGUAGES = {"auto", "bn", "en", "hi", "ur", "ar"}
ALLOWED_MODELS = {"tiny", "base", "small"}

app = FastAPI(title="AI Auto Subtitle Generator API", version="1.0.0")
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=False,
    allow_methods=["GET", "POST", "OPTIONS"],
    allow_headers=["*"],
)

jobs: dict[str, dict[str, Any]] = {}
jobs_lock = threading.Lock()
model_lock = threading.RLock()
loaded_model: Optional[WhisperModel] = None
loaded_model_size: Optional[str] = None


def update_job(job_id: str, **changes: Any) -> None:
    with jobs_lock:
        if job_id in jobs:
            jobs[job_id].update(changes)


def get_model(model_size: str) -> WhisperModel:
    """Keep only one model in memory to avoid exhausting low-RAM PCs."""
    global loaded_model, loaded_model_size
    if loaded_model is not None and loaded_model_size == model_size:
        return loaded_model
    with model_lock:
        if loaded_model is None or loaded_model_size != model_size:
            loaded_model = None
            loaded_model_size = None
            loaded_model = WhisperModel(
                model_size,
                device="cpu",
                compute_type="int8",
                cpu_threads=CPU_THREADS,
                num_workers=1,
                download_root=str(MODEL_DIR),
            )
            loaded_model_size = model_size
    return loaded_model


def run_command(command: list[str], cwd: Optional[Path] = None) -> subprocess.CompletedProcess[str]:
    try:
        result = subprocess.run(
            command,
            cwd=str(cwd) if cwd else None,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            check=False,
        )
    except FileNotFoundError as exc:
        raise RuntimeError("FFmpeg পাওয়া যায়নি। Windows-এ FFmpeg install করে PATH-এ যোগ করো।") from exc
    if result.returncode != 0:
        message = (result.stderr or result.stdout or "Unknown FFmpeg error").strip()
        raise RuntimeError(message[-5000:])
    return result


def probe_video(ffprobe: str, input_path: Path) -> tuple[int, int]:
    result = run_command([
        ffprobe, "-v", "error", "-select_streams", "v:0", "-show_entries", "stream=width,height",
        "-of", "json", input_path.name,
    ], cwd=input_path.parent)
    data = json.loads(result.stdout or "{}")
    streams = data.get("streams") or []
    if not streams:
        raise RuntimeError("ভিডিও ফাইলের video stream পাওয়া যায়নি।")
    return int(streams[0].get("width", 1080)), int(streams[0].get("height", 1920))


def process_job(job_id: str, input_path: Path, model_size: str, language: str, style: str) -> None:
    job_dir = input_path.parent
    audio_path = job_dir / "speech.wav"
    ass_path = job_dir / "captions.ass"
    srt_path = job_dir / "captions.srt"
    transcript_path = job_dir / "transcript.txt"
    output_path = job_dir / "captioned_video.mp4"
    ffmpeg = shutil.which("ffmpeg")
    ffprobe = shutil.which("ffprobe")

    try:
        if not ffmpeg or not ffprobe:
            raise RuntimeError("FFmpeg/FFprobe ইনস্টল নেই। FFmpeg install করে Windows PATH-এ যোগ করে আবার চালাও।")

        update_job(job_id, status="processing", progress=8, stage="ভিডিও থেকে অডিও প্রস্তুত করা হচ্ছে")
        run_command([
            ffmpeg, "-y", "-i", input_path.name, "-vn", "-ac", "1", "-ar", "16000",
            "-c:a", "pcm_s16le", audio_path.name,
        ], cwd=job_dir)

        update_job(job_id, progress=20, stage="AI দিয়ে কথা শনাক্ত করা হচ্ছে (Whisper)")
        # Serialise inference to protect the CPU/RAM on entry-level PCs.
        with model_lock:
            model = get_model(model_size)
            segments_iter, info = model.transcribe(
                str(audio_path),
                language=None if language == "auto" else language,
                word_timestamps=True,
                vad_filter=True,
                beam_size=3,
                condition_on_previous_text=False,
            )
            segments = []
            duration = float(getattr(info, "duration", 0.0) or 0.0)
            for segment in segments_iter:
                segments.append(segment)
                if duration > 0:
                    fraction = min(1.0, float(getattr(segment, "end", 0.0)) / duration)
                    update_job(job_id, progress=20 + int(fraction * 36), stage="AI দিয়ে কথা শনাক্ত করা হচ্ছে (Whisper)")

        if not segments:
            raise RuntimeError("ভিডিওতে শনাক্ত করার মতো কোনো কথা পাওয়া যায়নি। অন্য ভিডিও দিয়ে চেষ্টা করো।")

        update_job(job_id, progress=58, stage="শব্দের টাইমস্ট্যাম্প ও সাবটাইটেল তৈরি হচ্ছে")
        width, height = probe_video(ffprobe, input_path)
        make_ass(segments, width, height, style, ass_path)
        make_srt(segments, srt_path)
        transcript = "\n".join((getattr(segment, "text", "") or "").strip() for segment in segments).strip()
        transcript_path.write_text(transcript + "\n", encoding="utf-8-sig")

        update_job(
            job_id,
            progress=68,
            stage="ভিডিওতে রঙিন word-by-word caption বসানো হচ্ছে",
            detected_language=getattr(info, "language", None),
            language_probability=round(float(getattr(info, "language_probability", 0.0) or 0.0), 3),
            transcript_preview=transcript[:500],
        )
        # ASS file is referenced by relative name, avoiding Windows drive-letter escaping bugs.
        run_command([
            ffmpeg, "-y", "-i", input_path.name, "-vf", "ass=captions.ass:shaping=complex",
            "-map", "0:v:0", "-map", "0:a:0?", "-c:v", "libx264", "-preset", "veryfast",
            "-crf", "23", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "192k",
            "-movflags", "+faststart", output_path.name,
        ], cwd=job_dir)

        if not output_path.exists() or output_path.stat().st_size == 0:
            raise RuntimeError("FFmpeg output video তৈরি করতে পারেনি।")

        update_job(
            job_id,
            status="completed",
            progress=100,
            stage="সম্পন্ন",
            output_size=output_path.stat().st_size,
            detected_language=getattr(info, "language", None),
        )
    except Exception as exc:
        update_job(job_id, status="failed", progress=0, stage="সমস্যা হয়েছে", error=str(exc)[-5000:])
        for path in (output_path, srt_path, transcript_path):
            try:
                if path.exists():
                    path.unlink()
            except OSError:
                pass
    finally:
        for path in (input_path, audio_path, ass_path):
            try:
                if path.exists():
                    path.unlink()
            except OSError:
                pass


@app.get("/health")
def health() -> dict[str, Any]:
    return {
        "ok": True,
        "service": "AI Auto Subtitle Generator",
        "ffmpeg_ready": bool(shutil.which("ffmpeg") and shutil.which("ffprobe")),
        "max_upload_mb": MAX_UPLOAD_MB,
        "default_model": "base",
    }


@app.post("/jobs", status_code=202)
async def create_job(
    background_tasks: BackgroundTasks,
    file: UploadFile = File(...),
    language: str = Form("auto"),
    style: str = Form("hormozi"),
    model_size: str = Form("base"),
) -> dict[str, Any]:
    if not file.filename:
        raise HTTPException(status_code=400, detail="ফাইলের নাম পাওয়া যায়নি।")
    extension = Path(file.filename).suffix.lower()
    if extension not in ALLOWED_EXTENSIONS:
        raise HTTPException(status_code=400, detail="MP4, MOV, MKV, WEBM, AVI বা M4V ভিডিও আপলোড করো।")
    if language not in ALLOWED_LANGUAGES:
        raise HTTPException(status_code=400, detail="নির্বাচিত ভাষা সমর্থিত নয়।")
    if model_size not in ALLOWED_MODELS:
        raise HTTPException(status_code=400, detail="tiny, base অথবা small মডেল নির্বাচন করো।")
    if style not in STYLE_COLORS:
        raise HTTPException(status_code=400, detail="hormozi, clean অথবা neon caption style নির্বাচন করো।")

    job_id = uuid.uuid4().hex
    job_dir = JOBS_DIR / job_id
    job_dir.mkdir(parents=True, exist_ok=True)
    input_path = job_dir / f"input{extension}"
    copied = 0
    try:
        with input_path.open("wb") as destination:
            while True:
                chunk = await file.read(1024 * 1024)
                if not chunk:
                    break
                copied += len(chunk)
                if copied > MAX_UPLOAD_BYTES:
                    raise HTTPException(status_code=413, detail=f"সর্বোচ্চ ভিডিও সাইজ {MAX_UPLOAD_MB} MB।")
                destination.write(chunk)
    except Exception:
        shutil.rmtree(job_dir, ignore_errors=True)
        raise
    finally:
        await file.close()

    if copied == 0:
        shutil.rmtree(job_dir, ignore_errors=True)
        raise HTTPException(status_code=400, detail="খালি ভিডিও ফাইল আপলোড করা যাবে না।")

    with jobs_lock:
        jobs[job_id] = {
            "job_id": job_id,
            "status": "queued",
            "progress": 2,
            "stage": "কাজের সারিতে যোগ হয়েছে",
            "error": None,
            "created_file": file.filename,
            "detected_language": None,
            "output_size": 0,
            "job_dir": str(job_dir),
        }
    background_tasks.add_task(process_job, job_id, input_path, model_size, language, style)
    return {"job_id": job_id, "status": "queued", "message": "ভিডিও প্রসেসিং শুরু হয়েছে।"}


@app.get("/jobs/{job_id}")
def job_status(job_id: str) -> dict[str, Any]:
    with jobs_lock:
        job = jobs.get(job_id)
        if not job:
            raise HTTPException(status_code=404, detail="এই কাজটি পাওয়া যায়নি। সার্ভার restart হলে পুরোনো job তালিকা মুছে যেতে পারে।")
        return {key: value for key, value in job.items() if key != "job_dir"}


def output_file(job_id: str, kind: str) -> tuple[Path, str, str]:
    with jobs_lock:
        job = jobs.get(job_id)
        if not job:
            raise HTTPException(status_code=404, detail="কাজটি পাওয়া যায়নি।")
        if job.get("status") != "completed":
            raise HTTPException(status_code=409, detail="ভিডিও প্রসেসিং এখনো সম্পন্ন হয়নি।")
        job_dir = Path(job["job_dir"])
    choices = {
        "video": (job_dir / "captioned_video.mp4", "video/mp4", "captioned_video.mp4"),
        "srt": (job_dir / "captions.srt", "application/x-subrip", "captions.srt"),
        "txt": (job_dir / "transcript.txt", "text/plain; charset=utf-8", "transcript.txt"),
    }
    if kind not in choices:
        raise HTTPException(status_code=400, detail="kind অবশ্যই video, srt অথবা txt হতে হবে।")
    path, media_type, filename = choices[kind]
    if not path.exists():
        raise HTTPException(status_code=404, detail="ফলাফলের ফাইল পাওয়া যায়নি।")
    return path, media_type, filename


@app.get("/jobs/{job_id}/stream")
def stream_video(job_id: str) -> FileResponse:
    path, media_type, filename = output_file(job_id, "video")
    return FileResponse(path, media_type=media_type, filename=filename)


@app.get("/jobs/{job_id}/download")
def download_output(job_id: str, kind: str = "video") -> FileResponse:
    path, media_type, filename = output_file(job_id, kind)
    return FileResponse(path, media_type=media_type, filename=filename)
