# LEDERG Messenger Self-Healing Autopilot
$ErrorActionPreference = "Stop"

$RepoUrl = "https://github.com/LEDERG777-TEXNARIC/LEDERG-GOLDEX.git"
$Branch = "main"
$AppDir = "C:\LEDERG-MESSENGER"
$DataDir = "C:\LEDERG-MESSENGER-DATA"
$BootDir = "C:\LEDERG-MESSENGER-BOOT"
$BackupDir = Join-Path $DataDir "backups"
$LogDir = Join-Path $DataDir "logs"
$LogFile = Join-Path $LogDir "autopilot.log"
$GoodFile = Join-Path $DataDir "last-known-good.txt"
$BootRunner = Join-Path $BootDir "autopilot.ps1"
$Port = 8000
$TaskName = "LEDERG-MESSENGER"
$CheckSeconds = 60
$ServerTaskBat = Join-Path $DataDir "start-server.bat"

New-Item -ItemType Directory -Force -Path $DataDir,$BackupDir,$LogDir,$BootDir | Out-Null

function Log([string]$Message) {
    $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
    Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8
    Write-Host $line
}

# Only one supervisor may run. The messenger server is a separate scheduled task.
$mutex = New-Object System.Threading.Mutex($false, "Global\LEDERG-MESSENGER-AUTOPILOT")
if (-not $mutex.WaitOne(0)) {
    Log "Another autopilot instance is already running."
    exit 0
}

function Git([string[]]$Args) {
    $out = & git @Args 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "git $($Args -join ' ') failed: $out"
    }
    return $out
}

function Head([string]$Ref) {
    return (& git -C $AppDir rev-parse $Ref).Trim()
}

function EnsureRepo {
    if (Test-Path (Join-Path $AppDir ".git")) {
        & git -C $AppDir remote set-url origin $RepoUrl 2>$null | Out-Null
        return
    }

    if (Test-Path $AppDir) {
        $old = $AppDir + "_old_" + (Get-Date -Format "yyyyMMdd_HHmmss")
        Move-Item $AppDir $old -Force
    }

    Log "Cloning $RepoUrl"
    & git clone --branch $Branch $RepoUrl $AppDir 2>&1 | ForEach-Object { Log $_ }
    if ($LASTEXITCODE -ne 0) {
        throw "Git clone failed"
    }
}

function EnsureVenv {
    $py = Join-Path $AppDir ".venv\Scripts\python.exe"
    if (-not (Test-Path $py)) {
        Log "Creating Python virtual environment."
        & py -3 -m venv (Join-Path $AppDir ".venv") 2>&1 | ForEach-Object { Log $_ }
        if ($LASTEXITCODE -ne 0) {
            throw "Python virtual environment creation failed"
        }
    }
}

function InstallDeps {
    $py = Join-Path $AppDir ".venv\Scripts\python.exe"
    & $py -m pip install -r (Join-Path $AppDir "requirements.txt") --disable-pip-version-check --no-input 2>&1 |
        ForEach-Object { Log $_ }
    if ($LASTEXITCODE -ne 0) {
        throw "Dependency installation failed"
    }
}

function CompileCheck {
    $py = Join-Path $AppDir ".venv\Scripts\python.exe"
    & $py -m compileall -q (Join-Path $AppDir "server") (Join-Path $AppDir "run.py")
    if ($LASTEXITCODE -ne 0) {
        throw "Python compile check failed"
    }
}

function DBCheck {
    $py = Join-Path $AppDir ".venv\Scripts\python.exe"
    $script = Join-Path $AppDir "scripts\db_maintenance.py"
    if (Test-Path $script) {
        & $py $script 2>&1 | ForEach-Object { Log $_ }
        if ($LASTEXITCODE -ne 0) {
            throw "Database maintenance failed"
        }
    }
}

function WriteServerTaskBat {
    @"
@echo off
cd /d "$AppDir"
set "LEDERG_HOST=0.0.0.0"
set "LEDERG_PORT=$Port"
"$AppDir\.venv\Scripts\python.exe" "$AppDir\run.py" >> "$DataDir\logs\server.log" 2>&1
"@ | Set-Content -LiteralPath $ServerTaskBat -Encoding ASCII

    & schtasks /Create /TN $TaskName /SC ONSTART /RU SYSTEM /RL HIGHEST /F /TR ('"' + $ServerTaskBat + '"') 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Messenger scheduled task creation failed"
    }
}

function StopServer {
    & schtasks /End /TN $TaskName 2>&1 | Out-Null
    Start-Sleep -Seconds 2

    # Task Scheduler can leave a child python process alive. Kill only this app's run.py.
    try {
        Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -like "*$AppDir\run.py*" } |
            ForEach-Object {
                Invoke-CimMethod -InputObject $_ -MethodName Terminate -ErrorAction SilentlyContinue | Out-Null
            }
    } catch {}
    Start-Sleep -Seconds 1
}

function StartServer {
    & schtasks /Run /TN $TaskName 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Messenger scheduled task start failed"
    }
    Start-Sleep -Seconds 4
}

function Healthy {
    try {
        $r = Invoke-RestMethod "http://127.0.0.1:$Port/health" -TimeoutSec 8
        return ($r.ok -eq $true -and $r.database -eq "ok")
    } catch {
        return $false
    }
}

function BackupDb {
    $db = Join-Path $DataDir "lederg.db"
    if (-not (Test-Path $db)) {
        return $null
    }

    # The server is stopped before this function, so copying DB + WAL sidecars is safe.
    $stamp = Get-Date -Format yyyyMMdd_HHmmss
    $dest = Join-Path $BackupDir "lederg_$stamp.db"
    Copy-Item $db $dest -Force

    foreach ($suffix in @("-wal", "-shm")) {
        $src = "$db$suffix"
        if (Test-Path $src) {
            Copy-Item $src "$dest$suffix" -Force
        }
    }

    Get-ChildItem $BackupDir -Filter "lederg_*.db" |
        Sort-Object LastWriteTime -Descending |
        Select-Object -Skip 20 |
        Remove-Item -Force -ErrorAction SilentlyContinue

    Log "DB backup created: $dest"
    return $dest
}

function RestoreDb([string]$Backup) {
    if (-not $Backup) {
        return
    }

    $db = Join-Path $DataDir "lederg.db"
    Copy-Item $Backup $db -Force

    foreach ($suffix in @("-wal", "-shm")) {
        $src = "$Backup$suffix"
        $dst = "$db$suffix"
        if (Test-Path $src) {
            Copy-Item $src $dst -Force
        } elseif (Test-Path $dst) {
            Remove-Item $dst -Force -ErrorAction SilentlyContinue
        }
    }

    Log "DB restored from backup."
}

function SaveKnownGood([string]$Commit) {
    Set-Content -LiteralPath $GoodFile -Value $Commit -Encoding ASCII
}

function ReadKnownGood([string]$Fallback) {
    if (Test-Path $GoodFile) {
        $value = (Get-Content $GoodFile -Raw).Trim()
        if ($value -match "^[0-9a-f]{40}$") {
            return $value
        }
    }
    return $Fallback
}

function RefreshAutopilot {
    # Keep the supervisor itself current. If GitHub is unavailable, keep using the cached runner.
    $rawUrl = "https://raw.githubusercontent.com/LEDERG777-TEXNARIC/LEDERG-GOLDEX/main/scripts/autopilot.ps1"
    $tmp = Join-Path $BootDir "autopilot.ps1.new"
    try {
        $content = (Invoke-WebRequest -UseBasicParsing -Uri $rawUrl -TimeoutSec 15).Content
        if (-not [string]::IsNullOrWhiteSpace($content)) {
            [IO.File]::WriteAllText($tmp, $content, [Text.Encoding]::UTF8)
            Move-Item $tmp $BootRunner -Force
        }
    } catch {
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    }
}

function UpdateCycle {
    Push-Location $AppDir
    try {
        Git @("fetch", "origin", $Branch, "--prune") | Out-Null

        $local = Head "HEAD"
        $remote = Head "origin/$Branch"
        $good = ReadKnownGood $local

        if ($local -eq $remote) {
            if (-not (Test-Path $GoodFile)) {
                SaveKnownGood $local
            }

            if (Healthy) {
                return
            }

            Log "Server unhealthy on current revision $local. Restarting."
            StopServer
            WriteServerTaskBat
            StartServer

            if (Healthy) {
                Log "Current revision recovered without rollback."
                return
            }

            if ($good -and $good -ne $local) {
                Log "Current revision is still unhealthy. Rolling back to known-good $good."
                StopServer
                Git @("reset", "--hard", $good) | Out-Null
                CompileCheck
                InstallDeps
                DBCheck
                WriteServerTaskBat
                StartServer
                if (-not (Healthy)) {
                    throw "Known-good rollback health check failed"
                }
                Log "ROLLBACK SUCCESS: $good"
                return
            }

            throw "Current revision health check failed and no older known-good revision exists"
        }

        Log "NEW REVISION: $local -> $remote ; known-good=$good"
        StopServer
        $backup = BackupDb

        Git @("reset", "--hard", $remote) | Out-Null
        Git @("clean", "-fd") | Out-Null
        EnsureVenv
        CompileCheck
        InstallDeps
        DBCheck
        WriteServerTaskBat
        StartServer

        if (Healthy) {
            SaveKnownGood $remote
            Log "UPDATE SUCCESS: $remote"
            return
        }

        throw "Health check failed after update"
    } catch {
        Log "UPDATE ERROR: $($_.Exception.Message)"

        try {
            StopServer

            $rollback = ReadKnownGood $local
            if (-not $rollback) {
                $rollback = $local
            }
            if (-not $rollback) {
                $rollback = Head "HEAD~1"
            }

            Log "ROLLBACK TO: $rollback"
            Git @("reset", "--hard", $rollback) | Out-Null
            EnsureVenv
            CompileCheck
            InstallDeps

            # Only restore a DB when this cycle created a backup.
            if ($backup) {
                RestoreDb $backup
            }

            DBCheck
            WriteServerTaskBat
            StartServer

            if (-not (Healthy)) {
                throw "Rollback health check failed"
            }

            SaveKnownGood $rollback
            Log "ROLLBACK SUCCESS: $rollback"
        } catch {
            Log "CRITICAL: rollback failed too: $($_.Exception.Message)"
            try { StopServer } catch {}
            throw
        }
    } finally {
        Pop-Location
    }
}

try {
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        throw "Git not found in PATH"
    }
    if (-not (Get-Command py -ErrorAction SilentlyContinue)) {
        throw "Python launcher not found"
    }

    # The permanent BAT downloads this runner on every launch. This also refreshes
    # the cached runner during a live session so the BAT itself never needs editing.
    RefreshAutopilot

    EnsureRepo
    EnsureVenv
    CompileCheck
    InstallDeps
    DBCheck
    WriteServerTaskBat

    if (-not (Healthy)) {
        try { StopServer } catch {}
        StartServer
    }

    if (Healthy) {
        $head = Head "HEAD"
        if (-not (Test-Path $GoodFile)) {
            SaveKnownGood $head
        }
        Log "SERVER ONLINE: http://127.0.0.1:$Port ; revision=$head"
    } else {
        Log "Initial server health check failed; supervisor will retry."
    }

    while ($true) {
        try {
            RefreshAutopilot
            UpdateCycle
        } catch {
            Log "SUPERVISOR CYCLE FAILED: $($_.Exception.Message)"
        }

        Start-Sleep -Seconds $CheckSeconds
    }
} catch {
    Log "FATAL: $($_.Exception.Message)"
    exit 1
} finally {
    try { $mutex.ReleaseMutex() | Out-Null } catch {}
    $mutex.Dispose()
}
