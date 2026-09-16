# Legacy wrapper — use sync-maya.ps1
$ErrorActionPreference = 'Stop'
Write-Warning 'sync-user-65778-reports.ps1 is deprecated; running sync-maya.ps1'
& (Join-Path $PSScriptRoot 'sync-maya.ps1') @args
