@echo off
setlocal EnableExtensions EnableDelayedExpansion
set "REPO_URL=https://github.com/LEDERG777-TEXNARIC/LEDERG-GOLDEX.git"
set "BRANCH=main"
set "APP_DIR=C:\LEDERG-MESSENGER"
set "DATA_DIR=C:\LEDERG-MESSENGER-DATA"
set "BACKUP_DIR=C:\LEDERG-MESSENGER-DATA\backups"
set "CHECK_SECONDS=60"
set "PORT=8000"
set "APP_TASK=LEDERG-MESSENGER"

if /I "%~1"=="install" goto INSTALL
if /I "%~1"=="run" goto RUN
if /I "%~1"=="update" goto UPDATE
if /I "%~1"=="check" goto CHECK
if /I "%~1"=="start" goto START
if /I "%~1"=="stop" goto STOP
if /I "%~1"=="repair" goto REPAIR
if /I "%~1"=="rollback" goto ROLLBACK
goto RUN

:TOOLS
where git >nul 2>nul || (echo [ERROR] Git missing.&exit /b 1)
where powershell >nul 2>nul || (echo [ERROR] PowerShell missing.&exit /b 1)
exit /b 0

:DIRS
if not exist "%DATA_DIR%" mkdir "%DATA_DIR%"
if not exist "%BACKUP_DIR%" mkdir "%BACKUP_DIR%"
if not exist "%DATA_DIR%\uploads" mkdir "%DATA_DIR%\uploads"
if not exist "%DATA_DIR%\logs" mkdir "%DATA_DIR%\logs"
exit /b 0

:FETCH
for /l %%N in (1,1,5) do (
  git fetch origin "%BRANCH%" --quiet
  if not errorlevel 1 exit /b 0
  echo [GitHub] Retry %%N/5...
  timeout /t 5 /nobreak >nul
)
exit /b 1

:BACKUP
if not exist "%DATA_DIR%\lederg.db" exit /b 0
for /f %%A in ('powershell -NoProfile -Command "Get-Date -Format yyyyMMdd_HHmmss"') do set "STAMP=%%A"
copy /Y "%DATA_DIR%\lederg.db" "%BACKUP_DIR%\lederg_!STAMP!.db" >nul
if errorlevel 1 exit /b 1
echo [DB] Backup !STAMP!
exit /b 0

:TASK_CREATE
(
echo @echo off
echo cd /d "%APP_DIR%"
echo "%APP_DIR%\.venv\Scripts\python.exe" "%APP_DIR%\run.py" ^>^> "%DATA_DIR%\logs\server.log" 2^>^&1
) > "%DATA_DIR%\start.bat"
schtasks /Create /TN "%APP_TASK%" /SC ONSTART /RU SYSTEM /RL HIGHEST /F /TR "\"%DATA_DIR%\start.bat\"" >nul 2>&1
exit /b 0

:START_TASK
schtasks /Run /TN "%APP_TASK%" >nul 2>&1
exit /b 0

:STOP_TASK
schtasks /End /TN "%APP_TASK%" >nul 2>&1
exit /b 0

:HEALTH
powershell -NoProfile -ExecutionPolicy Bypass -File "%APP_DIR%\scripts\healthcheck.ps1" >nul 2>&1
exit /b %errorlevel%

:INSTALL
call :TOOLS || goto FAIL
call :DIRS
if not exist "%APP_DIR%\.git" (
  if exist "%APP_DIR%" (
    for /f %%A in ('powershell -NoProfile -Command "Get-Date -Format yyyyMMdd_HHmmss"') do set "OLD=!APP_DIR!_old_%%A"
    move "%APP_DIR%" "!OLD!" >nul || goto FAIL
  )
  git clone --branch "%BRANCH%" "%REPO_URL%" "%APP_DIR%" || goto FAIL
) else (
  cd /d "%APP_DIR%"
  call :FETCH || goto FAIL
  git reset --hard "origin/%BRANCH%" || goto FAIL
)
cd /d "%APP_DIR%"
if not exist ".venv\Scripts\python.exe" py -3 -m venv .venv
if errorlevel 1 goto FAIL
".venv\Scripts\python.exe" -m pip install -r requirements.txt --disable-pip-version-check || goto FAIL
call :TASK_CREATE
call :START_TASK
timeout /t 3 /nobreak >nul
call :HEALTH
if errorlevel 1 (
  echo [ERROR] Server did not pass health check.
  call :STOP_TASK
  goto FAIL
)
echo [SUCCESS] LEDERG Messenger installed.
goto DONE

:UPDATE
call :TOOLS || goto FAIL
call :DIRS
if not exist "%APP_DIR%\.git" goto INSTALL
cd /d "%APP_DIR%"
call :FETCH || goto FAIL
for /f %%A in ('git rev-parse HEAD') do set "LOCAL=%%A"
for /f %%A in ('git rev-parse origin/%BRANCH%') do set "REMOTE=%%A"
if /I "!LOCAL!"=="!REMOTE!" (
  echo [OK] Already current: !LOCAL:~0,7!
  goto DONE
)
call :BACKUP || goto FAIL
call :STOP_TASK
timeout /t 2 /nobreak >nul
git reset --hard "origin/%BRANCH%" || (
  call :START_TASK
  goto FAIL
)
git clean -fd
".venv\Scripts\python.exe" -m pip install -r requirements.txt --disable-pip-version-check || (
  call :START_TASK
  goto FAIL
)
call :TASK_CREATE
call :START_TASK
timeout /t 4 /nobreak >nul
call :HEALTH
if errorlevel 1 (
  echo [ROLLBACK] Health check failed. Restoring previous commit...
  call :STOP_TASK
  git reset --hard "!LOCAL!"
  ".venv\Scripts\python.exe" -m pip install -r requirements.txt --disable-pip-version-check >nul 2>&1
  call :TASK_CREATE
  call :START_TASK
  goto FAIL
)
for /f %%A in ('git rev-parse --short HEAD') do set "NEW=%%A"
echo [SUCCESS] Updated to !NEW!
goto DONE

:CHECK
call :TOOLS || goto FAIL
if not exist "%APP_DIR%\.git" (echo [INFO] Not installed.&goto DONE)
cd /d "%APP_DIR%"
call :FETCH || goto FAIL
for /f %%A in ('git rev-parse HEAD') do set "LOCAL=%%A"
for /f %%A in ('git rev-parse origin/%BRANCH%') do set "REMOTE=%%A"
echo Local : !LOCAL!
echo Remote: !REMOTE!
if /I "!LOCAL!"=="!REMOTE!" (echo [OK] Up to date.) else (echo [UPDATE] New commit available.)
goto DONE

:RUN
call :TOOLS || goto FAIL
call :DIRS
if not exist "%APP_DIR%\.git" call :INSTALL
:LOOP
call :UPDATE >nul 2>&1
if errorlevel 1 echo [%DATE% %TIME%] [WARNING] Update/health cycle failed.
timeout /t %CHECK_SECONDS% /nobreak >nul
goto LOOP

:START
call :START_TASK
goto DONE
:STOP
call :STOP_TASK
goto DONE
:REPAIR
call :INSTALL
goto DONE
:ROLLBACK
if not exist "%APP_DIR%\.git" goto FAIL
cd /d "%APP_DIR%"
call :FETCH || goto FAIL
for /f %%A in ('git rev-parse HEAD~1') do set "PREV=%%A"
call :STOP_TASK
git reset --hard "!PREV!"
call :TASK_CREATE
call :START_TASK
goto DONE

:FAIL
echo [FAILED]
exit /b 1
:DONE
echo [DONE]
exit /b 0
