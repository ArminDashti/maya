# Remove local Maya Open WebUI completely (container, image, volumes/DB).
$ErrorActionPreference = 'Stop'
& (Join-Path $PSScriptRoot '..\.armin\deploy\local-docker\remove.ps1') @args
