# Install or update local Maya Open WebUI stack.
# Update keeps volumes/DB/files (no docker compose down -v).
# Implementation: .armin/deploy/local-docker/install-on-local-docker.ps1
$ErrorActionPreference = 'Stop'
& (Join-Path $PSScriptRoot '..\.armin\deploy\local-docker\install-on-local-docker.ps1') @args
