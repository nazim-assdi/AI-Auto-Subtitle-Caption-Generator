# AI Auto-Subtitle Generator

A local-first captioning workflow. The Flutter client uploads a video to a Windows PC backend. Faster-Whisper produces transcription and word timestamps; FFmpeg/libass burns active-word captions into an MP4.

Features: all 100 language codes exposed by the installed multilingual Whisper tokenizer; vocabulary hints; editable transcript and re-render; Creator Pulse metrics; six caption styles; Export Center for MP4, SRT, VTT, ASS, SSA, SBV, TXT, timed TXT, CSV, TSV, Excel XLSX, Word DOCX, Markdown, HTML and JSON; one ZIP containing all transcript exports; optional offline translation; Android and Windows clients.

Windows one-click launch: after first-time setup and app build, run repository-root `launch_windows.bat`; it starts/checks the local backend and opens the Windows app only after the API reports ready. If running the portable EXE directly, start `backend/start_backend.bat` first. Backend setup: install Python 3.11/3.12 and FFmpeg/FFprobe, run backend/install_backend.bat. Open http://127.0.0.1:8000/health to check readiness. The first run downloads the selected Whisper model.

Processing diagnostics: press `Test` in the app. `GET /health` reports `ffmpeg_ready` and `ass_filter_ready`. Both must be true. If the ASS filter is missing, install a libass-enabled FFmpeg build (Windows: `winget install -e --id Gyan.FFmpeg.Shared`), open a new terminal and restart the backend. The app shows the detailed job error instead of silently placing a failure message in the server-status line.

Optional offline translation: from `backend/`, run `install_translation_model.bat en bn` to install an English-to-Bengali Argos model route (replace the language codes as required). Once installed, subtitle translation runs locally. Not every Whisper recognition language has an Argos translation package; see `GET /translation/status` for installed pairs.

Build: install Flutter 3.38+, Android SDK/licenses and Visual Studio 2022 Desktop development with C++ for Windows. Run flutter_app/build_all.bat. APK is written to flutter_app/build/app/outputs/flutter-apk/app-release.apk. Windows portable files are in flutter_app/dist/Windows_Portable/; keep the whole folder together.

Android connection: connect PC and phone to the same Wi-Fi, find the PC Wi-Fi IPv4 address with ipconfig, then set the app URL to http://PC-IP:8000. Windows defaults to http://127.0.0.1:8000.

Tests: from backend/, run python -m unittest discover -s tests -v.

Security: the backend listens on 0.0.0.0:8000 for LAN access and has no authentication. Do not expose this port to the public internet. Job status is in memory and resets on restart; exported files stay in backend/data/jobs. Recognition accuracy depends on audio quality. Burned-in captions cannot be toggled off; use the SRT for edits.
