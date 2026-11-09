@echo off
setlocal
cd /d "%~dp0"
where python >nul 2>nul
if errorlevel 1 (
  echo Python পাওয়া যায়নি। Python 3.11 বা 3.12 (64-bit) install করে আবার চালাও।
  pause
  exit /b 1
)
python -c "import sys; print('Python', sys.version); raise SystemExit(0 if sys.version_info[:2] in ((3, 11), (3, 12)) else 1)"
if errorlevel 1 (
  echo এই backend-এর জন্য Python 3.11 বা 3.12 (64-bit) প্রয়োজন।
  pause
  exit /b 1
)
if not exist .venv (
  python -m venv .venv
  if errorlevel 1 goto :error
)
call .venv\Scripts\activate.bat
python -m pip install --upgrade pip
pip install -r requirements.txt
if errorlevel 1 goto :error
where ffmpeg >nul 2>nul
if errorlevel 1 (
  echo FFmpeg পাওয়া যায়নি। PowerShell-এ চালাও: winget install -e --id Gyan.FFmpeg.Shared
) else (
  ffmpeg -version | findstr /r /c:"ffmpeg version"
  ffprobe -version | findstr /r /c:"ffprobe version"
)
echo Backend setup সম্পন্ন। এখন start_backend.bat চালাও।
pause
exit /b 0
:error
echo Setup ব্যর্থ হয়েছে। উপরের error দেখো।
pause
exit /b 1
