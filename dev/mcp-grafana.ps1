# Launches the read-only Grafana MCP server (uvx mcp-grafana) for dev agents
# (OpenCode/Claude). Tools: query_loki_logs, query_prometheus, dashboards,
# alerting, Explore deeplinks, ... see arda-infra/docs/monitoring.md.
#
# Credentials come from dev/mcp-grafana.env (gitignored), falling back to the
# User environment. Nothing is written to stdout except the MCP protocol.
$ErrorActionPreference = 'Stop'

$envFile = Join-Path $PSScriptRoot 'mcp-grafana.env'
if (Test-Path -LiteralPath $envFile) {
  foreach ($line in Get-Content -LiteralPath $envFile) {
    if ($line -match '^\s*(#|$)') { continue }
    $key, $value = $line -split '=', 2
    if (-not $key -or -not $value) { continue }
    [Environment]::SetEnvironmentVariable($key.Trim(), $value.Trim().Trim('"'), 'Process')
  }
}

if (-not $env:GRAFANA_URL) { $env:GRAFANA_URL = 'https://grafana.arda.io.vn' }
if (-not $env:GRAFANA_SERVICE_ACCOUNT_TOKEN) {
  $env:GRAFANA_SERVICE_ACCOUNT_TOKEN = [Environment]::GetEnvironmentVariable('GRAFANA_SERVICE_ACCOUNT_TOKEN', 'User')
}
if (-not $env:GRAFANA_SERVICE_ACCOUNT_TOKEN) {
  [Console]::Error.WriteLine('mcp-grafana: missing GRAFANA_SERVICE_ACCOUNT_TOKEN (set it in dev/mcp-grafana.env or User env).')
  exit 1
}
if (-not $env:GRAFANA_EXTRA_HEADERS) {
  Remove-Item Env:\GRAFANA_EXTRA_HEADERS -ErrorAction SilentlyContinue
}

$uvx = (Get-Command uvx -ErrorAction SilentlyContinue).Source
if (-not $uvx) { $uvx = Join-Path $env:USERPROFILE '.local\bin\uvx.exe' }
if (-not (Test-Path -LiteralPath $uvx)) {
  [Console]::Error.WriteLine('mcp-grafana: uvx not found on PATH.')
  exit 1
}

& $uvx mcp-grafana --disable-write --disable-oncall --disable-incident
exit $LASTEXITCODE
