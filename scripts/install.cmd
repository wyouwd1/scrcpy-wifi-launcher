@echo off
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\install.ps1" %*
set "RC=%ERRORLEVEL%"
echo.
pause
exit /b %RC%
