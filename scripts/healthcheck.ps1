param([string]$Url="http://127.0.0.1:8000/health")
try {
  $r = Invoke-RestMethod -Uri $Url -TimeoutSec 5
  if ($r.ok -ne $true) { exit 2 }
  exit 0
} catch { exit 1 }
