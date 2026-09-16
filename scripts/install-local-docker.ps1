# Install or update local Maya Open WebUI stack.
# Update keeps volumes/DB/files (no docker compose down -v).
$ErrorActionPreference = 'Stop'
& (Join-Path $PSScriptRoot '..\.armin\deploy\local-docker\install.ps1') @args
