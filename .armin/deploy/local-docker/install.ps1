param(
    [string]$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
)

$ErrorActionPreference = 'Stop'
$yamlPath = Join-Path $PSScriptRoot 'install.yaml'
if (-not (Test-Path $yamlPath)) { throw "Missing $yamlPath" }

function Get-YamlValue([string]$text, [string]$key) {
    if ($text -match "(?m)^${key}:\s*[`"']?([^`"'\r\n]+)") { return $Matches[1].Trim() }
    return $null
}

function Test-DockerName([string]$name) {
    if (-not $name) { return $false }
    $hit = docker ps -a --filter "name=^/${name}$" --format '{{.Names}}' |
        Where-Object { $_ -eq $name }
    return [bool]$hit
}

function Test-DockerVolume([string]$name) {
    if (-not $name) { return $false }
    $hit = docker volume ls --format '{{.Name}}' | Where-Object { $_ -eq $name }
    return [bool]$hit
}

function Copy-DockerVolume([string]$from, [string]$to) {
    docker volume create $to | Out-Null
    docker run --rm -v "${from}:/from" -v "${to}:/to" alpine:3.20 `
        sh -c 'cd /from && cp -a . /to/' | Out-Host
}

$yaml = Get-Content -Path $yamlPath -Raw
$stack = Get-YamlValue $yaml 'stack_name'
$composeRel = Get-YamlValue $yaml 'compose_file'
$publishPort = Get-YamlValue $yaml 'publish_port'
$containerName = Get-YamlValue $yaml 'container_name'
$legacyStack = Get-YamlValue $yaml 'legacy_stack_name'
$legacyContainer = Get-YamlValue $yaml 'legacy_container_name'
$legacyVolume = Get-YamlValue $yaml 'legacy_volume_name'
$volumeName = Get-YamlValue $yaml 'volume_name'
if (-not $stack) { throw 'stack_name missing in install.yaml' }
if (-not $containerName) { $containerName = 'maya-openwebui' }
if (-not $volumeName) { $volumeName = 'maya-openwebui-data' }

$composeFile = Join-Path $ProjectRoot 'docker-compose.yml'
if (-not (Test-Path $composeFile) -and $composeRel) {
    $composeFile = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ($composeRel -replace '/', [IO.Path]::DirectorySeparatorChar)))
}
if (-not (Test-Path $composeFile)) { throw "Compose file not found: $composeFile" }

$envFile = Join-Path $ProjectRoot '.env'
$envExample = Join-Path $ProjectRoot '.env.example'
if (-not (Test-Path $envFile)) {
    if (Test-Path $envExample) {
        Copy-Item $envExample $envFile
        Write-Host "Created .env from .env.example"
    } else {
        throw 'Missing .env and .env.example'
    }
}

$net = docker network ls --format '{{.Name}}' | Where-Object { $_ -eq 'pc-armin-local' }
if (-not $net) {
    docker network create pc-armin-local | Out-Host
    Write-Host 'Created docker network pc-armin-local'
}

# Keep DB/files: never down -v on install/update. Reuse or copy legacy volume once.
if (-not (Test-DockerVolume $volumeName) -and $legacyVolume -and (Test-DockerVolume $legacyVolume)) {
    Write-Host "Migrating volume $legacyVolume -> $volumeName (data kept)..."
    Copy-DockerVolume $legacyVolume $volumeName
}

$env:PUBLISH_PORT = if ($env:PUBLISH_PORT) { $env:PUBLISH_PORT } else { $publishPort }
$existing = Test-DockerName $containerName
$legacyExists = $legacyContainer -and (Test-DockerName $legacyContainer)
if ($existing -or $legacyExists) {
    Write-Host "Updating stack $stack (volumes kept)..."
} else {
    Write-Host "Installing stack $stack..."
}

Push-Location $ProjectRoot
try {
    # Stop old project name without deleting volumes, then bring up new stack.
    if ($legacyStack -and $legacyStack -ne $stack) {
        docker compose -p $legacyStack -f $composeFile --env-file $envFile down 2>$null | Out-Host
    }
    if ($legacyContainer -and $legacyContainer -ne $containerName -and (Test-DockerName $legacyContainer)) {
        docker rm -f $legacyContainer | Out-Host
    }
    docker compose -p $stack -f $composeFile --env-file $envFile up -d
} finally {
    Pop-Location
}

Write-Host "Done. container=$containerName"
Write-Host "  local:  http://maya.local/"
Write-Host "  path:   http://pc-armin/maya  or  http://10.20.9.59/maya  (302 -> http://maya.local/)"
Write-Host "  direct: http://127.0.0.1:$($env:PUBLISH_PORT)/  (debug only; prefer maya.local)"
