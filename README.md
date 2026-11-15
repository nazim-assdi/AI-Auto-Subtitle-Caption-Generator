# AI Auto-Subtitle Generator

Local-first AI video captioning for Android and Windows. Flutter uploads a video to a Python FastAPI backend running on the PC; Faster-Whisper transcribes speech and FFmpeg burns animated word-highlight captions into an MP4.

- All 100 language codes exposed by the installed multilingual Whisper tokenizer; searchable language picker and automatic language detection
- Word-level timing and active-word highlight
- Export Center: Excel XLSX, Word DOCX, CSV, TSV, SRT, VTT, ASS, SSA, SBV, TXT, Markdown, HTML and JSON
- Hormozi-inspired yellow, cyan and neon caption themes
- MP4 with burned-in captions, separate SRT and transcript downloads
- Live progress, preview and Android/Windows export

## Creator Studio Dashboard

Premium responsive dashboard with Overview, New Project, Export Center and Settings workspaces. Desktop uses an animated sidebar; Android uses a floating bottom navigation dock. Visual system includes an ambient grid backdrop, gradient glass-style cards, refined AI engine health badge, animated KPI cards, an editorial hero panel and smooth page transitions. The creation workspace adds a guided three-step flow, a source-video card and visual caption-style presets. The export library provides a widescreen video preview, compact downloadable asset cards, a complete ZIP bundle and responsive empty states. Settings includes an adaptive backend endpoint panel and runtime diagnostics.

## Windows launch

After first-time backend setup and Windows build, double-click launch_windows.bat from the repository root. It starts/checks the backend and opens the Windows app only after /health confirms FFmpeg and ASS subtitle rendering are ready.

If you launch the portable EXE directly, first run backend/start_backend.bat and keep its terminal open.

See Product Vision for the design direction. Start with Bangla instructions (README_BN.md) or the English guide (README_EN.md).

Backend: Python 3.11/3.12, FastAPI, Faster-Whisper, FFmpeg. Client: Flutter 3.38+, Android and Windows.


## Subtitle output language and typeface

The Create workflow separates **Recognition language** (the spoken audio) from **Subtitle output language** (the language rendered into the video and subtitle files). Choose **Same as spoken language** to keep the original transcript, or choose another language to translate the cues before the video and SRT/VTT exports are rendered. Translation requires the corresponding Argos offline language pair to be installed; otherwise the job reports the missing pair rather than silently producing the wrong language.

The caption font selector offers Segoe UI, Arial, Nirmala UI, Verdana, Georgia, Impact, Tahoma and Trebuchet MS. The selected font is embedded in the ASS subtitle style used to burn captions into the MP4 and is retained when the transcript is edited and re-rendered. The app interface uses an English-first Segoe UI/Roboto system typeface and animated page-title, headline and processing-stage transitions.
