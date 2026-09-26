@echo off
setlocal
set "APP_DIR=C:\LEDERG-MESSENGER"
set "REPO_URL=https://github.com/LEDERG777-TEXNARIC/LEDERG-GOLDEX.git"
set "BRANCH=main"
set "DATA_DIR=C:\LEDERG-MESSENGER-DATA"
if not exist "%DATA_DIR%" mkdir "%DATA_DIR%"
if not exist "%DATA_DIR%\logs" mkdir "%DATA_DIR%\logs"

where git >nul 2>nul
if errorlevel 1 (
  echo [ERROR] Git not found in PATH.
  exit /b 1
)
where powershell >nul 2>nul
if errorlevel 1 (
  echo [ERROR] PowerShell not found.
  exit /b 1
)

if not exist "%APP_DIR%\.git" (
  if exist "%APP_DIR%" ren "%APP_DIR%" "LEDERG-MESSENGER_old_%RANDOM%"
  echo [BOOTSTRAP] Cloning LEDERG-GOLDEX...
  git clone --branch "%BRANCH%" "%REPO_URL%" "%APP_DIR%"
  if errorlevel 1 (
    echo [ERROR] Clone failed.
    exit /b 1
  )
) else (
  git -C "%APP_DIR%" remote set-url origin "%REPO_URL%" >nul 2>&1
  if not exist "%APP_DIR%\scripts\autopilot.ps1" (
    echo [BOOTSTRAP] Updating local launcher files...
    git -C "%APP_DIR%" fetch origin "%BRANCH%" --prune
    if errorlevel 1 (
      echo [ERROR] GitHub fetch failed.
      exit /b 1
    )
    git -C "%APP_DIR%" reset --hard "origin/%BRANCH%"
    if errorlevel 1 (
      echo [ERROR] Bootstrap update failed.
      exit /b 1
    )
  )
)

if not exist "%APP_DIR%\scripts\autopilot.ps1" (
  echo [ERROR] autopilot.ps1 is missing after bootstrap.
  exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%APP_DIR%\scripts\autopilot.ps1"
exit /b %errorlevel%
