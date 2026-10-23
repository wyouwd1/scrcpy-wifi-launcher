@echo off
setlocal EnableExtensions EnableDelayedExpansion
cd /d "%~dp0"
title scrcpy 启动器

rem ============================================================
rem scrcpy 启动器 - WiFi 自动发现候选
rem 本文件使用 GBK 编码 / CRLF 换行。不含破坏性命令。
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

rem --no-pause 是启动器开关，绝不透传给 scrcpy。
set "CHECK=!ARGS:"=!"
set "CHECK= !CHECK! "
if not "!CHECK: --no-pause =!"=="!CHECK!" (
    set "DO_PAUSE=0"
    set "ARGS=!ARGS:--no-pause=!"
)
if /i "%SCRCPY_NO_PAUSE%"=="1" set "DO_PAUSE=0"

rem --no-wifi 是启动器开关；SCRCPY_NO_WIFI=1 效果相同。
if not "!CHECK: --no-wifi =!"=="!CHECK!" (
    set "DO_WIFI=0"
    set "SCRCPY_CONN=usb"
    set "ARGS=!ARGS:--no-wifi=!"
)
if /i "%SCRCPY_NO_WIFI%"=="1" set "SCRCPY_CONN=usb"

rem --wifi 强制走 WiFi 发现，不显示菜单。
if not "!CHECK: --wifi =!"=="!CHECK!" (
    set "SCRCPY_CONN=wifi"
    set "ARGS=!ARGS:--wifi=!"
)

rem 快速路径：--help/--version 不需要设备。
set "WANT_HELP=0"
if not "!CHECK: --help =!"=="!CHECK!" set "WANT_HELP=1"
if not "!CHECK: -h =!"=="!CHECK!" set "WANT_HELP=1"
if not "!CHECK: --version =!"=="!CHECK!" set "WANT_HELP=1"
if not "!CHECK: -v =!"=="!CHECK!" set "WANT_HELP=1"

if not exist "%SCRCPY%" goto :err_scrcpy_missing
if "%WANT_HELP%"=="1" goto :run_help
if not exist "%ADB%" goto :err_adb_missing

rem 启动 adb server，失败时明确报错。
"%ADB%" start-server >nul 2>&1
if errorlevel 1 goto :err_adb_server

rem SCRCPY_SERIAL 优先且必须校验；不自动回退。
if defined SCRCPY_SERIAL goto :explicit_serial

rem 让用户选择连接方式。默认 USB，因为 WiFi 可能卡顿。
rem 非交互运行（--no-pause）跳过菜单直接用 USB，
rem 除非 SCRCPY_CONN 或 --wifi 另有指定。
if not defined SCRCPY_CONN (
    if "%DO_PAUSE%"=="1" (
        call :choose_connection
    ) else (
        set "SCRCPY_CONN=usb"
    )
)
if /i "%SCRCPY_CONN%"=="usb" goto :usb_select
if /i "%SCRCPY_CONN%"=="wifi" goto :wifi_first
echo [错误] SCRCPY_CONN="%SCRCPY_CONN%" 无效（应为 wifi 或 usb）
set "RC=1"
goto :finish_error

:wifi_first
call :try_wifi
if defined WIFI_ENDPOINT (
    set "SERIAL=%WIFI_ENDPOINT%"
    set "SERNAME=WIFI"
    goto :select_done
)
echo [信息] WiFi 不可用，回退到 USB 设备选择

:usb_select
rem 自动选择：统计 device/unauthorized/offline，优先 USB。
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
rem 连接方式选择菜单：1=WiFi，2=USB（默认），Q=退出。
rem ------------------------------------------------------------
:choose_connection
echo.
echo ===============================
echo   选择连接方式
echo ===============================
echo   1. WiFi  - 自动发现（可能较慢）
echo   2. USB   - 数据线，更流畅  [默认]
echo   Q. 退出
echo.
choice /c 12q /n /t 15 /d 2 /m "请选择 [1/2/Q]，15 秒内不操作默认 2："
if "%ERRORLEVEL%"=="3" goto :cancelled
if "%ERRORLEVEL%"=="1" (
    set "SCRCPY_CONN=wifi"
    exit /b 0
)
rem 2 = USB；选择失败（无控制台）也回退到 USB。
set "SCRCPY_CONN=usb"
exit /b 0

rem ------------------------------------------------------------
rem WiFi 发现辅助脚本。成功时设置 WIFI_ENDPOINT/WIFI_SOURCE。
rem ------------------------------------------------------------
:try_wifi
if not exist "%WIFI_PS1%" (
    echo [警告] 未找到 wifi-discover.ps1，跳过 WiFi 自动发现
    exit /b 0
)
set "WIFI_TMP=%TEMP%\scrcpy-wifi-%RANDOM%-%RANDOM%.txt"
set "WIFI_ERR=%TEMP%\scrcpy-wifi-err-%RANDOM%-%RANDOM%.txt"
echo [信息] 正在搜索 WiFi 设备（最多 14 秒；可用 --no-wifi 跳过）
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
        if defined WIFI_LAST_ERR echo [信息] WiFi 发现：!WIFI_LAST_ERR!
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
    echo [错误] SCRCPY_SERIAL="%SERIAL%" 不在线（adb get-state: %STATE%）
    echo [错误] 请修正或取消 SCRCPY_SERIAL；不会自动回退
    "%ADB%" devices
    set "RC=1"
    goto :finish_error
)
set "SERNAME=OVERRIDE"

:select_done
echo ===============================
echo   scrcpy 启动器（MOD = Alt 键）
echo ===============================
if /i "%SERNAME%"=="OVERRIDE" (
    echo [信息] 由 SCRCPY_SERIAL 指定：%SERIAL%
) else (
    if /i "%SERNAME%"=="WIFI" (
        echo [信息] 已选 WiFi 端点：%SERIAL%   来源：%WIFI_SOURCE%
    ) else (
        echo [信息] 在线设备：%COUNT%   已选：%SERNAME%  %SERIAL%
        echo [信息] 设备状态：device=%COUNT% unauthorized=%UNAUTH% offline=%OFFLINE%
        if %COUNT% GTR 1 echo [信息] 有多台设备在线，请设置 SCRCPY_SERIAL 指定
    )
)
echo [信息] 快捷键：Alt+o 熄屏，Alt+Shift+o 亮屏，Alt+p 电源键
echo.

set "WIDTH=%SCRCPY_WIDTH%"
if not defined WIDTH set "WIDTH=580"
set "HEIGHT=%SCRCPY_HEIGHT%"
if not defined HEIGHT set "HEIGHT=1264"

rem 交互式双击：只在出错时保留 scrcpy 窗口。
rem 使用官方参数 --pause-on-exit=if-error，不做无条件暂停。
set "PAUSE_ARG="
if "%DO_PAUSE%"=="1" set "PAUSE_ARG=--pause-on-exit=if-error"

"%SCRCPY%" -s "%SERIAL%" "--window-width=%WIDTH%" "--window-height=%HEIGHT%" %PAUSE_ARG% %ARGS%
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" echo [错误] scrcpy 退出，代码 %RC%
exit /b %RC%

:run_help
"%SCRCPY%" %ARGS%
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" echo [错误] scrcpy 退出，代码 %RC%
exit /b %RC%

:cancelled
echo [信息] 用户已取消
exit /b 0

:err_scrcpy_missing
echo [错误] 未找到 scrcpy.exe："%SCRCPY%"
set "RC=1"
goto :finish_error

:err_adb_missing
echo [错误] 未找到 adb.exe："%ADB%"
set "RC=1"
goto :finish_error

:err_adb_server
echo [错误] adb server 启动失败
set "RC=1"
goto :finish_error

:err_no_device
echo [错误] 没有处于 "device" 状态的 adb 设备
echo [信息] 在线 device：%COUNT%   unauthorized：%UNAUTH%   offline：%OFFLINE%
if "%DO_WIFI%"=="1" (
    echo [信息] WiFi 自动发现未找到可用端点。
    echo [信息] 首次使用：请在手机上打开"无线调试"，或先连接一次 USB。
) else (
    echo [信息] WiFi 自动发现已被 --no-wifi 或 SCRCPY_NO_WIFI=1 关闭。
    echo [信息] 请先打开"无线调试"，或连接一次 USB 以启用 adb tcpip。
)
echo [信息] 配对：adb pair ^<手机IP^>:^<配对端口^>，然后输入手机显示的配对码。
"%ADB%" devices
set "RC=1"
goto :finish_error

:finish_error
if "%DO_PAUSE%"=="1" pause
exit /b %RC%
