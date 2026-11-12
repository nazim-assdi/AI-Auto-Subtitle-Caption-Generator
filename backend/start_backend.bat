@echo off
setlocal
cd /d "%~dp0"
if not exist .venv\Scripts\activate.bat (
  echo আগে install_backend.bat চালাতে হবে।
  pause
  exit /b 1
)
call .venv\Scripts\activate.bat
if not defined MAX_UPLOAD_MB set MAX_UPLOAD_MB=500
if not defined CPU_THREADS set CPU_THREADS=4
where ffmpeg >nul 2>nul
if errorlevel 1 (
  echo FFmpeg পাওয়া যায়নি। FFmpeg install করে PATH ঠিক করো।
  pause
  exit /b 1
)
echo AI Subtitle API চালু হচ্ছে: http://127.0.0.1:8000
echo ফোনে ব্যবহার করতে PC ও ফোন একই Wi-Fi-তে রাখো এবং PC-এর LAN IP ব্যবহার করো।
echo বন্ধ করতে Ctrl+C চাপো।
python -m uvicorn main:app --host 0.0.0.0 --port 8000
pause
