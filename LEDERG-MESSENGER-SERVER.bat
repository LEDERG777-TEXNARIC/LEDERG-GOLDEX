@echo off
setlocal EnableExtensions EnableDelayedExpansion
title LEDERG SMART SERVER GUARD

rem ============================================================
rem LEDERG SMART SERVER GUARD
rem Single BAT supervisor
rem ============================================================
rem - SYSTEM startup task
rem - local Git repository updates from origin/main
rem - checks GitHub every 5 seconds
rem - starts run.py directly
rem - monitors process + /health + SQLite
rem - DB maintenance + backup before releases
rem - GOOD release outside Git
rem - automatic rollback on bad release
rem - remembers bad commits and waits for a newer commit
rem - recovers the LEDERG process without killing unrelated ports
rem ============================================================

set "APP_DIR=C:\LEDERG-MESSENGER"
set "DATA_DIR=C:\LEDERG-MESSENGER-DATA"
set "BOOT_DIR=C:\LEDERG-MESSENGER-BOOT"
set "STATE_DIR=%DATA_DIR%\smart-server"
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
set "SCRIPT_NAME=LEDERG-MESSENGER-SERVER.bat"
set "BOOT_SCRIPT=%BOOT_DIR%\%SCRIPT_NAME%"

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
echo LEDERG SMART INSTALL
echo ============================================================
echo.

if not exist "%APP_DIR%" (
    echo ERROR: %APP_DIR% does not exist.
    echo Clone the LEDERG repository into %APP_DIR% first.
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
echo Installing / reconciling Python dependencies...
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
copy /Y "%~f0" "%BOOT_SCRIPT%" >nul
if errorlevel 1 (
    echo ERROR: Cannot install stable BAT copy into %BOOT_DIR%.
    pause
    exit /b 1
)

echo.
echo Creating SYSTEM startup task...
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop';$a=New-ScheduledTaskAction -Execute 'cmd.exe' -Argument ('/d /c ""' + 'C:\LEDERG-MESSENGER-BOOT\LEDERG-MESSENGER-SERVER.bat' + '"" run');$t=New-ScheduledTaskTrigger -AtStartup;$s=New-ScheduledTaskSettingsSet -Hidden -StartWhenAvailable -RestartCount 100 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew;$p=New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest;$task=New-ScheduledTask -Action $a -Trigger $t -Settings $s -Principal $p;Register-ScheduledTask -TaskName 'LEDERG-MESSENGER' -InputObject $task -Force | Out-Null"
if errorlevel 1 (
    echo ERROR: Task Scheduler creation failed.
    schtasks /Query /TN "%TASK_NAME%" /FO LIST
    pause
    exit /b 1
)

schtasks /Query /TN "%TASK_NAME%" /FO LIST >nul 2>&1
if errorlevel 1 (
    echo ERROR: Task Scheduler did not confirm the task.
    pause
    exit /b 1
)

echo.
echo Starting permanent LEDERG supervisor...
schtasks /Run /TN "%TASK_NAME%" >nul 2>&1
if errorlevel 1 (
    echo WARNING: task exists but could not be started immediately.
    echo It will start automatically after reboot.
)

echo.
echo ============================================================
echo LEDERG SMART GUARD INSTALLED SUCCESSFULLY
echo ============================================================
echo Task    : %TASK_NAME%
echo App     : %APP_DIR%
echo Port    : %PORT%
echo Check   : every %CHECK_SECONDS% seconds
echo Health  : %HEALTH_URL%
echo Logs    : %LOG_DIR%
echo GOOD    : %GOOD_DIR%
echo DB      : %DATA_DIR%\lederg.db
echo.
echo The task runs as SYSTEM and survives closing this window.
echo This BAT is outside the Git working tree.
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
call :LOG "LEDERG SMART GUARD STARTED."
call :LOG "App=%APP_DIR%"
call :LOG "Data=%DATA_DIR%"
call :LOG "Health=%HEALTH_URL%"
call :LOG "GitHub interval=%CHECK_SECONDS%s."
call :LOG "Task=%TASK_NAME%."

cd /d "%APP_DIR%"
if errorlevel 1 goto SAFE_MODE

where git.exe >nul 2>&1
if errorlevel 1 (
    call :LOG "FATAL: Git is missing."
    goto SAFE_MODE
)

if not exist "%APP_DIR%\.git" (
    call :LOG "FATAL: Git repository missing."
    goto SAFE_MODE
)

if not exist "%PYTHON%" (
    call :LOG "Python venv missing. Attempting automatic repair."
    call :ENSURE_PYTHON
    if errorlevel 1 goto SAFE_MODE
)

call :STOP_SERVER
call :START_SERVER
if errorlevel 1 (
    call :LOG "Initial start failed."
    if exist "%GOOD_DIR%\run.py" (
        call :LOG "GOOD release exists. Restoring it."
        call :RESTORE_GOOD
        call :START_SERVER
    )
)

call :WAIT_HEALTH
if not errorlevel 1 (
    if not exist "%GOOD_DIR%\run.py" (
        call :SNAPSHOT_GOOD
        if not errorlevel 1 call :LOG "Initial healthy release saved as GOOD."
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
for /f "delims=" %%A in ('powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$root=[regex]::Escape('%APP_DIR%');$p=Get-CimInstance Win32_Process -ErrorAction SilentlyContinue ^| Where-Object { $_.Name -match '^python(w)?\.exe$' -and $_.CommandLine -and $_.CommandLine -match $root -and $_.CommandLine -match '(^|\s)run\.py(\s|$)' } ^| Select-Object -First 1 -ExpandProperty ProcessId; if($p){$p}"') do set "SERVER_PID=%%A"
exit /b 0

:ENSURE_SERVER
call :STOP_SERVER
call :START_SERVER
if errorlevel 1 exit /b 1
call :WAIT_HEALTH
if errorlevel 1 (
    call :LOG "START FAILED: HTTP health did not become ready."
    call :DIAGNOSE
    call :STOP_SERVER
    exit /b 1
)
call :LOG "SERVICE HEALTHY."
exit /b 0

:START_SERVER
call :STOP_ORPHANED_LEDGER
for /f %%A in ('powershell.exe -NoProfile -Command "Get-Date -Format yyyyMMdd_HHmmss"') do set "RUN_TS=%%A"
set "SERVER_LOG=%LOG_DIR%\server_!RUN_TS!.log"
set "SERVER_ERR=%LOG_DIR%\server_!RUN_TS!_error.log"
set "SERVER_PID="
call :LOG "Starting run.py..."
for /f "delims=" %%A in ('powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$p=Start-Process -FilePath '%PYTHON%' -ArgumentList 'run.py' -WorkingDirectory '%APP_DIR%' -RedirectStandardOutput '%SERVER_LOG%' -RedirectStandardError '%SERVER_ERR%' -WindowStyle Hidden -PassThru; $p.Id"') do set "SERVER_PID=%%A"
if not defined SERVER_PID (
    call :LOG "ERROR: could not obtain Python PID."
    exit /b 1
)
call :LOG "Python PID=!SERVER_PID!."
exit /b 0

:STOP_SERVER
call :LOG "Stopping LEDERG processes."
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$root=[regex]::Escape('%APP_DIR%'); Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^python(w)?\.exe$' -and $_.CommandLine -and $_.CommandLine -match $root -and $_.CommandLine -match '(^|\s)run\.py(\s|$)' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }" >nul 2>&1
set "SERVER_PID="
timeout /t 2 /nobreak >nul
exit /b 0

:STOP_ORPHANED_LEDGER
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$root=[regex]::Escape('%APP_DIR%'); Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^python(w)?\.exe$' -and $_.CommandLine -and $_.CommandLine -match $root -and $_.CommandLine -match '(^|\s)run\.py(\s|$)' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }" >nul 2>&1
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$c=Get-NetTCPConnection -LocalPort %PORT% -State Listen -ErrorAction SilentlyContinue | Select-Object -ExpandProperty OwningProcess -Unique; foreach($pid in $c){$p=Get-CimInstance Win32_Process -Filter ('ProcessId='+$pid) -ErrorAction SilentlyContinue; if($p -and $p.CommandLine -and $p.CommandLine -match [regex]::Escape('%APP_DIR%') -and $p.CommandLine -match 'run\.py'){Stop-Process -Id $pid -Force -ErrorAction SilentlyContinue}}" >nul 2>&1
exit /b 0

:WAIT_HEALTH
set /a HWAIT=0
:WAIT_LOOP
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "try {$r=Invoke-RestMethod -Uri '%HEALTH_URL%' -TimeoutSec 4; if($r.ok -eq $true -and $r.database -eq 'ok'){exit 0}else{exit 1}}catch{exit 1}" >nul 2>&1
if not errorlevel 1 exit /b 0
set /a HWAIT+=1
if !HWAIT! GEQ %HEALTH_TIMEOUT% exit /b 1
call :FIND_LEDGER_PROCESS
if not defined SERVER_PID exit /b 1
tasklist /FI "PID eq !SERVER_PID!" | findstr /I "!SERVER_PID!" >nul
if errorlevel 1 exit /b 1
timeout /t 1 /nobreak >nul
goto WAIT_LOOP

:RECOVER_RUNTIME
set /a RCOUNT=0
:RECOVER
set /a RCOUNT+=1
call :LOG "Recovery attempt !RCOUNT!/%MAX_RECOVERY%."
call :DIAGNOSE
call :STOP_SERVER
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
    call :LOG "All recovery attempts failed. Entering SAFE MODE."
    goto SAFE_MODE
)
timeout /t 5 /nobreak >nul
goto RECOVER

:CHECK_UPDATE
cd /d "%APP_DIR%"
git fetch origin %BRANCH% --prune --quiet >nul 2>&1
if errorlevel 1 (
    call :LOG "GitHub check failed. Current release remains untouched."
    exit /b 0
)

set "LOCAL_SHA="
set "REMOTE_SHA="
for /f "delims=" %%A in ('git rev-parse HEAD 2^>nul') do set "LOCAL_SHA=%%A"
for /f "delims=" %%A in ('git rev-parse origin/%BRANCH% 2^>nul') do set "REMOTE_SHA=%%A"
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
call :LOG "UPDATE START"
call :STOP_SERVER
call :DB_MAINTENANCE
call :BACKUP_DB
if errorlevel 1 (
    call :LOG "UPDATE ABORTED: DB backup failed."
    call :ENSURE_SERVER
    exit /b 1
)

call :SNAPSHOT_GOOD
if errorlevel 1 (
    call :LOG "UPDATE ABORTED: GOOD snapshot failed."
    call :ENSURE_SERVER
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
    call :LOG "UPDATE FAIL: database maintenance check failed."
    goto UPDATE_FAIL
)

call :START_SERVER
if errorlevel 1 goto UPDATE_FAIL
call :WAIT_HEALTH
if errorlevel 1 (
    call :LOG "UPDATE FAIL: HTTP health check failed."
    goto UPDATE_FAIL
)

call :LOG "UPDATE SUCCESS: !NEW_SHA! is healthy."
call :SNAPSHOT_GOOD
del /q "%STATE_DIR%\BAD_SHA.txt" >nul 2>&1
call :PRUNE_BACKUPS
call :LOG "UPDATE COMPLETE"
exit /b 0

:UPDATE_FAIL
call :DIAGNOSE
call :STOP_SERVER
if defined NEW_SHA (
    >"%STATE_DIR%\BAD_SHA.txt" echo !NEW_SHA!
    call :LOG "Marked commit !NEW_SHA! as BAD."
)
if defined LAST_DB_BACKUP (
    if exist "!LAST_DB_BACKUP!" (
        if exist "%DATA_DIR%\lederg.db" copy /Y "!LAST_DB_BACKUP!" "%DATA_DIR%\lederg.db" >nul
        call :LOG "Restored DB backup after failed release."
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
goto SAFE_MODE

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
    call :LOG "DB backup: database file does not exist yet."
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
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Get-ChildItem -LiteralPath '%BACKUP_DIR%' -Filter 'lederg_*.db' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -Skip 20 | Remove-Item -Force -ErrorAction SilentlyContinue" >nul 2>&1
exit /b 0

:SNAPSHOT_GOOD
if not exist "%APP_DIR%\run.py" exit /b 1
if not exist "%APP_DIR%\server" exit /b 1
robocopy "%APP_DIR%" "%GOOD_DIR%" /MIR /R:2 /W:2 /COPY:DAT /XJ /XD ".git" ".venv" "__pycache__" "uploads" "smart-server" /XF ".env" >nul
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
    call :LOG "RESTORE FAILED: no GOOD release."
    exit /b 1
)

robocopy "%GOOD_DIR%" "%APP_DIR%" /MIR /R:2 /W:2 /COPY:DAT /XJ /XD ".git" ".venv" "__pycache__" "uploads" "smart-server" /XF ".env" >nul
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
if exist "%SERVER_LOG%" powershell.exe -NoProfile -Command "Get-Content -LiteralPath '%SERVER_LOG%' -Tail 80" >>"%LOG_FILE%" 2>&1
if exist "%SERVER_ERR%" powershell.exe -NoProfile -Command "Get-Content -LiteralPath '%SERVER_ERR%' -Tail 120" >>"%LOG_FILE%" 2>&1
schtasks /Query /TN "%TASK_NAME%" /FO LIST >>"%LOG_FILE%" 2>&1
call :LOG "================================================"
exit /b 0

:STATUS
call :INIT
echo ============================================================
echo LEDERG SMART STATUS
echo ============================================================
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
powershell.exe -NoProfile -Command "try {$r=Invoke-RestMethod -Uri '%HEALTH_URL%' -TimeoutSec 5; 'OK='+$r.ok+' DB='+$r.database} catch {'OFFLINE'}"
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
echo Removing LEDERG scheduled task...
schtasks /End /TN "%TASK_NAME%" >nul 2>&1
schtasks /Delete /TN "%TASK_NAME%" /F >nul 2>&1
echo Task removed. Application, database and backups were NOT deleted.
pause
exit /b 0

:SAFE_MODE
call :LOG "SAFE MODE: supervisor stays alive and retries."
:SAFE_WAIT
timeout /t 60 /nobreak >nul
if not exist "%APP_DIR%\.git" goto SAFE_WAIT
call :LOG "SAFE MODE RETRY."
goto RUN
