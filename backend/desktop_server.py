"""Windows desktop entry point for the bundled, self-contained API server."""
from __future__ import annotations

import os
import sys
from pathlib import Path


def configure_runtime() -> None:
    executable_dir = Path(sys.executable).resolve().parent
    ffmpeg_dir = executable_dir / "ffmpeg"
    if ffmpeg_dir.is_dir():
        os.environ["PATH"] = str(ffmpeg_dir) + os.pathsep + os.environ.get("PATH", "")
    local_app_data = Path(os.environ.get("LOCALAPPDATA", Path.home() / "AppData" / "Local"))
    data_dir = local_app_data / "AI Auto Subtitle Generator"
    data_dir.mkdir(parents=True, exist_ok=True)
    os.environ["AI_SUBTITLE_DATA_DIR"] = str(data_dir)
    os.environ.setdefault("MAX_UPLOAD_MB", "500")
    os.environ.setdefault("CPU_THREADS", str(max(1, min(os.cpu_count() or 4, 4))))


def main() -> None:
    configure_runtime()
    import uvicorn
    import main as backend

    uvicorn.run(backend.app, host="127.0.0.1", port=8000, log_level="warning", access_log=False)


if __name__ == "__main__":
    main()
