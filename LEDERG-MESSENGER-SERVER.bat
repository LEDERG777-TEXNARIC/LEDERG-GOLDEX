@echo off
setlocal EnableExtensions EnableDelayedExpansion
title LEDERG AUTOPILOT

rem ============================================================
rem LEDERG AUTOPILOT - SINGLE BAT SUPERVISOR
rem ============================================================
rem One permanent BAT:
rem   * starts automatically through Windows Task Scheduler
rem   * keeps the messenger running
rem   * checks GitHub/main every 5 seconds
rem   * deploys new commits automatically
rem   * installs changed Python dependencies
rem   * checks Python syntax
rem   * checks HTTP + database health
rem   * backs up SQLite before every release
rem   * keeps a GOOD release outside Git
rem   * rolls back a broken release automatically
rem   * repairs a dead LEDERG process automatically
rem   * never kills an unrelated program on port 8000
rem ============================================================

set "APP_DIR=C:\LEDERG-MESSENGER"
set "DATA_DIR=C:\LEDERG-MESSENGER-DATA"
set "BOOT_DIR=C:\LEDERG-MESSENGER-BOOT"
set "STATE_DIR=%DATA_DIR%\autopilot"
set "LOG_DIR=%STATE_DIR%\logs"
set "GOOD_DIR=%STATE_DIR%\GOOD"
set "BACKUP_DIR=%DATA_DIR%\backups"

set "TASK_NAME=LEDERG-MESSENGER"
set "BRANCH=main"
set "PORT=8000"
set "HEALTH_URL=http://127.0.0.1:%PORT%/health"
set "CHECK_SECONDS=5"
set "HEALTH_TIMEOUT=45"
set "MAX_RECOVERY=3"

set "VENV=%APP_DIR%\.venv"
set "PYTHON=%VENV%\Scripts\python.exe"

set "SUPERVISOR=%BOOT_DIR%\LEDERG-MESSENGER-SERVER.bat"
set "TASK_RUNNER=%BOOT_DIR%\LEDERG-AUTOPILOT.cmd"

if /I "%~1"=="run" goto RUN
if /I "%~1"=="install" goto INSTALL
if /I "%~1"=="status" goto STATUS
if /I "%~1"=="logs" goto LOGS
if /I "%~1"=="uninstall" goto UNINSTALL
if "%~1"=="" goto INSTALL
echo Unknown command: %~1
exit /b 2

:INIT
if not exist "%DATA_DIR%" mkdir "%DATA_DIR%"
if not exist "%STATE_DIR%" mkdir "%STATE_DIR%"
if not exist "%LOG_DIR%" mkdir "%LOG_DIR%"
if not exist "%GOOD_DIR%" mkdir "%GOOD_DIR%"
if not exist "%BACKUP_DIR%" mkdir "%BACKUP_DIR%"
for /f %%A in ('powershell.exe -NoProfile -Command "Get-Date -Format yyyyMMdd_HHmmss"') do set "TS=%%A"
set "LOG_FILE=%LOG_DIR%\guard_!TS!.log"
set "SERVER_LOG=%LOG_DIR%\server_!TS!.log"
set "SERVER_ERR=%LOG_DIR%\server_!TS!_error.log"
exit /b 0

:LOG
echo [%DATE% %TIME%] %~1
>>"%LOG_FILE%" echo [%DATE% %TIME%] %~1
exit /b 0

:INSTALL
call :INIT

echo ============================================================
echo LEDERG AUTOPILOT INSTALL
echo ============================================================
echo.

if not exist "%APP_DIR%" (
    echo ERROR: %APP_DIR% does not exist.
    echo.
    echo The repository must already be cloned there.
    pause
    exit /b 1
)

where git.exe >nul 2>&1
if errorlevel 1 (
    echo ERROR: Git is not installed.
    pause
    exit /b 1
)

if not exist "%APP_DIR%\.git" (
    echo ERROR: %APP_DIR% is not a Git repository.
    pause
    exit /b 1
)

call :ENSURE_PYTHON
if errorlevel 1 (
    echo ERROR: Python could not be prepared.
    pause
    exit /b 1
)

echo.
echo Reconciling Python dependencies...
"%PYTHON%" -m pip install --upgrade pip --disable-pip-version-check
if errorlevel 1 (
    echo ERROR: pip upgrade failed.
    pause
    exit /b 1
)

if exist "%APP_DIR%\requirements.txt" (
    "%PYTHON%" -m pip install -r "%APP_DIR%\requirements.txt" --disable-pip-version-check
    if errorlevel 1 (
        echo ERROR: requirements installation failed.
        pause
        exit /b 1
    )
)

echo.
echo Validating application...
"%PYTHON%" -m compileall -q "%APP_DIR%\server" "%APP_DIR%\run.py"
if errorlevel 1 (
    echo ERROR: Python compile check failed.
    pause
    exit /b 1
)

if not exist "%BOOT_DIR%" mkdir "%BOOT_DIR%"

echo Installing permanent runner...
copy /Y "%~f0" "%SUPERVISOR%" >nul
if errorlevel 1 (
    echo ERROR: Could not copy supervisor to %SUPERVISOR%.
    pause
    exit /b 1
)

> "%TASK_RUNNER%" echo @echo off
>>"%TASK_RUNNER%" echo call "%SUPERVISOR%" run
if not exist "%TASK_RUNNER%" (
    echo ERROR: Could not create task runner.
    pause
    exit /b 1
)

echo.
echo Removing old task instance...
schtasks /End /TN "%TASK_NAME%" >nul 2>&1
schtasks /Delete /TN "%TASK_NAME%" /F >nul 2>&1

echo Creating permanent SYSTEM task...
schtasks /Create /TN "%TASK_NAME%" /SC ONSTART /DELAY 0000:15 /RU SYSTEM /RL HIGHEST /F /TR "cmd.exe /d /c %TASK_RUNNER%"
if errorlevel 1 (
    echo ERROR: Task Scheduler creation failed.
    schtasks /Query /TN "%TASK_NAME%" /FO LIST
    pause
    exit /b 1
)

echo Configuring automatic task restart...
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop';$task=Get-ScheduledTask -TaskName '%TASK_NAME%';$task.Settings.MultipleInstances='IgnoreNew';$task.Settings.RestartCount=100;$task.Settings.RestartInterval='PT1M';$task.Settings.StartWhenAvailable=$true;$task.Settings.ExecutionTimeLimit='PT0S';Set-ScheduledTask -TaskName '%TASK_NAME%' -Settings $task.Settings" >nul 2>&1
if errorlevel 1 (
    echo [WARN] Extra restart settings could not be applied.
    echo [WARN] The BAT itself remains a permanent watchdog.
)

echo.
echo Starting autopilot NOW...
schtasks /Run /TN "%TASK_NAME%" >nul 2>&1

echo Waiting for the messenger to become healthy...
call :WAIT_EXTERNAL_HEALTH

echo.
echo ============================================================
if not errorlevel 1 (
    echo LEDERG AUTOPILOT IS ONLINE
) else (
    echo LEDERG AUTOPILOT IS INSTALLED
    echo Server is not healthy yet. The watchdog will keep retrying automatically.
)
echo ============================================================
echo Task      : %TASK_NAME%
echo App       : %APP_DIR%
echo Port      : %PORT%
echo GitHub    : origin/%BRANCH%
echo Watch     : every %CHECK_SECONDS% seconds
echo Health    : %HEALTH_URL%
echo DB        : %DATA_DIR%\lederg.db
echo Logs      : %LOG_DIR%
echo GOOD      : %GOOD_DIR%
echo.
echo You can close this window. Windows Task Scheduler keeps the autopilot alive.
echo ============================================================
echo.
pause
exit /b 0

:ENSURE_PYTHON
if exist "%PYTHON%" exit /b 0

where py.exe >nul 2>&1
if not errorlevel 1 (
    py -3 -m venv "%VENV%"
    if exist "%PYTHON%" exit /b 0
)

where python.exe >nul 2>&1
if not errorlevel 1 (
    python -m venv "%VENV%"
    if exist "%PYTHON%" exit /b 0
)

echo Python is missing. Trying automatic installation...
where winget.exe >nul 2>&1
if not errorlevel 1 (
    winget install --id Python.Python.3.11 -e --scope machine --accept-package-agreements --accept-source-agreements
    if not errorlevel 1 (
        set "PATH=%PATH%;C:\Program Files\Python311;C:\Program Files\Python311\Scripts;%LOCALAPPDATA%\Programs\Python\Python311;%LOCALAPPDATA%\Programs\Python\Python311\Scripts"
        where py.exe >nul 2>&1
        if not errorlevel 1 py -3 -m venv "%VENV%"
        if exist "%PYTHON%" exit /b 0
        where python.exe >nul 2>&1
        if not errorlevel 1 python -m venv "%VENV%"
        if exist "%PYTHON%" exit /b 0
    )
)

echo Automatic Python installation failed.
exit /b 1

:RUN
call :INIT
call :LOG "============================================================"
call :LOG "LEDERG AUTOPILOT STARTED."
call :LOG "APP=%APP_DIR%"
call :LOG "DATA=%DATA_DIR%"
call :LOG "PORT=%PORT%"
call :LOG "HEALTH=%HEALTH_URL%"
call :LOG "GITHUB CHECK=%CHECK_SECONDS%s."
call :LOG "TASK=%TASK_NAME%."

cd /d "%APP_DIR%"
if errorlevel 1 goto SAFE_MODE

if not exist "%APP_DIR%\.git" (
    call :LOG "FATAL: Git repository missing."
    goto SAFE_MODE
)

call :ENSURE_PYTHON
if errorlevel 1 goto SAFE_MODE

call :LOG "Synchronizing local repository..."
git fetch origin %BRANCH% --prune --quiet >nul 2>&1
if errorlevel 1 (
    call :LOG "GitHub fetch failed. Local release will continue unchanged."
) else (
    call :LOG "GitHub reachable."
)

call :FIND_LEDGER_PROCESS
if defined SERVER_PID (
    call :LOG "Existing LEDERG process found: PID !SERVER_PID!."
) else (
    call :LOG "No LEDERG process found. Starting server."
    call :START_SERVER
)

call :WAIT_HEALTH
if errorlevel 1 (
    call :LOG "Initial health check failed."
    call :RECOVER_RUNTIME
)

call :CHECK_SERVER
if not errorlevel 1 (
    if not exist "%GOOD_DIR%\run.py" (
        call :SNAPSHOT_GOOD
        if not errorlevel 1 call :LOG "Current healthy release saved as GOOD."
    )
)

:LOOP
call :CHECK_SERVER
if errorlevel 1 (
    call :LOG "WATCHDOG: service unhealthy."
    call :RECOVER_RUNTIME
)

call :CHECK_UPDATE

timeout /t %CHECK_SECONDS% /nobreak >nul
goto LOOP

:CHECK_SERVER
call :FIND_LEDGER_PROCESS
if not defined SERVER_PID exit /b 1
tasklist /FI "PID eq !SERVER_PID!" | findstr /I "!SERVER_PID!" >nul
if errorlevel 1 exit /b 1

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "try {$r=Invoke-RestMethod -Uri '%HEALTH_URL%' -TimeoutSec 4; if($r.ok -eq $true -and $r.database -eq 'ok'){exit 0}else{exit 1}}catch{exit 1}" >nul 2>&1
if errorlevel 1 exit /b 1

exit /b 0

:FIND_LEDGER_PROCESS
set "SERVER_PID="
for /f "delims=" %%A in ('powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$root=[regex]::Escape('%APP_DIR%');$p=Get-CimInstance Win32_Process -ErrorAction SilentlyContinue ^| Where-Object { $_.Name -match '^python(w)?\.exe$' -and $_.CommandLine -and $_.CommandLine -match $root -and $_.CommandLine -match '(^|\s)run\.py(\s|$)' } ^| Sort-Object ProcessId ^| Select-Object -First 1 -ExpandProperty ProcessId; if($p){$p}"') do set "SERVER_PID=%%A"
exit /b 0

:START_SERVER
call :STOP_LEDGER_PROCESSES

for /f %%A in ('powershell.exe -NoProfile -Command "Get-Date -Format yyyyMMdd_HHmmss"') do set "RUN_TS=%%A"
set "SERVER_LOG=%LOG_DIR%\server_!RUN_TS!.log"
set "SERVER_ERR=%LOG_DIR%\server_!RUN_TS!_error.log"
set "SERVER_PID="

call :LOG "Starting run.py..."
for /f "delims=" %%A in ('powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$p=Start-Process -FilePath '%PYTHON%' -ArgumentList 'run.py' -WorkingDirectory '%APP_DIR%' -RedirectStandardOutput '%SERVER_LOG%' -RedirectStandardError '%SERVER_ERR%' -WindowStyle Hidden -PassThru; $p.Id"') do set "SERVER_PID=%%A"

if not defined SERVER_PID (
    call :LOG "ERROR: could not start run.py or obtain PID."
    exit /b 1
)

call :LOG "Python PID=!SERVER_PID!."
exit /b 0

:STOP_LEDGER_PROCESSES
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$root=[regex]::Escape('%APP_DIR%');Get-CimInstance Win32_Process -ErrorAction SilentlyContinue ^| Where-Object { $_.Name -match '^python(w)?\.exe$' -and $_.CommandLine -and $_.CommandLine -match $root -and $_.CommandLine -match '(^|\s)run\.py(\s|$)' } ^| ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }" >nul 2>&1
set "SERVER_PID="
timeout /t 2 /nobreak >nul
exit /b 0

:WAIT_HEALTH
set /a HWAIT=0
:WAIT_HEALTH_LOOP
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "try {$r=Invoke-RestMethod -Uri '%HEALTH_URL%' -TimeoutSec 4; if($r.ok -eq $true -and $r.database -eq 'ok'){exit 0}else{exit 1}}catch{exit 1}" >nul 2>&1
if not errorlevel 1 exit /b 0

set /a HWAIT+=1
if !HWAIT! GEQ %HEALTH_TIMEOUT% exit /b 1

call :FIND_LEDGER_PROCESS
if not defined SERVER_PID exit /b 1

tasklist /FI "PID eq !SERVER_PID!" | findstr /I "!SERVER_PID!" >nul
if errorlevel 1 exit /b 1

timeout /t 1 /nobreak >nul
goto WAIT_HEALTH_LOOP

:WAIT_EXTERNAL_HEALTH
set /a EXT_WAIT=0
:EXT_WAIT_LOOP
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "try {$r=Invoke-RestMethod -Uri '%HEALTH_URL%' -TimeoutSec 4; if($r.ok -eq $true -and $r.database -eq 'ok'){exit 0}else{exit 1}}catch{exit 1}" >nul 2>&1
if not errorlevel 1 exit /b 0

set /a EXT_WAIT+=1
if !EXT_WAIT! GEQ %HEALTH_TIMEOUT% exit /b 1
timeout /t 1 /nobreak >nul
goto EXT_WAIT_LOOP

:RECOVER_RUNTIME
set /a RCOUNT=0
:RECOVER_LOOP
set /a RCOUNT+=1
call :LOG "Recovery attempt !RCOUNT!/%MAX_RECOVERY%."
call :DIAGNOSE

call :START_SERVER
if not errorlevel 1 (
    call :WAIT_HEALTH
    if not errorlevel 1 (
        call :LOG "Runtime recovery succeeded."
        exit /b 0
    )
)

if !RCOUNT! GEQ %MAX_RECOVERY% (
    if exist "%GOOD_DIR%\run.py" (
        call :LOG "Runtime recovery exhausted. Restoring GOOD release."
        call :RESTORE_GOOD
        call :START_SERVER
        call :WAIT_HEALTH
        if not errorlevel 1 (
            call :LOG "GOOD rollback succeeded."
            exit /b 0
        )
    )
    call :LOG "All runtime recovery attempts failed. Entering SAFE MODE."
    exit /b 1
)

timeout /t 5 /nobreak >nul
goto RECOVER_LOOP

:CHECK_UPDATE
cd /d "%APP_DIR%"

git fetch origin %BRANCH% --prune --quiet >nul 2>&1
if errorlevel 1 (
    call :LOG "GitHub update check failed. Keeping current release."
    exit /b 0
)

set "LOCAL_SHA="
set "REMOTE_SHA="
for /f "delims=" %%A in ('git rev-parse HEAD 2^>nul') do set "LOCAL_SHA=%%A"
for /f "delims=" %%A in ('git rev-parse origin/%BRANCH% 2^>nul') do set "REMOTE_SHA=%%A"

if not defined LOCAL_SHA exit /b 0
if not defined REMOTE_SHA exit /b 0
if /I "!LOCAL_SHA!"=="!REMOTE_SHA!" exit /b 0

call :LOG "NEW COMMIT DETECTED: !REMOTE_SHA!."

if exist "%STATE_DIR%\BAD_SHA.txt" (
    set "BAD_SHA="
    set /p BAD_SHA=<"%STATE_DIR%\BAD_SHA.txt"
    if /I "!BAD_SHA!"=="!REMOTE_SHA!" (
        call :LOG "Commit already marked BAD. Waiting for a newer commit."
        exit /b 0
    )
)

call :DEPLOY
exit /b 0

:DEPLOY
call :LOG "============================================================"
call :LOG "AUTOMATIC UPDATE START"
call :STOP_LEDGER_PROCESSES

call :DB_MAINTENANCE
if errorlevel 1 (
    call :LOG "WARNING: DB maintenance failed. Update will not proceed."
    call :START_SERVER
    exit /b 1
)

call :BACKUP_DB
if errorlevel 1 (
    call :LOG "UPDATE ABORTED: DB backup failed."
    call :START_SERVER
    call :WAIT_HEALTH
    exit /b 1
)

call :SNAPSHOT_GOOD
if errorlevel 1 (
    call :LOG "UPDATE ABORTED: GOOD snapshot failed."
    call :START_SERVER
    call :WAIT_HEALTH
    exit /b 1
)

cd /d "%APP_DIR%"

git reset --hard origin/%BRANCH% >>"%LOG_FILE%" 2>&1
if errorlevel 1 goto UPDATE_FAIL

set "NEW_SHA="
for /f "delims=" %%A in ('git rev-parse HEAD 2^>nul') do set "NEW_SHA=%%A"
call :LOG "Candidate commit=!NEW_SHA!."

"%PYTHON%" -m compileall -q "%APP_DIR%\server" "%APP_DIR%\run.py" >>"%LOG_FILE%" 2>&1
if errorlevel 1 (
    call :LOG "UPDATE FAIL: Python compilation error."
    goto UPDATE_FAIL
)

if exist "%APP_DIR%\requirements.txt" (
    "%PYTHON%" -m pip install -r "%APP_DIR%\requirements.txt" --disable-pip-version-check >>"%LOG_FILE%" 2>&1
    if errorlevel 1 (
        call :LOG "UPDATE FAIL: dependency installation error."
        goto UPDATE_FAIL
    )
)

call :DB_MAINTENANCE
if errorlevel 1 (
    call :LOG "UPDATE FAIL: DB maintenance failed after code update."
    goto UPDATE_FAIL
)

call :START_SERVER
if errorlevel 1 goto UPDATE_FAIL

call :WAIT_HEALTH
if errorlevel 1 (
    call :LOG "UPDATE FAIL: HTTP/DB health check failed."
    goto UPDATE_FAIL
)

call :LOG "UPDATE SUCCESS: !NEW_SHA! is healthy."
call :SNAPSHOT_GOOD
del /q "%STATE_DIR%\BAD_SHA.txt" >nul 2>&1
call :PRUNE_BACKUPS
call :LOG "AUTOMATIC UPDATE COMPLETE"
exit /b 0

:UPDATE_FAIL
call :DIAGNOSE
call :STOP_LEDGER_PROCESSES

if defined NEW_SHA (
    >"%STATE_DIR%\BAD_SHA.txt" echo !NEW_SHA!
    call :LOG "Marked commit !NEW_SHA! as BAD."
)

if defined LAST_DB_BACKUP (
    if exist "!LAST_DB_BACKUP!" (
        if exist "%DATA_DIR%\lederg.db" copy /Y "!LAST_DB_BACKUP!" "%DATA_DIR%\lederg.db" >nul
        call :LOG "Database backup restored after failed update."
    )
)

call :RESTORE_GOOD
call :START_SERVER
call :WAIT_HEALTH

if not errorlevel 1 (
    call :LOG "ROLLBACK SUCCESS: previous GOOD release is online."
    exit /b 1
)

call :LOG "CRITICAL: rollback release is also unhealthy."
exit /b 1

:DB_MAINTENANCE
if not exist "%APP_DIR%\scripts\db_maintenance.py" exit /b 0
if not exist "%DATA_DIR%\lederg.db" exit /b 0

call :LOG "Running SQLite maintenance..."
"%PYTHON%" "%APP_DIR%\scripts\db_maintenance.py" >>"%LOG_FILE%" 2>&1
if errorlevel 1 (
    call :LOG "SQLite maintenance reported an error."
    exit /b 1
)

exit /b 0

:BACKUP_DB
set "LAST_DB_BACKUP="

if not exist "%DATA_DIR%\lederg.db" (
    call :LOG "DB backup: database does not exist yet."
    exit /b 0
)

for /f %%A in ('powershell.exe -NoProfile -Command "Get-Date -Format yyyyMMdd_HHmmss"') do set "DBTS=%%A"
set "LAST_DB_BACKUP=%BACKUP_DIR%\lederg_!DBTS!.db"

copy /Y "%DATA_DIR%\lederg.db" "%LAST_DB_BACKUP%" >nul
if errorlevel 1 (
    call :LOG "DB backup FAILED."
    set "LAST_DB_BACKUP="
    exit /b 1
)

call :LOG "DB backup created: !LAST_DB_BACKUP!."
call :PRUNE_BACKUPS
exit /b 0

:PRUNE_BACKUPS
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Get-ChildItem -LiteralPath '%BACKUP_DIR%' -Filter 'lederg_*.db' -File -ErrorAction SilentlyContinue ^| Sort-Object LastWriteTime -Descending ^| Select-Object -Skip 20 ^| Remove-Item -Force -ErrorAction SilentlyContinue" >nul 2>&1
exit /b 0

:SNAPSHOT_GOOD
if not exist "%APP_DIR%\run.py" exit /b 1
if not exist "%APP_DIR%\server" exit /b 1

robocopy "%APP_DIR%" "%GOOD_DIR%" /MIR /R:2 /W:2 /COPY:DAT /XJ /XD ".git" ".venv" "__pycache__" "uploads" "smart-server" "autopilot" /XF ".env" >nul
set "RC=%ERRORLEVEL%"

if %RC% GEQ 8 (
    call :LOG "GOOD snapshot FAILED: robocopy=!RC!."
    exit /b 1
)

cd /d "%APP_DIR%"
set "GOOD_SHA="
for /f "delims=" %%A in ('git rev-parse HEAD 2^>nul') do set "GOOD_SHA=%%A"
if not defined GOOD_SHA exit /b 1

>"%STATE_DIR%\GOOD_SHA.txt" echo !GOOD_SHA!
call :LOG "GOOD snapshot saved: !GOOD_SHA!."
exit /b 0

:RESTORE_GOOD
if not exist "%GOOD_DIR%\run.py" (
    call :LOG "RESTORE FAILED: no GOOD release exists."
    exit /b 1
)

robocopy "%GOOD_DIR%" "%APP_DIR%" /MIR /R:2 /W:2 /COPY:DAT /XJ /XD ".git" ".venv" "__pycache__" "uploads" "smart-server" "autopilot" /XF ".env" >nul
set "RC=%ERRORLEVEL%"

if %RC% GEQ 8 (
    call :LOG "RESTORE FAILED: robocopy=!RC!."
    exit /b 1
)

if exist "%STATE_DIR%\GOOD_SHA.txt" (
    set "GOOD_SHA="
    set /p GOOD_SHA=<"%STATE_DIR%\GOOD_SHA.txt"
    if defined GOOD_SHA (
        cd /d "%APP_DIR%"
        git reset --hard !GOOD_SHA! >nul 2>&1
    )
)

if exist "%APP_DIR%\requirements.txt" (
    "%PYTHON%" -m pip install -r "%APP_DIR%\requirements.txt" --disable-pip-version-check >>"%LOG_FILE%" 2>&1
)

call :LOG "GOOD release restored."
exit /b 0

:DIAGNOSE
call :LOG "================ DIAGNOSTICS ================"
cd /d "%APP_DIR%"

for /f "delims=" %%A in ('git rev-parse --short HEAD 2^>nul') do call :LOG "Git HEAD: %%A"

"%PYTHON%" --version >>"%LOG_FILE%" 2>&1

powershell.exe -NoProfile -Command "Get-NetTCPConnection -LocalPort %PORT% -ErrorAction SilentlyContinue | Select-Object LocalAddress,LocalPort,State,OwningProcess | Format-Table -AutoSize" >>"%LOG_FILE%" 2>&1

if exist "%SERVER_LOG%" powershell.exe -NoProfile -Command "Get-Content -LiteralPath '%SERVER_LOG%' -Tail 100" >>"%LOG_FILE%" 2>&1
if exist "%SERVER_ERR%" powershell.exe -NoProfile -Command "Get-Content -LiteralPath '%SERVER_ERR%' -Tail 150" >>"%LOG_FILE%" 2>&1

schtasks /Query /TN "%TASK_NAME%" /FO LIST >>"%LOG_FILE%" 2>&1

call :LOG "================================================"
exit /b 0

:STATUS
call :INIT

echo ============================================================
echo LEDERG AUTOPILOT STATUS
echo ============================================================
echo.

schtasks /Query /TN "%TASK_NAME%" /FO LIST 2>nul
echo.

echo App:
echo %APP_DIR%
echo.

echo Git:
cd /d "%APP_DIR%"
git rev-parse --short HEAD 2>nul
echo.

echo Health:
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "try {$r=Invoke-RestMethod -Uri '%HEALTH_URL%' -TimeoutSec 5; 'OK='+$r.ok+' DB='+$r.database} catch {'OFFLINE'}"
echo.

echo Port:
powershell.exe -NoProfile -Command "Get-NetTCPConnection -LocalPort %PORT% -State Listen -ErrorAction SilentlyContinue | Select-Object LocalAddress,LocalPort,OwningProcess | Format-Table -AutoSize"
echo.

echo Python:
if exist "%PYTHON%" "%PYTHON%" --version
echo.

echo Logs:
echo %LOG_DIR%
pause
exit /b 0

:LOGS
call :INIT

for /f "delims=" %%A in ('powershell.exe -NoProfile -Command "(Get-ChildItem '%LOG_DIR%\guard_*.log' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName"') do set "LATEST=%%A"

if not defined LATEST (
    echo No logs yet.
    pause
    exit /b 0
)

start "" notepad.exe "!LATEST!"
exit /b 0

:UNINSTALL
echo ============================================================
echo LEDERG AUTOPILOT UNINSTALL
echo ============================================================
echo.

schtasks /End /TN "%TASK_NAME%" >nul 2>&1
schtasks /Delete /TN "%TASK_NAME%" /F >nul 2>&1

call :STOP_LEDGER_PROCESSES

echo Task removed.
echo Application, database, backups and GOOD release were NOT deleted.
pause
exit /b 0

:SAFE_MODE
call :LOG "SAFE MODE: autopilot remains alive and retries."
:SAFE_WAIT
timeout /t 60 /nobreak >nul
if not exist "%APP_DIR%\.git" goto SAFE_WAIT
call :LOG "SAFE MODE RETRY."
goto RUN
