param(
    [string]$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
)

$ErrorActionPreference = 'Stop'
$yamlPath = Join-Path $PSScriptRoot 'remove.yaml'
if (-not (Test-Path $yamlPath)) { throw "Missing $yamlPath" }

function Get-YamlValue([string]$text, [string]$key) {
    if ($text -match "(?m)^${key}:\s*[`"']?([^`"'\r\n]+)") { return $Matches[1].Trim() }
    return $null
}

$yaml = Get-Content -Path $yamlPath -Raw
$stack = Get-YamlValue $yaml 'stack_name'
$composeRel = Get-YamlValue $yaml 'compose_file'
$imageTag = Get-YamlValue $yaml 'image_tag'
$deleteVolume = Get-YamlValue $yaml 'delete_volume'
$deleteImage = Get-YamlValue $yaml 'delete_image'

$composeFile = Join-Path $ProjectRoot 'docker-compose.yml'
if (-not (Test-Path $composeFile) -and $composeRel) {
    $composeFile = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ($composeRel -replace '/', [IO.Path]::DirectorySeparatorChar)))
}
if (-not (Test-Path $composeFile)) { throw "Compose file not found: $composeFile" }

Push-Location $ProjectRoot
try {
    if ($deleteVolume -eq 'yes') {
        docker compose -p $stack -f $composeFile down -v
    } else {
        docker compose -p $stack -f $composeFile down
    }
} finally {
    Pop-Location
}

if ($deleteImage -eq 'yes' -and $imageTag) {
    docker rmi $imageTag 2>$null | Out-Host
}

Write-Host "Removed stack $stack"
