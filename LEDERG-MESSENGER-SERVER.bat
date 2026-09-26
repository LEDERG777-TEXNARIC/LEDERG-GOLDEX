@echo off
chcp 65001 >nul
title LEDERG SERVER - LIVE LOGS
setlocal

set "APP_DIR=C:\LEDERG-MESSENGER"
set "LEDERG_HOST=0.0.0.0"
set "LEDERG_PORT=8000"

cd /d "%APP_DIR%"
if errorlevel 1 (
    echo [ERROR] Cannot open %APP_DIR%
    pause
    exit /b 1
)

if not exist ".venv\Scripts\python.exe" (
    echo [ERROR] Python environment not found:
    echo %APP_DIR%\.venv\Scripts\python.exe
    pause
    exit /b 1
)

echo ============================================================
echo LEDERG SERVER
echo http://127.0.0.1:8000
echo LIVE run.py logs are shown below
echo ============================================================
echo.

:RUN
echo [%date% %time%] Starting run.py...
".venv\Scripts\python.exe" "run.py"

set "EXIT_CODE=%ERRORLEVEL%"
echo.
echo ============================================================
echo [%date% %time%] run.py stopped. Exit code: %EXIT_CODE%
echo Server will restart in 3 seconds...
echo ============================================================
timeout /t 3 /nobreak >nul
goto RUN
