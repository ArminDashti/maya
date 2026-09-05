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

$yaml = Get-Content -Path $yamlPath -Raw
$stack = Get-YamlValue $yaml 'stack_name'
$composeRel = Get-YamlValue $yaml 'compose_file'
$publishPort = Get-YamlValue $yaml 'publish_port'
if (-not $stack) { throw 'stack_name missing in install.yaml' }

# Resolve relative to project root (yaml ../../ paths are fragile with Join-Path)
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

$env:PUBLISH_PORT = if ($env:PUBLISH_PORT) { $env:PUBLISH_PORT } else { $publishPort }
$existing = docker ps -a --filter "name=maya-open-webui" --format '{{.Names}}'
if ($existing) {
    Write-Host "Updating stack $stack (volumes kept)..."
} else {
    Write-Host "Installing stack $stack..."
}

Push-Location $ProjectRoot
try {
    docker compose -p $stack -f $composeFile --env-file $envFile up -d
} finally {
    Pop-Location
}

Write-Host "Done. UI: http://pc-armin:$($env:PUBLISH_PORT)/  (bookmark http://pc-armin/maya/ redirects here)"
