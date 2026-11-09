# AI Auto-Subtitle Generator

A local-first captioning workflow. The Flutter client uploads a video to a Windows PC backend. Faster-Whisper produces transcription and word timestamps; FFmpeg/libass burns active-word captions into an MP4.

Features: Bengali/English/Hindi/Urdu/Arabic auto or manual language; Tiny/Base/Small CPU models; Hormozi-inspired yellow, cyan and neon styles; MP4, SRT and transcript export; progress polling and preview; Android and Windows clients.

Backend setup: install Python 3.11/3.12 and FFmpeg/FFprobe, run backend/install_backend.bat, then backend/start_backend.bat. Open http://127.0.0.1:8000/health to check readiness. The first run downloads the selected Whisper model.

Build: install Flutter 3.38+, Android SDK/licenses and Visual Studio 2022 Desktop development with C++ for Windows. Run flutter_app/build_all.bat. APK is written to flutter_app/build/app/outputs/flutter-apk/app-release.apk. Windows portable files are in flutter_app/dist/Windows_Portable/; keep the whole folder together.

Android connection: connect PC and phone to the same Wi-Fi, find the PC Wi-Fi IPv4 address with ipconfig, then set the app URL to http://PC-IP:8000. Windows defaults to http://127.0.0.1:8000.

Tests: from backend/, run python -m unittest discover -s tests -v.

Security: the backend listens on 0.0.0.0:8000 for LAN access and has no authentication. Do not expose this port to the public internet. Job status is in memory and resets on restart; exported files stay in backend/data/jobs. Recognition accuracy depends on audio quality. Burned-in captions cannot be toggled off; use the SRT for edits.
