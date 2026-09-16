# Reinstall: full remove (image/volumes), then fresh install.
$ErrorActionPreference = 'Stop'
& (Join-Path $PSScriptRoot 'remove-local-docker.ps1') @args
& (Join-Path $PSScriptRoot 'install-local-docker.ps1') @args
