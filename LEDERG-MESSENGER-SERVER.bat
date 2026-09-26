@echo off
setlocal EnableExtensions EnableDelayedExpansion

set "BOOT_DIR=C:\LEDERG-MESSENGER-BOOT"
set "SUPERVISOR=%BOOT_DIR%\supervisor.ps1"
set "TMP=%BOOT_DIR%\supervisor.new.ps1"
set "RAW=https://raw.githubusercontent.com/LEDERG777-TEXNARIC/LEDERG-GOLDEX/main/scripts/supervisor.ps1"
set "TASK=LEDERG-AUTOPILOT"
set "APP_DIR=C:\LEDERG-MESSENGER"
set "DATA_DIR=C:\LEDERG-MESSENGER-DATA"
set "LOG=%DATA_DIR%\logs\supervisor.log"

if not exist "%BOOT_DIR%" mkdir "%BOOT_DIR%"
if not exist "%DATA_DIR%\logs" mkdir "%DATA_DIR%\logs"

where powershell.exe >nul 2>nul
if errorlevel 1 (
    echo [LEDERG] PowerShell not found.
    pause
    exit /b 1
)

rem One-time elevation only when the Windows task does not exist yet.
schtasks /Query /TN "%TASK%" >nul 2>&1
if errorlevel 1 (
    net session >nul 2>&1
    if errorlevel 1 (
        powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%ComSpec%' -ArgumentList '/c ""%~f0""' -Verb RunAs"
        exit /b 0
    )

    echo [LEDERG] Installing full automatic supervisor...

    powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop';$u='%RAW%';$p='%TMP%';$c=(Invoke-WebRequest -UseBasicParsing -Uri $u -TimeoutSec 20).Content;if([string]::IsNullOrWhiteSpace($c)){throw 'Empty supervisor'};$e=New-Object System.Text.UTF8Encoding($false);[IO.File]::WriteAllText($p,$c,$e)"
    if errorlevel 1 (
        echo [LEDERG] Could not download supervisor from GitHub.
        pause
        exit /b 1
    )

    move /Y "%TMP%" "%SUPERVISOR%" >nul
    if errorlevel 1 (
        echo [LEDERG] Could not install supervisor.
        pause
        exit /b 1
    )

    powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop';$a=New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""C:\LEDERG-MESSENGER-BOOT\supervisor.ps1""';$t=New-ScheduledTaskTrigger -AtStartup;$s=New-ScheduledTaskSettingsSet -Hidden -StartWhenAvailable -RestartCount 50 -RestartInterval (New-TimeSpan -Minutes 1);$p=New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest;$task=New-ScheduledTask -Action $a -Trigger $t -Settings $s -Principal $p -MultipleInstances IgnoreNew;Register-ScheduledTask -TaskName 'LEDERG-AUTOPILOT' -InputObject $task -Force | Out-Null"
    if errorlevel 1 (
        echo [LEDERG] Could not create Windows autopilot task.
        pause
        exit /b 1
    )

    schtasks /Run /TN "%TASK%" >nul 2>&1
    if errorlevel 1 (
        echo [LEDERG] Autopilot task was created but could not be started immediately.
        echo [LEDERG] It will start automatically with Windows.
    )
)

if not exist "%SUPERVISOR%" (
    echo [LEDERG] Supervisor file is missing.
    pause
    exit /b 1
)

echo ============================================================
echo             LEDERG FULL AUTOPILOT IS RUNNING
echo             GitHub: LEDERG-GOLDEX / main
echo             Messenger: %APP_DIR%
echo             Port: 8000
echo             Window will stay open and monitor the server.
echo ============================================================
echo.

:MONITOR
schtasks /Query /TN "%TASK%" /FO LIST /V 2>nul | findstr /I "Status" 
echo [%DATE% %TIME%] Next automatic check in 60 seconds...
if exist "%LOG%" (
    echo ---------------- LAST SUPERVISOR LOG ----------------
    powershell.exe -NoProfile -Command "Get-Content -LiteralPath '%LOG%' -Tail 8"
    echo ------------------------------------------------------
)
timeout /t 60 /nobreak >nul
goto MONITOR
