@echo off
setlocal
cd /d "%~dp0"
if "%~1"=="" goto :usage
if "%~2"=="" goto :usage
if not exist .venv\Scripts\activate.bat (
  echo আগে install_backend.bat চালাও।
  pause
  exit /b 1
)
call .venv\Scripts\activate.bat
pip install -r requirements-translation.txt
if errorlevel 1 goto :error
python install_translation_model.py "%~1" "%~2"
if errorlevel 1 goto :error
pause
exit /b 0
:usage
echo Usage: install_translation_model.bat source-code target-code
echo Example: install_translation_model.bat en bn
echo Source code পাওয়া যাবে Creator Pulse-এর detected language থেকে।
pause
exit /b 2
:error
echo Translation model install ব্যর্থ হয়েছে।
pause
exit /b 1
