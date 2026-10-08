param(
  [Parameter(Mandatory = $true)]
  [string]$Namespace,

  [Parameter(Mandatory = $true)]
  [string]$Name,

  [Parameter(Mandatory = $true)]
  [string]$OutputPath,

  [switch]$Force
)

$ErrorActionPreference = "Stop"

if (-not $env:SOPS_AGE_KEY_FILE -or -not (Test-Path -LiteralPath $env:SOPS_AGE_KEY_FILE)) {
  throw "Set SOPS_AGE_KEY_FILE to the protected age identity before encrypting."
}
if ((Test-Path -LiteralPath $OutputPath) -and -not $Force) {
  throw "Refusing to overwrite existing output: $OutputPath"
}

$sops = Get-Command sops -ErrorAction Stop
$rawSecret = & kubectl -n $Namespace get secret $Name -o json
if ($LASTEXITCODE -ne 0) {
  throw "Could not read Secret $Namespace/$Name."
}
$source = ($rawSecret -join "`n") | ConvertFrom-Json
if ($source.kind -ne "Secret" -or -not $source.data) {
  throw "The requested resource is not a populated Kubernetes Secret."
}

# Keep only stable identity fields and data. The raw API object stays in memory;
# SOPS reads the sanitized JSON through stdin and writes only ciphertext.
$cleanData = [ordered]@{}
foreach ($property in $source.data.PSObject.Properties) {
  $cleanData[$property.Name] = $property.Value
}
$cleanSecret = [ordered]@{
  apiVersion = "v1"
  kind       = "Secret"
  metadata   = [ordered]@{ name = $Name; namespace = $Namespace }
  type       = $source.type
  data       = $cleanData
}
$plaintext = $cleanSecret | ConvertTo-Json -Depth 12 -Compress

$start = [Diagnostics.ProcessStartInfo]::new()
$start.FileName = $sops.Source
$start.Arguments = "encrypt --filename-override `"$OutputPath`" --input-type json --output-type yaml"
$start.UseShellExecute = $false
$start.CreateNoWindow = $true
$start.RedirectStandardInput = $true
$start.RedirectStandardOutput = $true
$start.RedirectStandardError = $true
$process = [Diagnostics.Process]::new()
$process.StartInfo = $start
try {
  if (-not $process.Start()) { throw "Could not start SOPS." }
  $process.StandardInput.WriteLine($plaintext)
  $process.StandardInput.Close()
  $ciphertext = $process.StandardOutput.ReadToEnd()
  $errorText = $process.StandardError.ReadToEnd()
  $process.WaitForExit()
  if ($process.ExitCode -ne 0) {
    throw "SOPS encryption failed: $errorText"
  }
  if ($ciphertext -notmatch 'ENC\[AES256_GCM,' -or $ciphertext -notmatch 'sops:') {
    throw "SOPS output did not contain an encrypted SOPS document."
  }
  $fullPath = [IO.Path]::GetFullPath($OutputPath)
  $parent = [IO.Path]::GetDirectoryName($fullPath)
  if (-not (Test-Path -LiteralPath $parent)) {
    throw "Output directory does not exist: $parent"
  }
  [IO.File]::WriteAllText($fullPath, $ciphertext, [Text.UTF8Encoding]::new($false))
  Write-Output "Encrypted Secret $Namespace/$Name to $OutputPath without writing plaintext to disk."
} finally {
  $process.Dispose()
  $plaintext = $null
  $cleanData = $null
  $cleanSecret = $null
  $source = $null
  $rawSecret = $null
}
