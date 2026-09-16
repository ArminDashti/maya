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

function Remove-DockerVolumeIfExists([string]$name) {
    if (-not $name) { return }
    $hit = docker volume ls --format '{{.Name}}' | Where-Object { $_ -eq $name }
    if ($hit) {
        docker volume rm $name 2>$null | Out-Host
    }
}

function Remove-DockerContainerIfExists([string]$name) {
    if (-not $name) { return }
    $hit = docker ps -a --filter "name=^/${name}$" --format '{{.Names}}' |
        Where-Object { $_ -eq $name }
    if ($hit) {
        docker rm -f $name | Out-Host
    }
}

$yaml = Get-Content -Path $yamlPath -Raw
$stack = Get-YamlValue $yaml 'stack_name'
$composeRel = Get-YamlValue $yaml 'compose_file'
$imageTag = Get-YamlValue $yaml 'image_tag'
$deleteVolume = Get-YamlValue $yaml 'delete_volume'
$deleteImage = Get-YamlValue $yaml 'delete_image'
$containerName = Get-YamlValue $yaml 'container_name'
$legacyStack = Get-YamlValue $yaml 'legacy_stack_name'
$legacyContainer = Get-YamlValue $yaml 'legacy_container_name'
$legacyVolume = Get-YamlValue $yaml 'legacy_volume_name'
$volumeName = Get-YamlValue $yaml 'volume_name'

$composeFile = Join-Path $ProjectRoot 'docker-compose.yml'
if (-not (Test-Path $composeFile) -and $composeRel) {
    $composeFile = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ($composeRel -replace '/', [IO.Path]::DirectorySeparatorChar)))
}
if (-not (Test-Path $composeFile)) { throw "Compose file not found: $composeFile" }

Push-Location $ProjectRoot
try {
    if ($deleteVolume -eq 'yes') {
        docker compose -p $stack -f $composeFile down -v --remove-orphans
        if ($legacyStack -and $legacyStack -ne $stack) {
            docker compose -p $legacyStack -f $composeFile down -v --remove-orphans 2>$null | Out-Host
        }
    } else {
        docker compose -p $stack -f $composeFile down --remove-orphans
        if ($legacyStack -and $legacyStack -ne $stack) {
            docker compose -p $legacyStack -f $composeFile down --remove-orphans 2>$null | Out-Host
        }
    }
} finally {
    Pop-Location
}

Remove-DockerContainerIfExists $containerName
Remove-DockerContainerIfExists $legacyContainer

if ($deleteVolume -eq 'yes') {
    Remove-DockerVolumeIfExists $volumeName
    Remove-DockerVolumeIfExists $legacyVolume
    # Project-prefixed leftovers from older compose layouts
    Remove-DockerVolumeIfExists 'maya_maya-openwebui-data'
    Remove-DockerVolumeIfExists 'maya_maya-open-webui-data'
    Remove-DockerVolumeIfExists 'maya-local_maya-open-webui-data'
}

if ($deleteImage -eq 'yes' -and $imageTag) {
    docker rmi $imageTag 2>$null | Out-Host
}

Write-Host "Removed stack $stack (container/image/volumes wiped)"
