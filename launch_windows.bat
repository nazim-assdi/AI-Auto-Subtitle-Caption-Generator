@echo off
setlocal
cd /d "%~dp0"

if not exist backend\.venv\Scripts\activate.bat (
  echo [ERROR] Python backend install করা হয়নি।
  echo প্রথমবার: backend\install_backend.bat চালাও।
  pause
  exit /b 1
)

if not exist flutter_app\dist\Windows_Portable\ai_auto_subtitle_generator.exe (
  echo [ERROR] Windows app build পাওয়া যায়নি।
  echo flutter_app\build_all.bat চালিয়ে Windows build তৈরি করো।
  pause
  exit /b 1
)

echo AI Auto-Subtitle Creator Studio চালু হচ্ছে...

powershell -NoProfile -ExecutionPolicy Bypass -Command "try { $h=Invoke-RestMethod -Uri 'http://127.0.0.1:8000/health' -TimeoutSec 2; if ($h.ok -and $h.ffmpeg_ready -and $h.ass_filter_ready) { exit 0 } } catch {}; exit 1"
if errorlevel 1 (
  echo Backend চালু করা হচ্ছে...
  start "AI Subtitle Backend" cmd /k "cd /d ""%~dp0backend"" && call start_backend.bat"
) else (
  echo Backend ইতিমধ্যেই চালু আছে।
)

echo Backend readiness পরীক্ষা হচ্ছে...
powershell -NoProfile -ExecutionPolicy Bypass -Command "$deadline=(Get-Date).AddSeconds(90); while ((Get-Date) -lt $deadline) { try { $h=Invoke-RestMethod -Uri 'http://127.0.0.1:8000/health' -TimeoutSec 3; if ($h.ok -and $h.ffmpeg_ready -and $h.ass_filter_ready) { exit 0 }; if (-not $h.ffmpeg_ready) { Write-Host 'FFmpeg/FFprobe পাওয়া যায়নি.'; exit 2 }; if (-not $h.ass_filter_ready) { Write-Host 'FFmpeg ASS/libass filter পাওয়া যায়নি.'; exit 3 } } catch {}; Start-Sleep -Seconds 2 }; exit 1"
if errorlevel 1 (
  echo.
  echo [ERROR] Backend ready হয়নি।
  echo Backend Terminal-এ error দেখো। FFmpeg, FFprobe ও ASS/libass filter check করো।
  echo Browser-এ http://127.0.0.1:8000/health খুলে diagnostics দেখো।
  pause
  exit /b 1
)

echo Backend প্রস্তুত। Windows app চালু হচ্ছে...
start "AI Auto Subtitle Creator Studio" "%~dp0flutter_app\dist\Windows_Portable\ai_auto_subtitle_generator.exe"
exit /b 0
