@echo off
setlocal EnableExtensions EnableDelayedExpansion
title LEDERG MESSENGER - SERVER :8000

set "APP_DIR=C:\LEDERG-MESSENGER"
set "PYTHON=%APP_DIR%\.venv\Scripts\python.exe"
set "PORT=8000"
set "HOST=0.0.0.0"
set "RESTART_SECONDS=3"

echo ============================================================
echo LEDERG MESSENGER SERVER
echo PORT: %PORT%
echo APP : %APP_DIR%
echo ============================================================
echo.
echo This BAT only keeps run.py alive.
echo run.py logs are shown directly in this window.
echo.

if not exist "%APP_DIR%\run.py" (
    echo [ERROR] run.py not found:
    echo %APP_DIR%\run.py
    echo.
    exit /b 1
)

if not exist "%PYTHON%" (
    echo [ERROR] Python venv not found:
    echo %PYTHON%
    echo.
    exit /b 1
)

:SERVER_LOOP
echo.
echo ============================================================
echo [%DATE% %TIME%] CHECKING PORT %PORT%
echo ============================================================

call :FREE_PORT
if errorlevel 1 (
    echo [ERROR] Could not free port %PORT%.
    echo Retrying in %RESTART_SECONDS% seconds...
    timeout /t %RESTART_SECONDS% /nobreak >nul
    goto SERVER_LOOP
)

echo [START] Starting LEDERG run.py on %HOST%:%PORT%
echo [LOGS] run.py stdout/stderr are below.
echo [INFO] Press CTRL+C to stop the server and this BAT.
echo.

set "LEDERG_HOST=%HOST%"
set "LEDERG_PORT=%PORT%"

"%PYTHON%" -u "%APP_DIR%\run.py"

set "EXIT_CODE=%ERRORLEVEL%"
echo.
echo ============================================================
echo [%DATE% %TIME%] run.py EXITED WITH CODE %EXIT_CODE%
echo ============================================================
echo [RESTART] Restarting in %RESTART_SECONDS% seconds...
timeout /t %RESTART_SECONDS% /nobreak
goto SERVER_LOOP


:FREE_PORT
set "FOUND_PID="

for /f "tokens=5" %%P in ('netstat -ano ^| findstr /R /C:":%PORT% " ^| findstr /I "LISTENING"') do (
    set "FOUND_PID=%%P"
    echo [PORT] Port %PORT% is occupied by PID %%P
    echo [PORT] Process:
    tasklist /FI "PID eq %%P" /FO TABLE /NH
    echo [PORT] Terminating PID %%P...
    taskkill /F /PID %%P /T >nul 2>&1
    if errorlevel 1 (
        echo [PORT] Failed to terminate PID %%P
        exit /b 1
    )
    echo [PORT] PID %%P terminated.
)

if defined FOUND_PID (
    timeout /t 1 /nobreak >nul
    for /f "tokens=5" %%P in ('netstat -ano ^| findstr /R /C:":%PORT% " ^| findstr /I "LISTENING"') do (
        echo [PORT] Port %PORT% is STILL occupied by PID %%P
        exit /b 1
    )
)

echo [PORT] %PORT% is free.
exit /b 0
