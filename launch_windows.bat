@echo off
setlocal
cd /d "%~dp0"
if not exist backend\.venv\Scripts\activate.bat (
  echo আগে backend\install_backend.bat চালাও।
  pause
  exit /b 1
)
if not exist flutter_app\dist\Windows_Portable\ai_auto_subtitle_generator.exe (
  echo আগে flutter_app\build_all.bat চালিয়ে Windows build তৈরি করো।
  pause
  exit /b 1
)
start "AI Subtitle Backend" cmd /k "cd /d ""%~dp0backend"" && call start_backend.bat"
timeout /t 3 /nobreak >nul
start "AI Auto Subtitle Generator" "%~dp0flutter_app\dist\Windows_Portable\ai_auto_subtitle_generator.exe"
