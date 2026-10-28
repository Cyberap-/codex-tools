@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0manage.ps1" stop
set "MOCK_EXIT=%ERRORLEVEL%"
if not "%MOCK_EXIT%"=="0" pause
exit /b %MOCK_EXIT%
