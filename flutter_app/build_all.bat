@echo off
setlocal
cd /d "%~dp0"
where flutter >nul 2>nul
if errorlevel 1 (
  echo Flutter SDK PATH-এ পাওয়া যায়নি। Flutter install করে নতুন Terminal খুলো।
  pause
  exit /b 1
)
if not exist android\app\src\main\AndroidManifest.xml goto :create_platforms
if not exist windows\CMakeLists.txt goto :create_platforms
goto :platforms_ready
:create_platforms
echo Android ও Windows platform folder তৈরি হচ্ছে...
flutter create --platforms=android,windows --org com.najim.ai --project-name ai_auto_subtitle_generator .
if errorlevel 1 goto :error
:platforms_ready
powershell -NoProfile -ExecutionPolicy Bypass -File "..\tools\patch_android_manifest.ps1"
if errorlevel 1 goto :error
flutter pub get
if errorlevel 1 goto :error
echo.
echo ===== Android APK build =====
flutter build apk --release
if errorlevel 1 goto :error
echo.
echo ===== Windows EXE build =====
flutter build windows --release
if errorlevel 1 goto :error
if not exist dist mkdir dist
if exist dist\Windows_Portable rmdir /s /q dist\Windows_Portable
xcopy /e /i /y build\windows\x64\runner\Release dist\Windows_Portable >nul
powershell -NoProfile -Command "if (Test-Path 'dist\AI_Auto_Subtitle_Generator_Windows_Portable.zip') { Remove-Item 'dist\AI_Auto_Subtitle_Generator_Windows_Portable.zip' -Force }; Compress-Archive -Path 'dist\Windows_Portable\*' -DestinationPath 'dist\AI_Auto_Subtitle_Generator_Windows_Portable.zip' -Force"
echo BUILD SUCCESS!
echo APK: build\app\outputs\flutter-apk\app-release.apk
echo Windows portable folder: dist\Windows_Portable
echo Windows ZIP: dist\AI_Auto_Subtitle_Generator_Windows_Portable.zip
echo NOTE: Windows Release folder-এর সব ফাইল একসঙ্গে রাখতে হবে।
pause
exit /b 0
:error
echo Build ব্যর্থ হয়েছে। উপরের error দেখো।
pause
exit /b 1
