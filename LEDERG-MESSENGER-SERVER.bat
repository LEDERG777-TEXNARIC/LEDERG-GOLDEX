@echo off
setlocal EnableExtensions EnableDelayedExpansion
title LEDERG MESSENGER - LIVE AUTOPILOT :8000

set "REPO_URL=https://github.com/LEDERG777-TEXNARIC/LEDERG-GOLDEX.git"
set "BRANCH=main"
set "APP_DIR=C:\LEDERG-MESSENGER"
set "PYTHON=%APP_DIR%\.venv\Scripts\python.exe"
set "HOST=0.0.0.0"
set "PORT=8000"
set "CHECK_SECONDS=30"
set "RESTART_SECONDS=3"
set "DB_CHECK_EVERY=2"
set "DB_CYCLE=0"
set "SERVER_PID="

echo ============================================================
echo LEDERG MESSENGER - LIVE AUTOPILOT
echo APP : %APP_DIR%
echo PORT: %PORT%
echo GIT : %REPO_URL%
echo ============================================================
echo.
echo run.py runs in background with LIVE console logs.
echo GitHub is checked every %CHECK_SECONDS% seconds.
echo New commit = stop -> update -> pip -> restart.
echo.

if not exist "%APP_DIR%\run.py" (
    echo [ERROR] run.py not found: %APP_DIR%\run.py
    exit /b 1
)
if not exist "%PYTHON%" (
    echo [ERROR] Python venv not found: %PYTHON%
    exit /b 1
)
if not exist "%APP_DIR%\.git" (
    echo [ERROR] Git repository not found: %APP_DIR%\.git
    exit /b 1
)

cd /d "%APP_DIR%"
powershell -NoProfile -Command "git -C '%APP_DIR%' remote set-url origin '%REPO_URL%'" >nul 2>&1

:MAIN
echo.
echo ============================================================
echo [%DATE% %TIME%] SERVER CYCLE
echo ============================================================

call :CHECK_REMOTE
if errorlevel 2 (
    echo [GIT] New commit found. Updating before server start...
    call :APPLY_UPDATE
    if errorlevel 1 echo [GIT] Update failed. Starting current local revision.
)

call :DB_GUARD
if errorlevel 20 (
    echo [DB] Critical database state detected before start.
    call :DB_REPAIR
    if errorlevel 1 (
        echo [DB] Automatic repair failed. Retrying...
        timeout /t %RESTART_SECONDS% /nobreak >nul
        goto MAIN
    )
)
call :FREE_PORT
if errorlevel 1 (
    echo [PORT] Could not free port %PORT%.
    timeout /t %RESTART_SECONDS% /nobreak >nul
    goto MAIN
)

call :DB_GUARD
cd /d "%APP_DIR%"
echo [DB] Intelligent database guard...
"%PYTHON%" "%APP_DIR%\scripts\db_maintenance.py"
if errorlevel 20 (
    echo [DB] Guard reports corruption or an unsafe database state.
    exit /b 20
)
if errorlevel 1 (
    echo [DB] Guard could not complete. Current database will be kept; retrying later.
    exit /b 1
)
echo [DB] Database healthy, schema normalized, verified backup maintained.
exit /b 0


:DB_REPAIR
cd /d "%APP_DIR%"
echo [DB] Starting automatic database repair...
"%PYTHON%" "%APP_DIR%\scripts\db_maintenance.py" --repair
if errorlevel 1 (
    echo [DB] Automatic repair FAILED.
    exit /b 1
)
echo [DB] Automatic repair completed.
exit /b 0


:START_SERVER
if errorlevel 1 (
    echo [SERVER] run.py failed to open port %PORT%.
    timeout /t %RESTART_SECONDS% /nobreak >nul
    goto MAIN
)

:MONITOR
timeout /t %CHECK_SECONDS% /nobreak >nul

set /a DB_CYCLE+=1
if !DB_CYCLE! GEQ %DB_CHECK_EVERY% (
    set "DB_CYCLE=0"
    call :DB_GUARD
    if errorlevel 20 (
        echo.
        echo ============================================================
        echo [%DATE% %TIME%] DATABASE WATCHDOG ALERT
        echo ============================================================
        call :STOP_SERVER
        call :DB_REPAIR
        if errorlevel 1 (
            echo [DB] Repair failed. Autopilot will retry automatically.
            timeout /t %RESTART_SECONDS% /nobreak >nul
            goto MAIN
        )
        goto MAIN
    )
)

call :SERVER_ALIVE
if errorlevel 1 (
    echo.
    echo [WATCHDOG] run.py stopped listening on %PORT%.
    call :STOP_SERVER
    goto MAIN
)

call :CHECK_REMOTE
if errorlevel 2 (
    echo.
    echo ============================================================
    echo [%DATE% %TIME%] NEW GITHUB COMMIT
    echo ============================================================
    call :STOP_SERVER
    call :APPLY_UPDATE
    if errorlevel 1 echo [GIT] Update failed. Keeping local revision.
    goto MAIN
)

goto MONITOR


:CHECK_REMOTE
cd /d "%APP_DIR%"
echo [GIT] Checking GitHub...

git fetch origin "%BRANCH%" --prune
if errorlevel 1 (
    echo [GIT] Fetch failed.
    exit /b 1
)

for /f "delims=" %%A in ('git rev-parse HEAD') do set "LOCAL_COMMIT=%%A"
for /f "delims=" %%A in ('git rev-parse origin/%BRANCH%') do set "REMOTE_COMMIT=%%A"

if /I "!LOCAL_COMMIT!"=="!REMOTE_COMMIT!" (
    echo [GIT] Up to date: !LOCAL_COMMIT:~0,8!
    exit /b 0
)

echo [GIT] Update available.
echo [GIT] Local : !LOCAL_COMMIT!
echo [GIT] Remote: !REMOTE_COMMIT!
exit /b 2


:APPLY_UPDATE
cd /d "%APP_DIR%"

git reset --hard "origin/%BRANCH%"
if errorlevel 1 (
    echo [GIT] reset failed.
    exit /b 1
)

git clean -fd

if exist "requirements.txt" (
    echo [PIP] Installing dependencies...
    "%PYTHON%" -m pip install -r "requirements.txt" --disable-pip-version-check
    if errorlevel 1 (
        echo [PIP] Dependency installation failed.
        exit /b 1
    )
)

for /f "delims=" %%A in ('git rev-parse HEAD') do set "NEW_COMMIT=%%A"
echo [GIT] Running revision: !NEW_COMMIT!
exit /b 0


:START_SERVER
echo.
echo [START] run.py -> %HOST%:%PORT%
echo [LOGS] LIVE run.py stdout/stderr:
echo.

set "LEDERG_HOST=%HOST%"
set "LEDERG_PORT=%PORT%"
set "LEDERG_AUTOPILOT=1"
set "SERVER_PID="

start "" /B "%PYTHON%" -u "%APP_DIR%\run.py"

for /l %%N in (1,1,10) do (
    timeout /t 1 /nobreak >nul
    call :GET_PORT_PID
    if defined SERVER_PID (
        echo [SERVER] run.py PID: !SERVER_PID!
        exit /b 0
    )
)

exit /b 1


:SERVER_ALIVE
call :GET_PORT_PID
if defined SERVER_PID exit /b 0
exit /b 1


:GET_PORT_PID
set "SERVER_PID="
for /f "tokens=5" %%P in ('netstat -ano ^| findstr /R /C:":%PORT% " ^| findstr /I "LISTENING"') do (
    set "SERVER_PID=%%P"
    goto GET_PORT_PID_DONE
)
:GET_PORT_PID_DONE
exit /b 0


:STOP_SERVER
call :GET_PORT_PID
if not defined SERVER_PID (
    echo [SERVER] No process on port %PORT%.
    exit /b 0
)

echo [SERVER] Stopping PID !SERVER_PID!...
powershell -NoProfile -Command "Stop-Process -Id !SERVER_PID! -Force -ErrorAction SilentlyContinue" >nul 2>&1
set "SERVER_PID="
timeout /t 1 /nobreak >nul
exit /b 0


:FREE_PORT
set "FOUND_PORT=0"

for /f "tokens=5" %%P in ('netstat -ano ^| findstr /R /C:":%PORT% " ^| findstr /I "LISTENING"') do (
    set "FOUND_PORT=1"
    echo [PORT] Port %PORT% occupied by PID %%P
    powershell -NoProfile -Command "Get-Process -Id %%P -ErrorAction SilentlyContinue | Select-Object Id,ProcessName,Path"
    echo [PORT] Terminating PID %%P...
    powershell -NoProfile -Command "Stop-Process -Id %%P -Force -ErrorAction SilentlyContinue" >nul 2>&1
    echo [PORT] PID %%P terminated.
)

if "%FOUND_PORT%"=="1" timeout /t 1 /nobreak >nul

for /f "tokens=5" %%P in ('netstat -ano ^| findstr /R /C:":%PORT% " ^| findstr /I "LISTENING"') do (
    echo [PORT] Port %PORT% is STILL occupied by PID %%P
    exit /b 1
)

echo [PORT] %PORT% is free.
exit /b 0
