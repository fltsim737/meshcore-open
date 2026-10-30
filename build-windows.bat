@echo off
rem Builds MeshCore Open SOS for Windows: double-click this file.
rem Makes build\windows\installer\MeshCore-Open-SOS-<version>-Windows-portable.zip (unzip and run, no install)
rem and, with Inno Setup 6 installed, build\windows\installer\MeshCore-Open-SOS-Setup.exe.
rem The tools it needs are listed in README-WINDOWS.txt.
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File windows\installer\build-windows.ps1
set RESULT=%ERRORLEVEL%
echo.
if %RESULT% neq 0 (echo The build stopped: see the messages above.) else (echo Finished. The files are in build\windows\installer)
pause
exit /b %RESULT%
