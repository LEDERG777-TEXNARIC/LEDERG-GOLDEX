# LEDERG permanent background supervisor
$ErrorActionPreference = "Stop"

$BootDir = "C:\LEDERG-MESSENGER-BOOT"
$DataDir = "C:\LEDERG-MESSENGER-DATA"
$Runner = Join-Path $BootDir "autopilot.ps1"
$Tmp = Join-Path $BootDir "autopilot.new.ps1"
$LogDir = Join-Path $DataDir "logs"
$Log = Join-Path $LogDir "supervisor.log"
$Raw = "https://raw.githubusercontent.com/LEDERG777-TEXNARIC/LEDERG-GOLDEX/main/scripts/autopilot.ps1"
$MutexName = "Global\LEDERG-MESSENGER-SUPERVISOR"

New-Item -ItemType Directory -Force -Path $BootDir,$DataDir,$LogDir | Out-Null

function Write-Log([string]$Message) {
    $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
    Add-Content -LiteralPath $Log -Value $line -Encoding UTF8
}

$mutex = New-Object System.Threading.Mutex($false,$MutexName)
if (-not $mutex.WaitOne(0)) { exit 0 }

try {
    while ($true) {
        try {
            $content = (Invoke-WebRequest -UseBasicParsing -Uri $Raw -TimeoutSec 20).Content
            if ([string]::IsNullOrWhiteSpace($content)) { throw "empty autopilot" }

            $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
            [IO.File]::WriteAllText($Tmp,$content,$utf8NoBom)
            Move-Item $Tmp $Runner -Force
            Write-Log "Autopilot code refreshed from GitHub."

            & powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File $Runner -Once
            if ($LASTEXITCODE -ne 0) {
                Write-Log "Autopilot cycle returned exit code $LASTEXITCODE."
            }
        } catch {
            Remove-Item $Tmp -Force -ErrorAction SilentlyContinue
            Write-Log "Supervisor cycle failed: $($_.Exception.Message)"
        }

        Start-Sleep -Seconds 60
    }
} finally {
    try { $mutex.ReleaseMutex() | Out-Null } catch {}
    $mutex.Dispose()
}
