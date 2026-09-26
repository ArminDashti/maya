# Compatibility shim - implementation lives in remove-from-local-docker.ps1.
param(
    [string]$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path,
    [switch]$Force
)
$ErrorActionPreference = 'Stop'
& (Join-Path $PSScriptRoot 'remove-from-local-docker.ps1') @PSBoundParameters
