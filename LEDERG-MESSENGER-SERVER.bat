@echo off
setlocal EnableExtensions EnableDelayedExpansion
title LEDERG FULL AUTOPILOT

set "BOOT_DIR=C:\LEDERG-MESSENGER-BOOT"
set "SUPERVISOR=%BOOT_DIR%\supervisor.ps1"
set "TASK=LEDERG-AUTOPILOT"
set "DATA_DIR=C:\LEDERG-MESSENGER-DATA"
set "LOG=%DATA_DIR%\logs\supervisor.log"
set "RAW=https://raw.githubusercontent.com/LEDERG777-TEXNARIC/LEDERG-GOLDEX/main/scripts/supervisor.ps1"
set "DL=%TEMP%\lederg-supervisor-%RANDOM%-%RANDOM%.ps1"

if not exist "%BOOT_DIR%" mkdir "%BOOT_DIR%"
if not exist "%DATA_DIR%\logs" mkdir "%DATA_DIR%\logs"

where powershell.exe >nul 2>&1
if errorlevel 1 (
  echo [ERROR] PowerShell is not available.
  pause
  exit /b 1
)

where curl.exe >nul 2>&1
if errorlevel 1 (
  echo [ERROR] curl.exe is not available.
  pause
  exit /b 1
)

schtasks /Query /TN "%TASK%" >nul 2>&1
if errorlevel 1 goto INSTALL
goto MONITOR

:INSTALL
net session >nul 2>&1
if errorlevel 1 (
  echo [LEDERG] Requesting administrator rights...
  powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%ComSpec%' -ArgumentList '/c ""%~f0""' -Verb RunAs"
  exit /b 0
)

echo ============================================================
echo              LEDERG FULL AUTOPILOT SETUP
echo ============================================================
echo [1/4] Downloading supervisor to Windows TEMP...

del /q "%DL%" >nul 2>&1
curl.exe -fL --retry 5 --retry-delay 2 --connect-timeout 10 --max-time 60 -sS -o "%DL%" "%RAW%"
if errorlevel 1 (
  echo [ERROR] GitHub download failed.
  echo [ERROR] Local destination: %DL%
  echo.
  echo Trying PowerShell fallback...
  powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$ProgressPreference='SilentlyContinue';Invoke-WebRequest -UseBasicParsing -Uri '%RAW%' -OutFile '%DL%' -TimeoutSec 60"
  if errorlevel 1 (
    echo [ERROR] PowerShell fallback also failed.
    pause
    exit /b 1
  )
)

if not exist "%DL%" (
  echo [ERROR] Downloaded file does not exist.
  pause
  exit /b 1
)

for %%A in ("%DL%") do if %%~zA LSS 1000 (
  echo [ERROR] Downloaded supervisor is too small.
  del /q "%DL%" >nul 2>&1
  pause
  exit /b 1
)

echo [2/4] Installing supervisor...
copy /Y "%DL%" "%SUPERVISOR%" >nul
if errorlevel 1 (
  echo [ERROR] Cannot copy supervisor into %BOOT_DIR%.
  echo Check folder permissions.
  del /q "%DL%" >nul 2>&1
  pause
  exit /b 1
)
del /q "%DL%" >nul 2>&1

if not exist "%SUPERVISOR%" (
  echo [ERROR] Supervisor was not installed.
  pause
  exit /b 1
)

echo [3/4] Creating permanent Windows task...
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop';$a=New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""C:\LEDERG-MESSENGER-BOOT\supervisor.ps1""';$t=New-ScheduledTaskTrigger -AtStartup;$s=New-ScheduledTaskSettingsSet -Hidden -StartWhenAvailable -RestartCount 50 -RestartInterval (New-TimeSpan -Minutes 1) -MultipleInstances IgnoreNew;$p=New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest;$task=New-ScheduledTask -Action $a -Trigger $t -Settings $s -Principal $p;Register-ScheduledTask -TaskName 'LEDERG-AUTOPILOT' -InputObject $task -Force | Out-Null"
if errorlevel 1 (
  echo [ERROR] Could not create LEDERG-AUTOPILOT.
  pause
  exit /b 1
)

echo [4/4] Starting permanent autopilot...
schtasks /Run /TN "%TASK%" >nul 2>&1

echo.
echo [OK] FULL AUTOPILOT INSTALLED.
echo [OK] GitHub updates: automatic
echo [OK] Server restart: automatic
echo [OK] Port 8000 recovery: automatic
echo [OK] DB backup/check: automatic
echo [OK] Rollback: automatic
echo.

:MONITOR
echo ============================================================
echo                 LEDERG FULL AUTOPILOT
echo ============================================================
echo Repository : LEDERG-GOLDEX / main
echo Server     : port 8000
echo Task       : %TASK%
echo Monitor    : ACTIVE
echo ============================================================
echo.

:LOOP
schtasks /Query /TN "%TASK%" >nul 2>&1
if errorlevel 1 (
  echo [WARN] Autopilot task is really missing. Reinstalling...
  goto INSTALL
)

set "TASK_STATUS=Unknown"
for /f "delims=" %%A in ('powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$t=Get-ScheduledTask -TaskName '%TASK%' -ErrorAction SilentlyContinue; if($t){$t.State}" 2^>nul') do set "TASK_STATUS=%%A"

if /I "%TASK_STATUS%"=="Running" (
  echo [LEDERG] Autopilot task: Running
) else (
  echo [WARN] Autopilot task state: %TASK_STATUS%. Starting...
  schtasks /Run /TN "%TASK%" >nul 2>&1
  if errorlevel 1 echo [WARN] Could not start task right now; supervisor will retry automatically.
)
if exist "%LOG%" (
  echo ---------------- LAST LOG ----------------
  powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Get-Content -LiteralPath '%LOG%' -Tail 10"
  echo -------------------------------------------
)
echo [%DATE% %TIME%] Next check in 60 seconds...
timeout /t 60 /nobreak >nul
goto LOOP
