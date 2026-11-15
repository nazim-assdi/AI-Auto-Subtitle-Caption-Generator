@echo off
setlocal
cd /d "%~dp0"
set "APP=flutter_app\dist\Windows_Portable\ai_auto_subtitle_generator.exe"
if not exist "%APP%" (
  echo [ERROR] Windows app build পাওয়া যায়নি।
  echo GitHub Actions-এর latest successful Windows build ZIP download করো।
  pause
  exit /b 1
)
if not exist "flutter_app\dist\Windows_Portable\backend_runtime\ai_subtitle_backend.exe" (
  echo [ERROR] Bundled Backend পাওয়া যায়নি। Self-contained Windows ZIP ব্যবহার করো।
  pause
  exit /b 1
)
echo AI Auto Subtitle Generator চালু হচ্ছে...
echo Backend app-এর সঙ্গে স্বয়ংক্রিয়ভাবে চালু হবে।
start "AI Auto Subtitle Generator" "%APP%"
exit /b 0
