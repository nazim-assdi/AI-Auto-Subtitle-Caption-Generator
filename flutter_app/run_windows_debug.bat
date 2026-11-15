@echo off
setlocal
cd /d "%~dp0"
where flutter >nul 2>nul
if errorlevel 1 (
  echo Flutter SDK PATH-এ পাওয়া যায়নি।
  pause
  exit /b 1
)
if not exist windows\CMakeLists.txt (
  flutter create --platforms=android,windows --org com.najim.ai --project-name ai_auto_subtitle_generator .
)
powershell -NoProfile -ExecutionPolicy Bypass -File "..\tools\patch_android_manifest.ps1"
flutter pub get
flutter run -d windows
