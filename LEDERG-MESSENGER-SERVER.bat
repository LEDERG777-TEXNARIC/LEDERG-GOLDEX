@echo off
setlocal EnableExtensions

set "BOOT_DIR=C:\LEDERG-MESSENGER-BOOT"
set "SUPERVISOR=%BOOT_DIR%\supervisor.ps1"
set "TMP=%BOOT_DIR%\supervisor.new.ps1"
set "RAW=https://raw.githubusercontent.com/LEDERG777-TEXNARIC/LEDERG-GOLDEX/main/scripts/supervisor.ps1"
set "TASK=LEDERG-AUTOPILOT"

if not exist "%BOOT_DIR%" mkdir "%BOOT_DIR%"

where powershell.exe >nul 2>nul
if errorlevel 1 (
    echo [LEDERG] PowerShell is required.
    exit /b 1
)

rem If the permanent task already exists, just start it. No UAC and no manual update.
schtasks /Query /TN "%TASK%" >nul 2>&1
if not errorlevel 1 (
    schtasks /Run /TN "%TASK%" >nul 2>&1
    exit /b 0
)

rem First-time installation needs administrator rights.
net session >nul 2>&1
if errorlevel 1 (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%ComSpec%' -ArgumentList '/c ""%~f0""' -Verb RunAs"
    exit /b 0
)

echo [LEDERG] Installing permanent autopilot...

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop';$u='%RAW%';$p='%TMP%';$c=(Invoke-WebRequest -UseBasicParsing -Uri $u -TimeoutSec 20).Content;if([string]::IsNullOrWhiteSpace($c)){throw 'Empty supervisor'};$e=New-Object System.Text.UTF8Encoding($false);[IO.File]::WriteAllText($p,$c,$e)"
if errorlevel 1 (
    if not exist "%SUPERVISOR%" (
        echo [LEDERG] GitHub is unavailable and no cached supervisor exists.
        exit /b 1
    )
) else (
    move /Y "%TMP%" "%SUPERVISOR%" >nul
)

if not exist "%SUPERVISOR%" (
    echo [LEDERG] Supervisor missing.
    exit /b 1
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop';$a=New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""C:\LEDERG-MESSENGER-BOOT\supervisor.ps1""';$t=New-ScheduledTaskTrigger -AtStartup;$s=New-ScheduledTaskSettingsSet -Hidden -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Days 3650) -RestartCount 20 -RestartInterval (New-TimeSpan -Minutes 1);$p=New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest;$task=New-ScheduledTask -Action $a -Trigger $t -Settings $s -Principal $p;Register-ScheduledTask -TaskName 'LEDERG-AUTOPILOT' -InputObject $task -Force | Out-Null"
if errorlevel 1 (
    echo [LEDERG] Could not create the Windows autopilot task.
    exit /b 1
)

schtasks /Run /TN "%TASK%" >nul 2>&1
if errorlevel 1 (
    echo [LEDERG] Task was created but could not be started immediately.
    echo [LEDERG] It will start automatically with Windows.
    exit /b 0
)

echo [LEDERG] FULL AUTOPILOT INSTALLED.
echo [LEDERG] Future updates are automatic.
exit /b 0
