# AI Auto-Subtitle Generator (Android + Windows)

প্রজেক্টে দুটি অংশ আছে: backend হলো Python FastAPI + Faster-Whisper + FFmpeg সার্ভার; flutter_app হলো Android ও Windows-এর অ্যাপ। AI প্রসেসিং Windows PC-তে হবে। Android ফোন একই Wi-Fi দিয়ে PC-র সার্ভারে ভিডিও পাঠাবে।

## Windows Backend চালু করা

**এক-ক্লিকে চালাতে:** প্রথমবার backend install ও Windows app build শেষ হলে repository root-এর `launch_windows.bat` double-click করো। এটি Backend health check করে, বন্ধ থাকলে Backend চালু করে, FFmpeg/ASS readiness নিশ্চিত হওয়ার পর app খুলবে।

শুধু portable EXE আলাদাভাবে চালালে আগে `backend\\start_backend.bat` চালু রাখতে হবে।

1. 64-bit Python 3.11 বা 3.12 ইনস্টল করো এবং Add Python to PATH নির্বাচন করো।
2. FFmpeg ও FFprobe ইনস্টল করো। PowerShell-এ চালাতে পারো: winget install -e --id Gyan.FFmpeg.Shared
3. backend ফোল্ডারে install_backend.bat চালাও।
4. এরপর start_backend.bat চালু রাখো। প্রথমবার Whisper Base model ডাউনলোড হবে।
5. অ্যাপে Server-এর `Test` চাপো অথবা http://127.0.0.1:8000/health খুলে `ffmpeg_ready` ও `ass_filter_ready` দুটোই true কি না দেখো।
6. `ass_filter_ready` false হলে FFmpeg-এর libass/ASS filter নেই। PowerShell-এ `winget install -e --id Gyan.FFmpeg.Shared` চালাও, পুরোনো Terminal বন্ধ করে নতুন Terminal খুলে `start_backend.bat` চালাও।

## Processing error হলে

অ্যাপে `Test` চাপলে Backend, FFmpeg, FFprobe এবং ASS/libass subtitle renderer-এর অবস্থা আলাদা করে দেখাবে। Video processing ব্যর্থ হলে Job panel-এ আসল Backend error দেখা যাবে। `FFmpeg-এ ASS/libass filter নেই` দেখালে Gyan shared/full FFmpeg build install করে Backend restart করো।

## Offline Translation Model (ঐচ্ছিক)

Backend ফোল্ডারে একবার optional offline translation engine install করতে পারো। উদাহরণ:

```bat
install_translation_model.bat en bn
```

এখানে `en` হলো source language এবং `bn` হলো target language। অন্য ভাষার জন্য তাদের code ব্যবহার করো। সব ১০০টি speech-recognition language-এর Argos translation package নেই। কোন model install আছে তা `http://127.0.0.1:8000/translation/status` থেকে দেখা যাবে। একবার model install হলে অনুবাদ PC-তেই হবে।

## APK ও EXE Build

Flutter 3.38 বা নতুন stable version, Android Studio/Android SDK এবং Windows EXE-এর জন্য Visual Studio 2022 Desktop development with C++ লাগবে। flutter_app ফোল্ডারে build_all.bat চালাও।

APK: flutter_app/build/app/outputs/flutter-apk/app-release.apk
Windows portable: flutter_app/dist/Windows_Portable/
Windows ZIP: flutter_app/dist/AI_Auto_Subtitle_Generator_Windows_Portable.zip

Windows portable ফোল্ডারের সব DLL ও data ফাইল একসঙ্গে রাখতে হবে; শুধু EXE কপি করলে চলবে না।

## Android ফোনে ব্যবহার

PC ও ফোন একই Wi-Fi-তে রাখো। PC-তে ipconfig চালিয়ে Wi-Fi IPv4 address দেখো। অ্যাপে Backend URL হিসেবে http://PC-IP:8000 দাও, যেমন http://192.168.0.105:8000। Test চাপো। Windows অ্যাপে default URL http://127.0.0.1:8000। Firewall বাধা দিলে Private network-এ TCP 8000 allow করো।

## Professional Creator Studio Dashboard

- Create Project-এ guided 3-step workflow, source video card এবং ছয়টি clickable visual caption preset
- Export Center-এ 16:9 video preview, responsive asset grid, format labels এবং ZIP project bundle
- Settings-এ backend endpoint, connection diagnostics এবং runtime overview
- Render status-এ animated progress, model ও language metadata

- Desktop-এ animated professional left sidebar; Android/ছোট screen-এ floating bottom navigation dock
- Gradient glass-style cards, ambient grid background, refined AI engine status pill, animated KPI ও page transitions
- চারটি আলাদা workspace: Overview, New Project, Export Center, Settings
- Overview dashboard-এ project status, language/AI status cards, recent project ও quick actions
- New Project-এ video source এবং caption settings আলাদা panel-এ
- Export Center-এ video preview, file downloads এবং Creator Pulse এক জায়গায়
- Settings-এ backend connection ও local AI runtime information

## Creator Studio ফিচার

- Faster-Whisper-এর ইনস্টল করা multilingual tokenizer-এর সব ১০০টি সমর্থিত ভাষা; searchable language picker এবং Auto detect
- Tiny, Base ও Small Whisper মডেল
- Word-by-word active highlight; Hormozi-inspired, Cyan ও Neon theme
- Editable transcript, Creator Vocabulary Boost, Creator Pulse report (pace, pause, filler-word hints, review words, hook suggestions)
- Export Center: MP4, SRT, WebVTT, ASS, SSA, YouTube SBV, TXT, Timecoded TXT, CSV, TSV, Excel XLSX, Word DOCX, Markdown, HTML, Project JSON এবং Creator Report
- Optional offline translated SRT/VTT ও bilingual SRT (Argos model install থাকলে)
- Progress, preview, Android Gallery ও Windows save

## Export Center

ভিডিও render শেষ হলে Export Center থেকে প্রয়োজনীয় ফাইল আলাদাভাবে Download করতে পারবে।

- Subtitle: SRT, VTT, ASS, SSA, SBV
- Spreadsheet: Excel XLSX (Captions, Word Timing ও Creator Pulse sheet), CSV, TSV
- Document/Text: Word DOCX, TXT, Timecoded TXT, Markdown, HTML
- Data: Project JSON ও Creator Report JSON
- All Exports ZIP: সব subtitle, transcript, Excel ও Word export একসঙ্গে

## PC সেটিংস ও সীমাবদ্ধতা

Ryzen 5 2400G ও 8 GB RAM-এ Base model দিয়ে শুরু করো; বেশি গতি চাইলে Tiny। CPU processing হওয়ায় বড় ভিডিওতে সময় লাগবে। প্রথমবার model download করতে internet লাগবে।

Backend একই LAN-এ 0.0.0.0:8000-এ চলে এবং এতে login/token নেই। Router port-forward করে public internet-এ প্রকাশ কোরো না। Backend restart হলে job status memory থেকে মুছে যাবে; completed output backend/data/jobs-এ থাকে। Transcription accuracy audio quality-এর ওপর নির্ভর করে। Burned-in caption ভিডিও থেকে বন্ধ করা যায় না; আলাদা SRT edit করা যাবে।

API: GET /health, GET /languages (Whisper-এর পূর্ণ language list), POST /jobs, GET /jobs/{job_id}, GET /jobs/{job_id}/stream, GET /jobs/{job_id}/download?kind=video|srt|vtt|ass|ssa|sbv|txt|timecoded-txt|csv|tsv|xlsx|docx|md|html|json|insights|all-exports.

Backend test: backend ফোল্ডারে requirements install করার পর python -m unittest discover -s tests -v চালাও।
