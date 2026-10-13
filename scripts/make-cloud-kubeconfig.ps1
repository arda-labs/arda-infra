# Builds a kubeconfig for the read-only cloud-agent ServiceAccount
# (k8s/rbac/cloud-agent-readonly.yaml). The token goes into the output file and
# is never printed. Keep the file out of git and load it into the cloud
# environment's secret store, e.g. as KUBECONFIG_B64.
#
#   .\scripts\make-cloud-kubeconfig.ps1 -Out $HOME\arda-cloud.kubeconfig
param(
    [Parameter(Mandatory = $true)][string]$Out,
    [string]$Server = "https://192.168.10.201:6443"
)
$ErrorActionPreference = "Stop"
$ns = "arda-app"
$secret = "cloud-agent-readonly-token"

$token = kubectl -n $ns get secret $secret -o "jsonpath={.data.token}"
$ca = kubectl -n $ns get secret $secret -o "jsonpath={.data.ca\.crt}"
if (-not $token -or -not $ca) { throw "Secret $ns/$secret has no token yet - is it synced?" }

$tokenPlain = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($token))
$caFile = New-TemporaryFile
try {
    [IO.File]::WriteAllBytes($caFile.FullName, [Convert]::FromBase64String($ca))
    if (Test-Path $Out) { Remove-Item $Out }
    kubectl config --kubeconfig=$Out set-cluster arda --server=$Server --certificate-authority=$($caFile.FullName) --embed-certs=true | Out-Null
    kubectl config --kubeconfig=$Out set-credentials cloud-agent-readonly --token=$tokenPlain | Out-Null
    kubectl config --kubeconfig=$Out set-context arda-readonly --cluster=arda --user=cloud-agent-readonly --namespace=arda-app | Out-Null
    kubectl config --kubeconfig=$Out use-context arda-readonly | Out-Null
} finally {
    Remove-Item $caFile.FullName -Force
}
Write-Host "Wrote $Out (context arda-readonly). Do not commit it."
