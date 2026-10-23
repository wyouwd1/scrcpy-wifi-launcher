@echo off
setlocal EnableExtensions EnableDelayedExpansion
cd /d "%~dp0"
title scrcpy launcher

rem ============================================================
rem scrcpy launcher - WiFi auto-discovery candidate
rem ASCII only / CRLF. No destructive commands.
rem ============================================================

set "SCRCPY=%~dp0scrcpy.exe"
set "ADB=%~dp0adb.exe"
set "WIFI_PS1=%~dp0wifi-discover.ps1"
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PS%" set "PS=powershell.exe"
set "RC=0"
set "DO_PAUSE=1"
set "DO_WIFI=1"
set "COUNT=0"
set "UNAUTH=0"
set "OFFLINE=0"
set "USB="
set "FIRST="
set "SERIAL="
set "SERNAME="
set "WIFI_ENDPOINT="
set "WIFI_SOURCE="
set "WIFI_RC=0"
set "WIFI_LAST_ERR="
set "WIFI_PORT=5555"
if defined SCRCPY_WIFI_PORT set "WIFI_PORT=%SCRCPY_WIFI_PORT%"
set "ARGS=%*"

rem --no-pause is a launcher switch; never forward it to scrcpy.
set "CHECK=!ARGS:"=!"
set "CHECK= !CHECK! "
if not "!CHECK: --no-pause =!"=="!CHECK!" (
    set "DO_PAUSE=0"
    set "ARGS=!ARGS:--no-pause=!"
)
if /i "%SCRCPY_NO_PAUSE%"=="1" set "DO_PAUSE=0"

rem --no-wifi is a launcher switch; SCRCPY_NO_WIFI=1 has the same effect.
if not "!CHECK: --no-wifi =!"=="!CHECK!" (
    set "DO_WIFI=0"
    set "SCRCPY_CONN=usb"
    set "ARGS=!ARGS:--no-wifi=!"
)
if /i "%SCRCPY_NO_WIFI%"=="1" set "SCRCPY_CONN=usb"

rem --wifi forces WiFi discovery without showing the menu.
if not "!CHECK: --wifi =!"=="!CHECK!" (
    set "SCRCPY_CONN=wifi"
    set "ARGS=!ARGS:--wifi=!"
)

rem Fast path: help/version do not need a device.
set "WANT_HELP=0"
if not "!CHECK: --help =!"=="!CHECK!" set "WANT_HELP=1"
if not "!CHECK: -h =!"=="!CHECK!" set "WANT_HELP=1"
if not "!CHECK: --version =!"=="!CHECK!" set "WANT_HELP=1"
if not "!CHECK: -v =!"=="!CHECK!" set "WANT_HELP=1"

if not exist "%SCRCPY%" goto :err_scrcpy_missing
if "%WANT_HELP%"=="1" goto :run_help
if not exist "%ADB%" goto :err_adb_missing

rem Start adb server and fail loudly if it cannot start.
"%ADB%" start-server >nul 2>&1
if errorlevel 1 goto :err_adb_server

rem Explicit SCRCPY_SERIAL wins and must be validated. No fallback.
if defined SCRCPY_SERIAL goto :explicit_serial

rem Let the user pick the transport. Default is USB because Wi-Fi can lag.
rem Non-interactive runs (--no-pause) skip the prompt and use USB unless
rem SCRCPY_CONN or --wifi says otherwise.
if not defined SCRCPY_CONN (
    if "%DO_PAUSE%"=="1" (
        call :choose_connection
    ) else (
        set "SCRCPY_CONN=usb"
    )
)
if /i "%SCRCPY_CONN%"=="usb" goto :usb_select
if /i "%SCRCPY_CONN%"=="wifi" goto :wifi_first
echo [ERROR] invalid SCRCPY_CONN="%SCRCPY_CONN%" ^(expected wifi or usb^)
set "RC=1"
goto :finish_error

:wifi_first
call :try_wifi
if defined WIFI_ENDPOINT (
    set "SERIAL=%WIFI_ENDPOINT%"
    set "SERNAME=WIFI"
    goto :select_done
)
echo [INFO] WiFi not available; falling back to USB device selection

:usb_select
rem Auto-select: count device/unauthorized/offline; prefer USB.
for /f "skip=1 tokens=1,2" %%A in ('adb.exe devices 2^>nul') do (
    if /i "%%B"=="device" (
        set /a COUNT+=1
        if not defined FIRST set "FIRST=%%A"
        set "CUR=%%A"
        if "!CUR::=!"=="!CUR!" if "!CUR:.=!"=="!CUR!" if /i not "!CUR:~0,9!"=="emulator-" if not defined USB set "USB=%%A"
    )
    if /i "%%B"=="unauthorized" set /a UNAUTH+=1
    if /i "%%B"=="offline" set /a OFFLINE+=1
)

if defined USB (
    set "SERIAL=!USB!"
    set "SERNAME=USB"
)
if not defined SERIAL (
    if defined FIRST (
        set "SERIAL=!FIRST!"
        set "SERNAME=AUTO"
    )
)
if not defined SERIAL goto :err_no_device
goto :select_done

rem ------------------------------------------------------------
rem Connection picker. 1=WiFi, 2=USB (default), Q=quit.
rem ------------------------------------------------------------
:choose_connection
echo.
echo ===============================
echo   Select connection
echo ===============================
echo   1. WiFi  - auto discover ^(may lag^)
echo   2. USB   - cable, smoother  [default]
echo   Q. Quit
echo.
choice /c 12q /n /t 15 /d 2 /m "Choice [1/2/Q], default 2 in 15s: "
if "%ERRORLEVEL%"=="3" goto :cancelled
if "%ERRORLEVEL%"=="1" (
    set "SCRCPY_CONN=wifi"
    exit /b 0
)
rem 2 = USB; any choice failure (no console attached) also falls back to USB.
set "SCRCPY_CONN=usb"
exit /b 0

rem ------------------------------------------------------------
rem WiFi discovery helper. Sets WIFI_ENDPOINT/WIFI_SOURCE on success.
rem ------------------------------------------------------------
:try_wifi
if not exist "%WIFI_PS1%" (
    echo [WARN] wifi-discover.ps1 not found; skipping WiFi auto-discovery
    exit /b 0
)
set "WIFI_TMP=%TEMP%\scrcpy-wifi-%RANDOM%-%RANDOM%.txt"
set "WIFI_ERR=%TEMP%\scrcpy-wifi-err-%RANDOM%-%RANDOM%.txt"
echo [INFO] Searching for a WiFi device (up to 14s; use --no-wifi to skip)
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%WIFI_PS1%" -AdbPath "%ADB%" -Port "%WIFI_PORT%" -TimeoutSec 5 > "%WIFI_TMP%" 2> "%WIFI_ERR%"
set "WIFI_RC=%ERRORLEVEL%"
if exist "%WIFI_TMP%" (
    for /f "usebackq tokens=1,* delims==" %%A in ("%WIFI_TMP%") do (
        if /i "%%A"=="WIFI_ENDPOINT" set "WIFI_ENDPOINT=%%B"
        if /i "%%A"=="WIFI_SOURCE" set "WIFI_SOURCE=%%B"
    )
    del /f /q "%WIFI_TMP%" >nul 2>&1
)
if not "%WIFI_RC%"=="0" (
    if exist "%WIFI_ERR%" (
        for /f "usebackq delims=" %%L in ("%WIFI_ERR%") do set "WIFI_LAST_ERR=%%L"
        if defined WIFI_LAST_ERR echo [INFO] WiFi helper: !WIFI_LAST_ERR!
        del /f /q "%WIFI_ERR%" >nul 2>&1
    )
    set "WIFI_ENDPOINT="
    set "WIFI_SOURCE="
)
if exist "%WIFI_ERR%" del /f /q "%WIFI_ERR%" >nul 2>&1
exit /b 0

:explicit_serial
set "SERIAL=%SCRCPY_SERIAL%"
set "STATE="
for /f "delims=" %%S in ('adb.exe -s "%SERIAL%" get-state 2^>nul') do set "STATE=%%S"
if /i not "%STATE%"=="device" (
    echo [ERROR] SCRCPY_SERIAL="%SERIAL%" is not online ^(adb get-state: %STATE%^)
    echo [ERROR] fix or unset SCRCPY_SERIAL; no automatic fallback
    "%ADB%" devices
    set "RC=1"
    goto :finish_error
)
set "SERNAME=OVERRIDE"

:select_done
echo ===============================
echo   scrcpy launcher (MOD = Alt)
echo ===============================
if /i "%SERNAME%"=="OVERRIDE" (
    echo [INFO] selected by SCRCPY_SERIAL: %SERIAL%
) else (
    if /i "%SERNAME%"=="WIFI" (
        echo [INFO] selected WiFi endpoint: %SERIAL%   source: %WIFI_SOURCE%
    ) else (
        echo [INFO] online devices: %COUNT%   selected: %SERNAME%  %SERIAL%
        echo [INFO] device states: device=%COUNT% unauthorized=%UNAUTH% offline=%OFFLINE%
        if %COUNT% GTR 1 echo [INFO] multiple devices online, set SCRCPY_SERIAL to choose
    )
)
echo [INFO] Alt+o screen off, Alt+Shift+o screen on, Alt+p power
echo.

set "WIDTH=%SCRCPY_WIDTH%"
if not defined WIDTH set "WIDTH=580"
set "HEIGHT=%SCRCPY_HEIGHT%"
if not defined HEIGHT set "HEIGHT=1264"

rem Interactive double-click: let scrcpy keep the window only on error.
rem Official scrcpy option --pause-on-exit=if-error; no unconditional pause.
set "PAUSE_ARG="
if "%DO_PAUSE%"=="1" set "PAUSE_ARG=--pause-on-exit=if-error"

"%SCRCPY%" -s "%SERIAL%" "--window-width=%WIDTH%" "--window-height=%HEIGHT%" %PAUSE_ARG% %ARGS%
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" echo [ERROR] scrcpy exited with code %RC%
exit /b %RC%

:run_help
"%SCRCPY%" %ARGS%
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" echo [ERROR] scrcpy exited with code %RC%
exit /b %RC%

:cancelled
echo [INFO] cancelled by user
exit /b 0

:err_scrcpy_missing
echo [ERROR] scrcpy.exe not found: "%SCRCPY%"
set "RC=1"
goto :finish_error

:err_adb_missing
echo [ERROR] adb.exe not found: "%ADB%"
set "RC=1"
goto :finish_error

:err_adb_server
echo [ERROR] failed to start adb server
set "RC=1"
goto :finish_error

:err_no_device
echo [ERROR] no adb device in "device" state
echo [INFO] online=device: %COUNT%   unauthorized: %UNAUTH%   offline: %OFFLINE%
if "%DO_WIFI%"=="1" (
    echo [INFO] WiFi auto-discovery found no usable endpoint.
    echo [INFO] First use: enable Wireless debugging on the phone, or connect USB once.
) else (
    echo [INFO] WiFi auto-discovery was disabled by --no-wifi or SCRCPY_NO_WIFI=1.
    echo [INFO] Enable Wireless debugging first, or connect USB once to enable adb tcpip.
)
echo [INFO] Pairing: adb pair ^<phone-ip^>:^<pair-port^> then enter the code shown on the phone.
"%ADB%" devices
set "RC=1"
goto :finish_error

:finish_error
if "%DO_PAUSE%"=="1" pause
exit /b %RC%
