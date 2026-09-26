# Remove local Maya Open WebUI completely (containers, image, volumes/DB, hosts entry).
# Asks for confirmation unless -Force.
# Implementation: .armin/deploy/local-docker/remove-from-local-docker.ps1
$ErrorActionPreference = 'Stop'
& (Join-Path $PSScriptRoot '..\.armin\deploy\local-docker\remove-from-local-docker.ps1') @args
