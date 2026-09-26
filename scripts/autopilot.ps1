# LEDERG Messenger Autopilot
$ErrorActionPreference = "Stop"
$RepoUrl = "https://github.com/LEDERG777-TEXNARIC/LEDERG-GOLDEX.git"
$Branch = "main"
$AppDir = "C:\LEDERG-MESSENGER"
$DataDir = "C:\LEDERG-MESSENGER-DATA"
$BackupDir = Join-Path $DataDir "backups"
$LogDir = Join-Path $DataDir "logs"
$LogFile = Join-Path $LogDir "autopilot.log"
$GoodFile = Join-Path $DataDir "last-known-good.txt"
$Port = 8000
$TaskName = "LEDERG-MESSENGER"
$CheckSeconds = 60
$ServerTaskBat = Join-Path $DataDir "start-server.bat"

New-Item -ItemType Directory -Force -Path $DataDir,$BackupDir,$LogDir | Out-Null

function Log([string]$m) {
    $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $m
    Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8
    Write-Host $line
}

$mutex = New-Object System.Threading.Mutex($false, "Global\LEDERG-MESSENGER-AUTOPILOT")
if (-not $mutex.WaitOne(0)) { Log "Another autopilot instance is running."; exit 0 }

function G([string[]]$args) {
    $out = & git @args 2>&1
    if ($LASTEXITCODE -ne 0) { throw "git $($args -join ' ') failed: $out" }
    return $out
}
function Commit([string]$ref) { return (& git -C $AppDir rev-parse $ref).Trim() }
function EnsureRepo {
    if (-not (Test-Path (Join-Path $AppDir ".git"))) {
        if (Test-Path $AppDir) {
            $old = $AppDir + "_old_" + (Get-Date -Format yyyyMMdd_HHmmss)
            Move-Item $AppDir $old -Force
        }
        Log "Cloning $RepoUrl"
        & git clone --branch $Branch $RepoUrl $AppDir 2>&1 | ForEach-Object { Log $_ }
        if ($LASTEXITCODE -ne 0) { throw "Clone failed" }
    }
}
function EnsureVenv {
    $py=Join-Path $AppDir ".venv\Scripts\python.exe"
    if (-not (Test-Path $py)) {
        & py -3 -m venv (Join-Path $AppDir ".venv")
        if ($LASTEXITCODE -ne 0) { throw "Python venv creation failed" }
    }
}
function InstallDeps {
    $py=Join-Path $AppDir ".venv\Scripts\python.exe"
    & $py -m pip install -r (Join-Path $AppDir "requirements.txt") --disable-pip-version-check --no-input 2>&1 |
        ForEach-Object { Log $_ }
    if ($LASTEXITCODE -ne 0) { throw "Dependency installation failed" }
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
    if ($LASTEXITCODE -ne 0) { throw "Scheduled task creation failed" }
}
function StartServer { & schtasks /Run /TN $TaskName 2>&1 | Out-Null; Start-Sleep -Seconds 4 }
function StopServer { & schtasks /End /TN $TaskName 2>&1 | Out-Null; Start-Sleep -Seconds 2 }
function Healthy {
    try {
        $r=Invoke-RestMethod "http://127.0.0.1:$Port/health" -TimeoutSec 8
        return ($r.ok -eq $true -and $r.database -eq "ok")
    } catch { return $false }
}
function BackupDb {
    $db=Join-Path $DataDir "lederg.db"
    if (-not (Test-Path $db)) { return $null }
    $stamp=Get-Date -Format yyyyMMdd_HHmmss
    $dest=Join-Path $BackupDir "lederg_$stamp.db"
    Copy-Item $db $dest -Force
    foreach($s in @("-wal","-shm")) {
        $p="$db$s"
        if(Test-Path $p){ Copy-Item $p "$dest$s" -Force }
    }
    Get-ChildItem $BackupDir -Filter "lederg_*.db" |
      Sort-Object LastWriteTime -Descending |
      Select-Object -Skip 20 |
      Remove-Item -Force -ErrorAction SilentlyContinue
    Log "DB backup: $dest"
    return $dest
}
function RestoreDb([string]$backup) {
    if (-not $backup) { return }
    StopServer
    $db=Join-Path $DataDir "lederg.db"
    Copy-Item $backup $db -Force
    foreach($s in @("-wal","-shm")) {
        $p="$backup$s"
        $target="$db$s"
        if(Test-Path $p){ Copy-Item $p $target -Force } elseif(Test-Path $target){ Remove-Item $target -Force }
    }
    Log "DB restored from backup."
}
function Good([string]$commit) { Set-Content -LiteralPath $GoodFile -Value $commit -Encoding ASCII }
function ReadGood([string]$fallback) {
    if(Test-Path $GoodFile){
        $v=(Get-Content $GoodFile -Raw).Trim()
        if($v -match "^[0-9a-f]{40}$"){ return $v }
    }
    return $fallback
}
function DbCheck {
    $py=Join-Path $AppDir ".venv\Scripts\python.exe"
    $script=Join-Path $AppDir "scripts\db_maintenance.py"
    if(Test-Path $script) {
        & $py $script 2>&1 | ForEach-Object { Log $_ }
        if($LASTEXITCODE -ne 0){ throw "DB maintenance failed" }
    }
}
function UpdateCycle {
    Push-Location $AppDir
    $local=$null
    $backup=$null
    try {
        G @("fetch","origin",$Branch,"--prune") | Out-Null
        $local=Commit "HEAD"
        $remote=Commit "origin/$Branch"
        $good=ReadGood $local

        if($local -eq $remote){
            if(-not (Test-Path $GoodFile)){ Good $local }
            if(-not (Healthy)){
                Log "Current revision is unhealthy. Repairing."
                StopServer
                EnsureVenv
                InstallDeps
                DbCheck
                WriteServerTaskBat
                StartServer
                if(-not (Healthy)){ throw "Current revision remains unhealthy" }
            }
            return
        }

        Log "NEW REVISION: $local -> $remote ; known-good=$good"
        StopServer
        $backup=BackupDb
        G @("reset","--hard",$remote) | Out-Null
        G @("clean","-fd") | Out-Null
        EnsureVenv
        InstallDeps
        DbCheck
        WriteServerTaskBat
        StartServer

        if(Healthy){
            Good $remote
            Log "UPDATE SUCCESS: $remote is now known-good."
            return
        }
        throw "Health check failed after update"
    } catch {
        Log "UPDATE ERROR: $($_.Exception.Message)"
        try {
            StopServer
            $rollback=$local
            if(-not $rollback){ $rollback="HEAD~1" }
            if(Test-Path $GoodFile){
                $candidate=(Get-Content $GoodFile -Raw).Trim()
                if($candidate -match "^[0-9a-f]{40}$"){ $rollback=$candidate }
            }
            Log "ROLLBACK TO: $rollback"
            G @("reset","--hard",$rollback) | Out-Null
            EnsureVenv
            InstallDeps
            if($backup){ RestoreDb $backup }
            DbCheck
            WriteServerTaskBat
            StartServer
            if(Healthy){
                Good $rollback
                Log "ROLLBACK SUCCESS: $rollback"
            } else {
                throw "Rollback health check failed"
            }
        } catch {
            Log "CRITICAL: rollback also failed: $($_.Exception.Message)"
            StopServer
            throw
        }
    } finally {
        Pop-Location
    }
}

try {
    if(-not (Get-Command git -ErrorAction SilentlyContinue)){throw "Git not found in PATH"}
    if(-not (Get-Command py -ErrorAction SilentlyContinue)){throw "Python launcher not found"}
    EnsureRepo
    EnsureVenv
    InstallDeps
    DbCheck
    WriteServerTaskBat
    StartServer

    if(Healthy){
        $head=Commit "HEAD"
        if(-not (Test-Path $GoodFile)){ Good $head }
        Log "SERVER ONLINE: http://127.0.0.1:$Port ; revision=$head"
    } else {
        Log "Initial health check failed."
    }

    while($true){
        try { UpdateCycle } catch { Log "Cycle failed: $($_.Exception.Message)" }
        Start-Sleep -Seconds $CheckSeconds
    }
} catch {
    Log "FATAL: $($_.Exception.Message)"
    exit 1
} finally {
    try { $mutex.ReleaseMutex() | Out-Null } catch {}
    $mutex.Dispose()
}
