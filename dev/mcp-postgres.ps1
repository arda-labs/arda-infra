# Launches the Postgres MCP server for dev agents.
#
# Default (read-only): one process serves every service database; tools take a
# `database` argument (execute_sql, list_schemas, list_objects,
# get_object_details, explain_query). Role: `arda_agent_ro`.
#
# -Write (postgres-admin entry): adds `execute_write` for cleaning up junk dev
# data. Role: `arda_agent_rw` (DML grants only, no DDL), dry-run by default,
# WHERE required on UPDATE/DELETE, row cap, auth DBs and goose_db_version
# blocked. Keep this entry for data cleanup only, never for schema changes.
#
# Credentials come from dev/mcp-postgres.env (gitignored), falling back to the
# User environment. Nothing is written to stdout except the MCP protocol.
#
# The server script carries PEP 723 metadata, so `uv run` resolves its
# dependencies (mcp<2, psycopg) on its own. `--python 3.12` keeps parity with
# the tested setup; the upstream postgres-mcp fallback additionally needs it
# (pglast has no 3.14 wheel), and mcp 2.x renamed mcp.server.fastmcp, which
# this server imports from the 1.x path.
param(
  [switch]$Write
)
$ErrorActionPreference = 'Stop'

$envFile = Join-Path $PSScriptRoot 'mcp-postgres.env'
if (Test-Path -LiteralPath $envFile) {
  foreach ($line in Get-Content -LiteralPath $envFile) {
    if ($line -match '^\s*(#|$)') { continue }
    $key, $value = $line -split '=', 2
    if (-not $key -or -not $value) { continue }
    [Environment]::SetEnvironmentVariable($key.Trim(), $value.Trim().Trim('"'), 'Process')
  }
}

if (-not $env:POSTGRES_HOST) { $env:POSTGRES_HOST = '192.168.10.210' }
if (-not $env:POSTGRES_PORT) { $env:POSTGRES_PORT = '5432' }
if (-not $env:ARDA_AGENT_RO_USER) { $env:ARDA_AGENT_RO_USER = 'arda_agent_ro' }
if (-not $env:ARDA_AGENT_RW_USER) { $env:ARDA_AGENT_RW_USER = 'arda_agent_rw' }
if (-not $env:ARDA_AGENT_RO_PASSWORD) {
  $env:ARDA_AGENT_RO_PASSWORD = [Environment]::GetEnvironmentVariable('ARDA_AGENT_RO_PASSWORD', 'User')
}
if (-not $env:ARDA_AGENT_RO_PASSWORD) {
  [Console]::Error.WriteLine('mcp-postgres: missing ARDA_AGENT_RO_PASSWORD (set it in dev/mcp-postgres.env or User env).')
  exit 1
}
if ($Write) {
  $env:MCP_POSTGRES_MODE = 'rw'
  if (-not $env:ARDA_AGENT_RW_PASSWORD) {
    $env:ARDA_AGENT_RW_PASSWORD = [Environment]::GetEnvironmentVariable('ARDA_AGENT_RW_PASSWORD', 'User')
  }
  if (-not $env:ARDA_AGENT_RW_PASSWORD) {
    [Console]::Error.WriteLine('mcp-postgres: missing ARDA_AGENT_RW_PASSWORD for -Write (set it in dev/mcp-postgres.env or User env).')
    exit 1
  }
} else {
  $env:MCP_POSTGRES_MODE = 'ro'
}

$server = Join-Path $PSScriptRoot 'mcp-postgres.py'
if (-not (Test-Path -LiteralPath $server)) {
  [Console]::Error.WriteLine("mcp-postgres: server script not found at $server.")
  exit 1
}

$uv = (Get-Command uv -ErrorAction SilentlyContinue).Source
if (-not $uv) { $uv = Join-Path $env:USERPROFILE '.local\bin\uv.exe' }
if (-not (Test-Path -LiteralPath $uv)) {
  [Console]::Error.WriteLine('mcp-postgres: uv not found on PATH.')
  exit 1
}

# VIP 192.168.10.210 (MetalLB, database/loadbalancer) routes to the primary and
# admits only the workstation /32; write access is limited by the role
# grants (DML only, not an owner) and by the server's execute_write guardrails.
& $uv run --python 3.12 --no-project --quiet $server
exit $LASTEXITCODE
