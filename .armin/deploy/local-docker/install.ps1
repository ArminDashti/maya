# Compatibility shim - implementation lives in install-on-local-docker.ps1.
param(
    [string]$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
)
$ErrorActionPreference = 'Stop'
& (Join-Path $PSScriptRoot 'install-on-local-docker.ps1') @PSBoundParameters
