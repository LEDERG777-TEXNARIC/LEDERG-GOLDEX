@echo off
setlocal EnableExtensions EnableDelayedExpansion
title LEDERG MESSENGER - AUTOPILOT SERVER :8000

set "REPO_URL=https://github.com/LEDERG777-TEXNARIC/LEDERG-GOLDEX.git"
set "BRANCH=main"
set "APP_DIR=C:\LEDERG-MESSENGER"
set "PYTHON=%APP_DIR%\.venv\Scripts\python.exe"
set "HOST=0.0.0.0"
set "PORT=8000"
set "CHECK_SECONDS=30"
set "RESTART_SECONDS=3"

echo ============================================================
echo LEDERG MESSENGER AUTOPILOT SERVER
echo APP : %APP_DIR%
echo PORT: %PORT%
echo GIT : %REPO_URL%
echo ============================================================
echo.
echo BAT keeps run.py alive and auto-updates from GitHub.
echo run.py stdout/stderr are shown in this window.
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
git remote set-url origin "%REPO_URL%" >nul 2>&1
if errorlevel 1 (
    echo [ERROR] Could not set GitHub remote.
    exit /b 1
)

:MAIN_LOOP
echo.
echo ============================================================
echo [%DATE% %TIME%] CHECK / UPDATE
echo ============================================================

call :UPDATE_REPOSITORY
if errorlevel 1 (
    echo [GIT] Update check failed. Server will continue.
)

call :FREE_PORT
if errorlevel 1 (
    echo [PORT] Could not free port %PORT%.
    echo [WAIT] Retrying in %RESTART_SECONDS% seconds...
    timeout /t %RESTART_SECONDS% /nobreak >nul
    goto MAIN_LOOP
)

echo.
echo [START] LEDERG run.py -> %HOST%:%PORT%
echo [LOGS] Live run.py logs:
echo.

set "LEDERG_HOST=%HOST%"
set "LEDERG_PORT=%PORT%"

"%PYTHON%" -u "%APP_DIR%\run.py"

set "EXIT_CODE=%ERRORLEVEL%"
echo.
echo ============================================================
echo [%DATE% %TIME%] run.py EXITED WITH CODE %EXIT_CODE%
echo ============================================================
echo [RESTART] Server will restart in %RESTART_SECONDS% seconds.
timeout /t %RESTART_SECONDS% /nobreak >nul
goto MAIN_LOOP


:UPDATE_REPOSITORY
cd /d "%APP_DIR%"

echo [GIT] Fetching GitHub...
git fetch origin "%BRANCH%" --prune
if errorlevel 1 (
    echo [GIT] Fetch failed.
    exit /b 1
)

for /f "delims=" %%A in ('git rev-parse HEAD') do set "LOCAL_COMMIT=%%A"
for /f "delims=" %%A in ('git rev-parse origin/%BRANCH%') do set "REMOTE_COMMIT=%%A"

if /I "%LOCAL_COMMIT%"=="%REMOTE_COMMIT%" (
    echo [GIT] Up to date: %LOCAL_COMMIT:~0,8%
    exit /b 0
)

echo [GIT] NEW COMMIT DETECTED
echo [GIT] Local : %LOCAL_COMMIT%
echo [GIT] Remote: %REMOTE_COMMIT%
echo [GIT] Updating local files...

git reset --hard "origin/%BRANCH%"
if errorlevel 1 (
    echo [GIT] reset failed.
    exit /b 1
)

git clean -fd

if exist "requirements.txt" (
    echo [PIP] Checking dependencies...
    "%PYTHON%" -m pip install -r "requirements.txt" --disable-pip-version-check
    if errorlevel 1 (
        echo [PIP] Dependency update failed.
        exit /b 1
    )
)

echo [GIT] Update installed successfully.
exit /b 0


:FREE_PORT
set "FOUND_PORT=0"

for /f "tokens=5" %%P in ('netstat -ano ^| findstr /R /C:":%PORT% " ^| findstr /I "LISTENING"') do (
    set "FOUND_PORT=1"
    echo [PORT] Port %PORT% occupied by PID %%P
    tasklist /FI "PID eq %%P" /FO TABLE /NH
    echo [PORT] Terminating PID %%P...
    taskkill /F /PID %%P /T >nul 2>&1
    if errorlevel 1 (
        echo [PORT] Failed to terminate PID %%P
        exit /b 1
    )
    echo [PORT] PID %%P terminated.
)

if "%FOUND_PORT%"=="1" timeout /t 1 /nobreak >nul

for /f "tokens=5" %%P in ('netstat -ano ^| findstr /R /C:":%PORT% " ^| findstr /I "LISTENING"') do (
    echo [PORT] Port %PORT% is STILL occupied by PID %%P
    exit /b 1
)

echo [PORT] %PORT% is free.
exit /b 0
