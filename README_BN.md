# AI Auto-Subtitle Generator (Android + Windows)

প্রজেক্টে দুটি অংশ আছে: backend হলো Python FastAPI + Faster-Whisper + FFmpeg সার্ভার; flutter_app হলো Android ও Windows-এর অ্যাপ। AI প্রসেসিং Windows PC-তে হবে। Android ফোন একই Wi-Fi দিয়ে PC-র সার্ভারে ভিডিও পাঠাবে।

## Windows Backend চালু করা

1. 64-bit Python 3.11 বা 3.12 ইনস্টল করো এবং Add Python to PATH নির্বাচন করো।
2. FFmpeg ও FFprobe ইনস্টল করো। PowerShell-এ চালাতে পারো: winget install -e --id Gyan.FFmpeg.Shared
3. backend ফোল্ডারে install_backend.bat চালাও।
4. এরপর start_backend.bat চালু রাখো। প্রথমবার Whisper Base model ডাউনলোড হবে।
5. Browser-এ http://127.0.0.1:8000/health খুলে ffmpeg_ready true আছে কি না দেখো।

## APK ও EXE Build

Flutter 3.38 বা নতুন stable version, Android Studio/Android SDK এবং Windows EXE-এর জন্য Visual Studio 2022 Desktop development with C++ লাগবে। flutter_app ফোল্ডারে build_all.bat চালাও।

APK: flutter_app/build/app/outputs/flutter-apk/app-release.apk
Windows portable: flutter_app/dist/Windows_Portable/
Windows ZIP: flutter_app/dist/AI_Auto_Subtitle_Generator_Windows_Portable.zip

Windows portable ফোল্ডারের সব DLL ও data ফাইল একসঙ্গে রাখতে হবে; শুধু EXE কপি করলে চলবে না।

## Android ফোনে ব্যবহার

PC ও ফোন একই Wi-Fi-তে রাখো। PC-তে ipconfig চালিয়ে Wi-Fi IPv4 address দেখো। অ্যাপে Backend URL হিসেবে http://PC-IP:8000 দাও, যেমন http://192.168.0.105:8000। Test চাপো। Windows অ্যাপে default URL http://127.0.0.1:8000। Firewall বাধা দিলে Private network-এ TCP 8000 allow করো।

## ফিচার

- Faster-Whisper-এর ইনস্টল করা multilingual tokenizer-এর সব ১০০টি সমর্থিত ভাষা; searchable language picker এবং Auto detect
- Tiny, Base ও Small Whisper মডেল
- Word-by-word active highlight; Hormozi-inspired, Cyan ও Neon theme
- H.264/AAC MP4 export, SRT এবং transcript
- Progress, preview, Android Gallery ও Windows save

## PC সেটিংস ও সীমাবদ্ধতা

Ryzen 5 2400G ও 8 GB RAM-এ Base model দিয়ে শুরু করো; বেশি গতি চাইলে Tiny। CPU processing হওয়ায় বড় ভিডিওতে সময় লাগবে। প্রথমবার model download করতে internet লাগবে।

Backend একই LAN-এ 0.0.0.0:8000-এ চলে এবং এতে login/token নেই। Router port-forward করে public internet-এ প্রকাশ কোরো না। Backend restart হলে job status memory থেকে মুছে যাবে; completed output backend/data/jobs-এ থাকে। Transcription accuracy audio quality-এর ওপর নির্ভর করে। Burned-in caption ভিডিও থেকে বন্ধ করা যায় না; আলাদা SRT edit করা যাবে।

API: GET /health, GET /languages (Whisper-এর পূর্ণ language list), POST /jobs, GET /jobs/{job_id}, GET /jobs/{job_id}/stream, GET /jobs/{job_id}/download?kind=video|srt|txt.

Backend test: backend ফোল্ডারে requirements install করার পর python -m unittest discover -s tests -v চালাও।
