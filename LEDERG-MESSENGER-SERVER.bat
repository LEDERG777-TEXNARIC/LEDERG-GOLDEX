@echo off
setlocal EnableExtensions
set "BOOT_DIR=C:\LEDERG-MESSENGER-BOOT"
set "RUNNER=%BOOT_DIR%\autopilot.ps1"
set "TMP=%BOOT_DIR%\autopilot.ps1.new"
set "RAW=https://raw.githubusercontent.com/LEDERG777-TEXNARIC/LEDERG-GOLDEX/main/scripts/autopilot.ps1"

if not exist "%BOOT_DIR%" mkdir "%BOOT_DIR%"

where powershell.exe >nul 2>nul
if errorlevel 1 (
    echo [ERROR] PowerShell not found.
    exit /b 1
)

echo [LEDERG] Downloading latest autopilot...
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; $u='%RAW%'; $p='%TMP%'; $c=(Invoke-WebRequest -UseBasicParsing -Uri $u -TimeoutSec 20).Content; if([string]::IsNullOrWhiteSpace($c)){throw 'Empty runner'}; [IO.File]::WriteAllText($p,$c,[Text.Encoding]::UTF8)"
if errorlevel 1 (
    if not exist "%RUNNER%" (
        echo [ERROR] GitHub unavailable and no cached autopilot exists.
        exit /b 1
    )
    echo [WARN] GitHub unavailable. Starting cached autopilot.
) else (
    move /Y "%TMP%" "%RUNNER%" >nul
)

start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%RUNNER%"
exit /b 0
