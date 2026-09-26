@echo off
chcp 65001 >nul
title LEDERG SERVER - LIVE LOGS
setlocal EnableExtensions

set "APP_DIR=C:\LEDERG-MESSENGER"
set "LEDERG_HOST=0.0.0.0"
set "LEDERG_PORT=8000"
set "RUNPY=%APP_DIR%\run.py"
set "PYTHON=%APP_DIR%\.venv\Scripts\python.exe"

cd /d "%APP_DIR%"
if errorlevel 1 (
    echo [ERROR] Cannot open %APP_DIR%
    pause
    exit /b 1
)

if not exist "%PYTHON%" (
    echo [ERROR] Python environment not found:
    echo %PYTHON%
    pause
    exit /b 1
)

echo ============================================================
echo LEDERG SERVER
echo http://127.0.0.1:8000
echo LIVE run.py logs are shown below
echo ============================================================
echo.

:START_SERVER
echo [%date% %time%] Checking old LEDERG processes...

powershell -NoProfile -ExecutionPolicy Bypass -Command "$p=Get-CimInstance Win32_Process -Filter 'Name = ''python.exe''' -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -and $_.CommandLine -like '*C:\LEDERG-MESSENGER*' -and $_.CommandLine -like '*run.py*' -and $_.ProcessId -ne $PID }; foreach($x in $p){ try { Stop-Process -Id $x.ProcessId -Force -ErrorAction Stop; Write-Host ('[CLEANUP] Stopped old LEDERG run.py PID=' + $x.ProcessId) } catch {} }"

timeout /t 1 /nobreak >nul

powershell -NoProfile -ExecutionPolicy Bypass -Command "$c=Get-NetTCPConnection -LocalPort 8000 -State Listen -ErrorAction SilentlyContinue; if($c){ foreach($x in $c){ Write-Host ('[PORT] 8000 is still occupied by PID=' + $x.OwningProcess) } exit 1 } exit 0"
if errorlevel 1 (
    echo [ERROR] Port 8000 is occupied by another application.
    echo Close that application or change its port before starting LEDERG.
    timeout /t 5 /nobreak >nul
    goto START_SERVER
)

echo [%date% %time%] Starting run.py...
echo.

"%PYTHON%" "%RUNPY%"

set "EXIT_CODE=%ERRORLEVEL%"
echo.
echo ============================================================
echo [%date% %time%] run.py stopped. Exit code: %EXIT_CODE%
echo Server will restart in 3 seconds...
echo ============================================================
timeout /t 3 /nobreak >nul
goto START_SERVER
