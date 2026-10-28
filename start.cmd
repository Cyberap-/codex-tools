@echo off
setlocal
set "MOCK_MODE=%~1"
if /i "%MOCK_MODE%"=="hosts" goto run
if /i "%MOCK_MODE%"=="s5" goto run
echo 1. HOSTS mode - local HTTPS on port 443, automatic hosts mapping
echo 2. SOCKS5 mode - proxy on 127.0.0.1:1089, no hosts changes
choice /c 12 /n /m "Select mode [1/2]: "
if errorlevel 2 (set "MOCK_MODE=s5") else (set "MOCK_MODE=hosts")
:run
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0manage.ps1" start -Mode %MOCK_MODE%
set "MOCK_EXIT=%ERRORLEVEL%"
if not "%MOCK_EXIT%"=="0" pause
exit /b %MOCK_EXIT%
