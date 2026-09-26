$ErrorActionPreference = "Stop"
$Owner = "LEDERG777-TEXNARIC"
$Repo = "LEDERG-MESSENGER"
$Root = Split-Path -Parent $PSScriptRoot

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
  Write-Host "[ERROR] GitHub CLI (gh) is required."
  Write-Host "Install it, run 'gh auth login', then run this script again."
  exit 1
}
gh auth status
if ($LASTEXITCODE -ne 0) { exit 1 }

gh repo view "$Owner/$Repo" *> $null
if ($LASTEXITCODE -eq 0) {
  Write-Host "[ERROR] $Owner/$Repo already exists. Refusing to overwrite."
  exit 2
}

gh repo create "$Owner/$Repo" --private --description "LEDERG self-hosted messenger" --source "$Root" --remote origin --push
Write-Host "[SUCCESS] Created https://github.com/$Owner/$Repo"
