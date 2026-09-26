@echo off
setlocal EnableExtensions EnableDelayedExpansion
title LEDERG MESSENGER SERVER
cd /d "C:\LEDERG-MESSENGER"

set "PORT=8000"
set "HOST=0.0.0.0"
set "PYTHON=C:\LEDERG-MESSENGER\.venv\Scripts\python.exe"
set "RUNPY=C:\LEDERG-MESSENGER\run.py"
set "RESTART_DELAY=3"

echo ============================================================
echo                  LEDERG MESSENGER
echo ============================================================
echo APP   : C:\LEDERG-MESSENGER
echo HOST  : %HOST%
echo PORT  : %PORT%
echo.
echo This window shows live run.py / Uvicorn logs.
echo ============================================================
echo.

if not exist "%RUNPY%" (
    echo [ERROR] run.py not found:
    echo         %RUNPY%
    pause
    exit /b 1
)

if not exist "%PYTHON%" (
    echo [ERROR] Virtualenv Python not found:
    echo         %PYTHON%
    echo Create .venv first.
    pause
    exit /b 1
)

:MAIN_LOOP
echo.
echo [%DATE% %TIME%] [CHECK] Checking TCP port %PORT%...

powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$port=%PORT%; $c=Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue; if($c){$c | Select-Object -Unique OwningProcess | ForEach-Object { $p=Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue; if($p){ Write-Host ('[PORT] PID=' + $p.Id + ' PROCESS=' + $p.ProcessName); Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue; Start-Sleep -Milliseconds 700 } }}"

echo [%DATE% %TIME%] [START] Starting run.py on %HOST%:%PORT%
echo ------------------------------------------------------------
echo.

set "LEDERG_HOST=%HOST%"
set "LEDERG_PORT=%PORT%"

"%PYTHON%" "%RUNPY%"

set "EXIT_CODE=%ERRORLEVEL%"
echo.
echo ------------------------------------------------------------
echo [%DATE% %TIME%] [STOP] run.py exited with code %EXIT_CODE%.
echo [%DATE% %TIME%] [RESTART] Restarting in %RESTART_DELAY% seconds...
echo ------------------------------------------------------------
timeout /t %RESTART_DELAY% /nobreak >nul
goto MAIN_LOOP
