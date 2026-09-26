@echo off
setlocal
set "APP_DIR=C:\LEDERG-MESSENGER"
set "REPO_URL=https://github.com/LEDERG777-TEXNARIC/LEDERG-GOLDEX.git"
set "BRANCH=main"
set "DATA_DIR=C:\LEDERG-MESSENGER-DATA"
if not exist "%DATA_DIR%" mkdir "%DATA_DIR%"
if not exist "%DATA_DIR%\logs" mkdir "%DATA_DIR%\logs"
where git >nul 2>nul
if errorlevel 1 exit /b 1
where powershell >nul 2>nul
if errorlevel 1 exit /b 1
if not exist "%APP_DIR%\.git" (
  if exist "%APP_DIR%" ren "%APP_DIR%" "LEDERG-MESSENGER_old_%RANDOM%"
  git clone --branch "%BRANCH%" "%REPO_URL%" "%APP_DIR%"
  if errorlevel 1 exit /b 1
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%APP_DIR%\scripts\autopilot.ps1"
exit /b %errorlevel%
