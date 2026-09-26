# LEDERG Messenger full autopilot
param([switch]$Once)

$ErrorActionPreference = "Stop"

$RepoUrl = "https://github.com/LEDERG777-TEXNARIC/LEDERG-GOLDEX.git"
$Branch = "main"
$AppDir = "C:\LEDERG-MESSENGER"
$DataDir = "C:\LEDERG-MESSENGER-DATA"
$BackupDir = Join-Path $DataDir "backups"
$LogDir = Join-Path $DataDir "logs"
$LogFile = Join-Path $LogDir "autopilot.log"
$GoodFile = Join-Path $DataDir "last-known-good.txt"
$GoodHistory = Join-Path $DataDir "known-good-history.txt"
$Port = 8000
$ServerTask = "LEDERG-MESSENGER"
$ServerTaskBat = Join-Path $DataDir "start-server.bat"

New-Item -ItemType Directory -Force -Path $DataDir,$BackupDir,$LogDir | Out-Null

function Log([string]$Message) {
    $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
    Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8
}

$mutex = New-Object System.Threading.Mutex($false,"Global\LEDERG-MESSENGER-AUTOPILOT")
if (-not $mutex.WaitOne(0)) { exit 0 }

function Run-Git([string[]]$Args) {
    $out = & git @Args 2>&1
    if ($LASTEXITCODE -ne 0) { throw "git $($Args -join ' ') failed: $out" }
    return $out
}
function Head([string]$Ref) { return (& git -C $AppDir rev-parse $Ref).Trim() }

function Ensure-Repo {
    if (Test-Path (Join-Path $AppDir ".git")) {
        & git -C $AppDir remote set-url origin $RepoUrl 2>$null | Out-Null
        return
    }

    if (Test-Path $AppDir) {
        $old = $AppDir + "_old_" + (Get-Date -Format "yyyyMMdd_HHmmss")
        Move-Item $AppDir $old -Force
    }

    Log "Cloning repository."
    & git clone --branch $Branch $RepoUrl $AppDir 2>&1 | ForEach-Object { Log $_ }
    if ($LASTEXITCODE -ne 0) { throw "Git clone failed" }
}

function Find-PythonLauncher {
    foreach ($name in @("py.exe","python.exe")) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue
        if ($cmd) { return $cmd.Source }
    }
    return $null
}

function Ensure-Venv {
    $py = Join-Path $AppDir ".venv\Scripts\python.exe"
    if (Test-Path $py) { return $py }

    $launcher = Find-PythonLauncher
    if (-not $launcher) { throw "Python launcher not found" }

    Log "Creating Python virtual environment."
    if ($launcher.ToLower().EndsWith("py.exe")) {
        & $launcher -3 -m venv (Join-Path $AppDir ".venv") 2>&1 | ForEach-Object { Log $_ }
    } else {
        & $launcher -m venv (Join-Path $AppDir ".venv") 2>&1 | ForEach-Object { Log $_ }
    }
    if ($LASTEXITCODE -ne 0) { throw "Virtual environment creation failed" }
    return $py
}

function Install-Dependencies([string]$Py) {
    & $Py -m pip install -r (Join-Path $AppDir "requirements.txt") --disable-pip-version-check --no-input 2>&1 |
        ForEach-Object { Log $_ }
    if ($LASTEXITCODE -ne 0) { throw "Dependency installation failed" }
}

function Compile-Check([string]$Py) {
    & $Py -m compileall -q (Join-Path $AppDir "server") (Join-Path $AppDir "run.py") 2>&1 |
        ForEach-Object { Log $_ }
    if ($LASTEXITCODE -ne 0) { throw "Python compile check failed" }
}

function DB-Check([string]$Py) {
    $script = Join-Path $AppDir "scripts\db_maintenance.py"
    if (-not (Test-Path $script)) { return }
    & $Py $script 2>&1 | ForEach-Object { Log $_ }
    if ($LASTEXITCODE -ne 0) { throw "Database maintenance failed" }
}

function Create-Server-Task {
@"
@echo off
cd /d "$AppDir"
set "LEDERG_HOST=0.0.0.0"
set "LEDERG_PORT=$Port"
"$AppDir\.venv\Scripts\python.exe" "$AppDir\run.py" >> "$DataDir\logs\server.log" 2>&1
"@ | Set-Content -LiteralPath $ServerTaskBat -Encoding ASCII

    & schtasks /Create /TN $ServerTask /SC ONSTART /RU SYSTEM /RL HIGHEST /F /TR ('"' + $ServerTaskBat + '"') 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Server scheduled task creation failed" }
}

function Start-Server {
    & schtasks /Run /TN $ServerTask 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Server scheduled task start failed" }
    Start-Sleep -Seconds 4
}

function Stop-Server {
    & schtasks /End /TN $ServerTask 2>&1 | Out-Null
    Start-Sleep -Seconds 2

    try {
        Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -like "*$AppDir\run.py*" } |
            ForEach-Object {
                Invoke-CimMethod -InputObject $_ -MethodName Terminate -ErrorAction SilentlyContinue | Out-Null
            }
    } catch {}
    Start-Sleep -Seconds 1
}

function Is-Healthy {
    try {
        $r = Invoke-RestMethod "http://127.0.0.1:$Port/health" -TimeoutSec 8
        return ($r.ok -eq $true -and $r.database -eq "ok")
    } catch {
        return $false
    }
}

function Backup-Database {
    $db = Join-Path $DataDir "lederg.db"
    if (-not (Test-Path $db)) { return $null }

    $stamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $dest = Join-Path $BackupDir "lederg_$stamp.db"

    Copy-Item $db $dest -Force
    foreach ($suffix in @("-wal","-shm")) {
        $src = "$db$suffix"
        if (Test-Path $src) { Copy-Item $src "$dest$suffix" -Force }
    }

    Get-ChildItem $BackupDir -Filter "lederg_*.db" |
        Sort-Object LastWriteTime -Descending |
        Select-Object -Skip 20 |
        Remove-Item -Force -ErrorAction SilentlyContinue

    Log "Database backup: $dest"
    return $dest
}

function Restore-Database([string]$Backup) {
    if (-not $Backup) { return }
    $db = Join-Path $DataDir "lederg.db"
    Copy-Item $Backup $db -Force

    foreach ($suffix in @("-wal","-shm")) {
        $src = "$Backup$suffix"
        $dst = "$db$suffix"
        if (Test-Path $src) {
            Copy-Item $src $dst -Force
        } elseif (Test-Path $dst) {
            Remove-Item $dst -Force -ErrorAction SilentlyContinue
        }
    }
    Log "Database restored from backup."
}

function Read-GoodHistory {
    if (-not (Test-Path $GoodHistory)) { return @() }
    return @(
        Get-Content $GoodHistory |
        Where-Object { $_ -match "^[0-9a-f]{40}$" } |
        Select-Object -Unique
    )
}

function Record-Good([string]$Commit) {
    $items = @($Commit) + (Read-GoodHistory)
    $items = @($items | Select-Object -Unique | Select-Object -First 10)
    Set-Content -LiteralPath $GoodHistory -Value $items -Encoding ASCII
    Set-Content -LiteralPath $GoodFile -Value $Commit -Encoding ASCII
}

function Best-Rollback([string]$Current) {
    $items = Read-GoodHistory
    foreach ($item in $items) {
        if ($item -ne $Current) { return $item }
    }
    return $null
}

function Ensure-Task {
    $supervisor = "C:\LEDERG-MESSENGER-BOOT\supervisor.ps1"
    if (-not (Test-Path $supervisor)) { return $false }
    $cmd = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $supervisor + '"'
    & schtasks /Create /TN "LEDERG-AUTOPILOT" /SC ONSTART /RU SYSTEM /RL HIGHEST /F /TR $cmd 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Log "Could not create autopilot startup task."
        return $false
    }
    return $true
}

try {
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { throw "Git not found in PATH" }

    Ensure-Repo
    $py = Ensure-Venv

    Run-Git @("fetch","origin",$Branch,"--prune") | Out-Null

    $local = Head "HEAD"
    $remote = Head "origin/$Branch"
    $good = Best-Rollback $local

    if (-not (Test-Path $GoodFile) -and (Is-Healthy)) {
        Record-Good $local
        $good = Best-Rollback $local
        Log "Initial known-good revision recorded: $local"
    }

    if ($local -eq $remote) {
        if (-not (Is-Healthy)) {
            Log "Current revision is unhealthy. Restarting."
            Stop-Server
            Compile-Check $py
            Create-Server-Task
            Start-Server

            if (-not (Is-Healthy)) {
                $rollback = Best-Rollback $local
                if ($rollback) {
                    Log "Current revision still unhealthy. Rolling back to previous stable $rollback."
                    Stop-Server
                    Run-Git @("reset","--hard",$rollback) | Out-Null
                    Compile-Check $py
                    Install-Dependencies $py
                    DB-Check $py
                    Create-Server-Task
                    Start-Server
                    if (-not (Is-Healthy)) { throw "Previous stable revision is also unhealthy" }
                    Record-Good $rollback
                    Log "ROLLBACK SUCCESS: $rollback"
                } else {
                    throw "Server unhealthy and no previous stable revision is recorded"
                }
            }
        }
    } else {
        Log "NEW REVISION: $local -> $remote"

        Stop-Server
        $backup = Backup-Database

        try {
            Run-Git @("reset","--hard",$remote) | Out-Null
            Run-Git @("clean","-fd") | Out-Null
            $py = Ensure-Venv
            Compile-Check $py
            Install-Dependencies $py
            DB-Check $py
            Create-Server-Task
            Start-Server

            if (-not (Is-Healthy)) { throw "New revision failed health check" }

            Record-Good $remote
            Log "UPDATE SUCCESS: $remote is now known-good."
        } catch {
            Log "UPDATE FAILED: $($_.Exception.Message)"

            $rollback = if ($local -and $local -match "^[0-9a-f]{40}$") { $local } else { $good }
            if (-not $rollback) { $rollback = Best-Rollback $local }

            if (-not $rollback) {
                throw "No stable revision available for rollback"
            }

            Stop-Server
            Run-Git @("reset","--hard",$rollback) | Out-Null
            $py = Ensure-Venv
            Compile-Check $py
            Install-Dependencies $py
            if ($backup) { Restore-Database $backup }
            DB-Check $py
            Create-Server-Task
            Start-Server

            if (-not (Is-Healthy)) {
                throw "Rollback health check failed"
            }

            Record-Good $rollback
            Log "ROLLBACK SUCCESS: $rollback"
        }
    }

    Ensure-Task | Out-Null
    if (-not (Is-Healthy)) {
        Create-Server-Task
        Start-Server
        if (-not (Is-Healthy)) { throw "Server is not healthy after recovery" }
    }

    if ($Once) {
        exit 0
    }
} catch {
    Log "FATAL: $($_.Exception.Message)"
    exit 1
} finally {
    try { $mutex.ReleaseMutex() | Out-Null } catch {}
    $mutex.Dispose()
}
