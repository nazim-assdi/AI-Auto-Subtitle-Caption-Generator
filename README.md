# AI Auto-Subtitle Generator

Local-first AI video captioning for Android and Windows. Flutter uploads a video to a Python FastAPI backend running on the PC; Faster-Whisper transcribes speech and FFmpeg burns animated word-highlight captions into an MP4.

- All 100 language codes exposed by the installed multilingual Whisper tokenizer; searchable language picker and automatic language detection
- Word-level timing and active-word highlight
- Hormozi-inspired yellow, cyan and neon caption themes
- MP4 with burned-in captions, separate SRT and transcript downloads
- Live progress, preview and Android/Windows export

See [Product Vision](PRODUCT_VISION.md) for the design direction. Start with [Bangla instructions](README_BN.md) or the [English guide](README_EN.md).

Backend: Python 3.11/3.12, FastAPI, Faster-Whisper, FFmpeg. Client: Flutter 3.38+, Android and Windows.
