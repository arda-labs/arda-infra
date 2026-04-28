param(
  [int]$LocalPort = 9180,
  [string]$Namespace = "gateway",
  [string]$Service = "svc/apisix-admin"
)

$ErrorActionPreference = "Stop"

function Get-ApisixAdminKey {
  $config = (kubectl -n $Namespace get configmap apisix -o jsonpath="{.data.config\.yaml}") -join "`n"
  $match = [regex]::Match(
    $config,
    '(?m)name:[ \t]*"?admin"?[ \t]*\r?\n[ \t]*key:[ \t]*"?([^"\s]+)"?[ \t]*\r?\n[ \t]*role:[ \t]*admin'
  )

  if ($match.Success) {
    return $match.Groups[1].Value
  }

  return $null
}

$adminKey = Get-ApisixAdminKey

Write-Host "APISIX Dashboard: http://127.0.0.1:$LocalPort/ui/"
if ($adminKey) {
  Write-Host "Admin API key: $adminKey"
} else {
  Write-Host "Admin API key: inspect ConfigMap gateway/apisix if the UI asks for it."
}
Write-Host "Press Ctrl+C to stop the tunnel."

kubectl -n $Namespace port-forward $Service "$LocalPort`:9180"
