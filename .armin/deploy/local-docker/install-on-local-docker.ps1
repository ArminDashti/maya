# Install or update the local Maya Open WebUI Docker stack.
#
# Fresh run (no state file): derive names, pick a free port (persisted in state.json),
# ensure image + network, run containers, save state.
# Existing run (state file, or containers already present): stop/remove containers only,
# rebuild (pull/build) the image, recreate containers. Volumes/DB, port and names are
# always reused - never down -v, never re-pick the port.
# Idempotent: safe to re-run; never duplicates hosts entries, networks or volumes.
#
# Colors: Cyan = step, Yellow = info, Green = ok, Red = error.
param(
    [string]$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path,
    # Internal: elevated re-entry used only to edit the hosts file. The action is gated
    # by state.json (add only while installed) so a late UAC approval can never undo a removal.
    [ValidateSet('none', 'add', 'remove')]
    [string]$HostsAction = 'none'
)

$ErrorActionPreference = 'Stop'
$StatePath = Join-Path $PSScriptRoot 'state.json'
$YamlPath = Join-Path $PSScriptRoot 'install.yaml'
$HostsPath = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
$HostsWaitSeconds = 30
# Well-known ports to never auto-select even when momentarily free.
$ReservedPorts = @(21, 22, 25, 53, 80, 110, 135, 139, 143, 443, 445, 993, 995, 1433, 1521, 3306, 3389, 5432, 5985, 5986, 6443)

function Step([string]$m) { Write-Host $m -ForegroundColor Cyan }
function Info([string]$m) { Write-Host $m -ForegroundColor Yellow }
function Ok([string]$m) { Write-Host $m -ForegroundColor Green }
function Err([string]$m) { Write-Host $m -ForegroundColor Red }

function Get-YamlValue([string]$text, [string]$key) {
    if ($text -match "(?m)^${key}:\s*[`"']?([^`"'`r`n]+)") { return $Matches[1].Trim() }
    return $null
}

function Invoke-Docker {
    param([string[]]$Rest, [switch]$AllowFail)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & docker @Rest 2>&1 | ForEach-Object { "$_" } | Out-String
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prev
    }
    if ($code -ne 0 -and -not $AllowFail) {
        throw "docker $($Rest -join ' ') failed (exit code ${code}):`n$($out.Trim())"
    }
    return [pscustomobject]@{ ExitCode = $code; Output = $out }
}

$script:ComposeBase = @()
function Invoke-Compose {
    param([string[]]$Rest, [switch]$AllowFail)
    return Invoke-Docker ($script:ComposeBase + $Rest) -AllowFail:$AllowFail
}

function Test-Container([string]$Name) {
    if (-not $Name) { return $false }
    $r = Invoke-Docker @('ps', '-a', '--filter', "name=^/$Name$", '--format', '{{.Names}}') -AllowFail
    foreach ($line in ($r.Output -split "`n")) { if ($line.Trim() -eq $Name) { return $true } }
    return $false
}

function Test-Volume([string]$Name) {
    if (-not $Name) { return $false }
    $r = Invoke-Docker @('volume', 'ls', '--format', '{{.Name}}') -AllowFail
    foreach ($line in ($r.Output -split "`n")) { if ($line.Trim() -eq $Name) { return $true } }
    return $false
}

function Get-PublishedPort([string]$Name, [string]$Internal) {
    $r = Invoke-Docker @('port', $Name, "$Internal/tcp") -AllowFail
    if ($r.ExitCode -ne 0) { return $null }
    foreach ($line in ($r.Output -split "`n")) {
        if ($line -match ':(\d+)\s*$') { return [int]$Matches[1] }
    }
    return $null
}

function Copy-DockerVolume([string]$from, [string]$to) {
    Invoke-Docker @('volume', 'create', $to) | Out-Null
    Invoke-Docker @('run', '--rm', '-v', "${from}:/from", '-v', "${to}:/to", 'alpine:3.20', 'sh', '-c', 'cd /from && cp -a . /to/')
}

function Test-PortFree([int]$Port) {
    if ($ReservedPorts -contains $Port) { return $false }
    $listen = Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue
    if ($listen) { return $false }
    try {
        $l = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $Port)
        $l.Start()
        $l.Stop()
        return $true
    } catch { return $false }
}

function Get-FreePort([int]$Preferred) {
    for ($p = $Preferred; $p -lt ($Preferred + 100); $p++) {
        if (Test-PortFree $p) { return $p }
    }
    throw "No free port found in range $Preferred..$($Preferred + 99)"
}

function Test-HostsEntry([string]$Addr) {
    if (-not (Test-Path -LiteralPath $HostsPath)) { return $false }
    foreach ($line in [System.IO.File]::ReadAllLines($HostsPath)) {
        $t = $line.Trim() -split '\s+'
        if ($t.Count -ge 2 -and $t[0] -eq '127.0.0.1' -and ($t -contains $Addr)) { return $true }
    }
    return $false
}

function Add-HostsEntry([string]$Addr) {
    [System.IO.File]::AppendAllText($HostsPath, "127.0.0.1`t$Addr`r`n", [System.Text.Encoding]::ASCII)
}

function Remove-HostsEntry([string]$Addr) {
    $lines = [System.IO.File]::ReadAllLines($HostsPath)
    $kept = New-Object System.Collections.Generic.List[string]
    $esc = [regex]::Escape($Addr)
    foreach ($line in $lines) {
        $t = $line.Trim() -split '\s+'
        if ($t.Count -ge 2 -and $t[0] -eq '127.0.0.1' -and ($t -contains $Addr)) {
            $new = ($line -replace ("\s+" + $esc + '\b'), '').TrimEnd()
            if ($new -match '^\s*127\.0\.0\.1\s*$') { continue }
            $kept.Add($new)
        } else {
            $kept.Add($line)
        }
    }
    [System.IO.File]::WriteAllLines($HostsPath, $kept.ToArray(), [System.Text.Encoding]::ASCII)
}

function Invoke-HostsEdit([string]$Action, [string]$Addr) {
    # Direct attempt first (works when running elevated).
    try {
        if ($Action -eq 'add') {
            if (Test-HostsEntry $Addr) { Ok "hosts: 127.0.0.1 $Addr already present"; return $true }
            Add-HostsEntry $Addr
        } else {
            if (-not (Test-HostsEntry $Addr)) { Ok "hosts: $Addr entry already absent"; return $true }
            Remove-HostsEntry $Addr
        }
        if ((Test-HostsEntry $Addr) -eq ($Action -eq 'add')) {
            Ok "hosts: 127.0.0.1 $Addr $($Action -replace 'add', 'added' -replace 'remove', 'removed')"
            return $true
        }
        Err "hosts: write to $HostsPath did not take effect"
        return $false
    } catch {
        Info "hosts: direct write denied ($($_.Exception.Message)) - elevation required"
    }
    # Not elevated: re-enter this script elevated (UAC prompt). state.json gates the action.
    $argList = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File',
        "`"$PSCommandPath`"", '-ProjectRoot', "`"$ProjectRoot`"", '-HostsAction', $Action
    )
    try {
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argList | Out-Null
    } catch {
        Info "hosts: elevation declined - run this script as Administrator to edit $HostsPath"
        return $false
    }
    Info "hosts: waiting ${HostsWaitSeconds}s for the UAC prompt ($Action $Addr)..."
    $deadline = (Get-Date).AddSeconds($HostsWaitSeconds)
    while ((Get-Date) -lt $deadline) {
        $present = Test-HostsEntry $Addr
        if ($Action -eq 'add' -and $present) { Ok "hosts: 127.0.0.1 $Addr added (elevated)"; return $true }
        if ($Action -eq 'remove' -and -not $present) { Ok "hosts: $Addr removed (elevated)"; return $true }
        Start-Sleep -Seconds 2
    }
    Info "hosts: no elevation within ${HostsWaitSeconds}s - entry left as-is (approve the UAC prompt or re-run elevated)"
    return $false
}

function Resolve-LocalAddress([string]$yamlText) {
    $a = Get-YamlValue $yamlText 'local_address'
    if ($a) { return $a }
    foreach ($f in @((Join-Path $ProjectRoot '.env'), (Join-Path $ProjectRoot '.env.example'))) {
        if (Test-Path -LiteralPath $f) {
            $raw = Get-Content -LiteralPath $f -Raw
            if ($raw -match '(?m)^WEBUI_URL\s*=\s*\w+://([^/:`\s]+)') { return $Matches[1] }
        }
    }
    return 'maya.local'
}

function Set-EnvPublishPort([string]$Path, [int]$Port) {
    $raw = [System.IO.File]::ReadAllText($Path).TrimStart([char]0xFEFF)
    $new = "PUBLISH_PORT=$Port"
    if ($raw -match '(?m)^PUBLISH_PORT=') {
        $updated = $raw -replace '(?m)^PUBLISH_PORT=.*$', $new
    } else {
        $updated = $raw.TrimEnd() + "`r`n$new`r`n"
    }
    if ($updated -ne $raw) {
        [System.IO.File]::WriteAllText($Path, $updated)
        Info ".env: PUBLISH_PORT set to $Port (compose port follows state, not .env drift)"
    }
}

# --- Elevated re-entry: perform only the hosts edit, then exit. -----------------
if ($HostsAction -ne 'none') {
    if (-not (Test-Path -LiteralPath $YamlPath)) { exit 1 }
    $addr0 = Resolve-LocalAddress (Get-Content -LiteralPath $YamlPath -Raw)
    $installed = Test-Path -LiteralPath $StatePath
    $should = ($HostsAction -eq 'add' -and $installed) -or ($HostsAction -eq 'remove' -and -not $installed)
    if (-not $should) { exit 0 }
    try {
        if ($HostsAction -eq 'add') { if (-not (Test-HostsEntry $addr0)) { Add-HostsEntry $addr0 } }
        else { if (Test-HostsEntry $addr0) { Remove-HostsEntry $addr0 } }
        exit 0
    } catch { exit 1 }
}

# --- [1/8] prerequisites -------------------------------------------------------
Step '[1/8] Checking prerequisites...'
$docker = Invoke-Docker @('version', '--format', '{{.Server.Version}}') -AllowFail
if ($docker.ExitCode -ne 0) { Err "Docker is not running (or not installed):`n$($docker.Output.Trim())"; exit 1 }
Ok "Docker daemon $($docker.Output.Trim())"

if (-not (Test-Path -LiteralPath $YamlPath)) { Err "Missing config: $YamlPath"; exit 1 }
$yaml = Get-Content -LiteralPath $YamlPath -Raw
$Stack = Get-YamlValue $yaml 'stack_name'
$ImageTag = Get-YamlValue $yaml 'image_tag'
$ContainerName = Get-YamlValue $yaml 'container_name'
$VolumeName = Get-YamlValue $yaml 'volume_name'
$LegacyStack = Get-YamlValue $yaml 'legacy_stack_name'
$LegacyContainer = Get-YamlValue $yaml 'legacy_container_name'
$LegacyVolume = Get-YamlValue $yaml 'legacy_volume_name'
$NetworkName = Get-YamlValue $yaml 'docker_network'
$InternalPort = Get-YamlValue $yaml 'internal_port'
$PreferredPort = Get-YamlValue $yaml 'publish_port'
if (-not $Stack) { Err 'stack_name missing in install.yaml'; exit 1 }
if (-not $ContainerName) { $ContainerName = 'maya-openwebui' }
if (-not $VolumeName) { $VolumeName = 'maya-openwebui-data' }
if (-not $InternalPort) { $InternalPort = '8080' }
if (-not $PreferredPort) { $PreferredPort = '3080' }
$Addr = Resolve-LocalAddress $yaml

$ComposeFile = Join-Path $ProjectRoot 'docker-compose.yml'
if (-not (Test-Path -LiteralPath $ComposeFile)) {
    $rel = Get-YamlValue $yaml 'compose_file'
    if ($rel) {
        $ComposeFile = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ($rel -replace '/', [IO.Path]::DirectorySeparatorChar)))
    }
}
if (-not (Test-Path -LiteralPath $ComposeFile)) { Err "Compose file not found: $ComposeFile"; exit 1 }

$EnvFile = Join-Path $ProjectRoot '.env'
if (-not (Test-Path -LiteralPath $EnvFile)) {
    $envExample = Join-Path $ProjectRoot '.env.example'
    if (Test-Path -LiteralPath $envExample) {
        Copy-Item -LiteralPath $envExample -Destination $EnvFile
        Info 'Created .env from .env.example'
    } else {
        Err 'Missing both .env and .env.example'
        exit 1
    }
}
$script:ComposeBase = @('compose', '-p', $Stack, '-f', $ComposeFile, '--env-file', $EnvFile)
Ok "stack=$Stack container=$ContainerName image=$ImageTag addr=$Addr"

# --- [2/8] state, port, network ------------------------------------------------
Step '[2/8] Detecting install state, port and network...'
$state = $null
if (Test-Path -LiteralPath $StatePath) {
    try { $state = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json }
    catch { Info "state file unreadable - treating as fresh: $($_.Exception.Message)" }
}
$containerExists = Test-Container $ContainerName
$mode = 'fresh'
if ($state) { $mode = 'update' }
elseif ($containerExists) { $mode = 'adopt' }

$port = $null
if ($state -and $state.publishPort) {
    $port = [int]$state.publishPort
    Info "port $port (from state file - never re-picked)"
} elseif ($containerExists) {
    $port = Get-PublishedPort $ContainerName $InternalPort
    if ($port) { Info "port $port (adopted from existing container)" }
}
if (-not $port) {
    $port = Get-FreePort ([int]$PreferredPort)
    if ($port -eq [int]$PreferredPort) { Info "port $port (preferred and free)" }
    else { Info "port $port (preferred busy/reserved - next free port selected)" }
}
$env:PUBLISH_PORT = "$port"

$networkCreated = $false
if ($state) { $networkCreated = [bool]$state.networkCreated }
if ($NetworkName) {
    $netExists = $false
    $netList = Invoke-Docker @('network', 'ls', '--format', '{{.Name}}') -AllowFail
    foreach ($line in ($netList.Output -split "`n")) { if ($line.Trim() -eq $NetworkName) { $netExists = $true } }
    if (-not $netExists) {
        Invoke-Docker @('network', 'create', $NetworkName) | Out-Null
        $networkCreated = $true
        Ok "created network $NetworkName"
    } else {
        Info "network $NetworkName already present (shared/external - never duplicated)"
    }
}

# Keep DB/files: reuse or copy the legacy volume once; never down -v on install/update.
if (-not (Test-Volume $VolumeName) -and $LegacyVolume -and (Test-Volume $LegacyVolume)) {
    Info "Migrating volume $LegacyVolume -> $VolumeName (data kept)..."
    Copy-DockerVolume $LegacyVolume $VolumeName
    Ok 'legacy volume data copied'
}
Ok "mode=$mode port=$port"

# --- [3/8] stop/remove existing containers (volumes untouched) -----------------
if ($mode -eq 'fresh') {
    Step '[3/8] Fresh install - no existing containers to stop'
} else {
    Step '[3/8] Stopping existing containers (volumes/DB untouched - never down -v)...'
    if ($LegacyStack -and $LegacyStack -ne $Stack) {
        Invoke-Docker @('compose', '-p', $LegacyStack, '-f', $ComposeFile, '--env-file', $EnvFile, 'down') -AllowFail | Out-Null
    }
    if ($LegacyContainer -and $LegacyContainer -ne $ContainerName -and (Test-Container $LegacyContainer)) {
        Invoke-Docker @('rm', '-f', $LegacyContainer) -AllowFail | Out-Null
    }
    $rm = Invoke-Compose @('rm', '-s', '-f') -AllowFail
    if ($rm.ExitCode -eq 0) { Ok 'existing stack containers removed (orphans left alone)' }
    else { Info "compose rm: $($rm.Output.Trim())" }
}

# --- [4/8] ensure image (pull, or build when compose defines build) ------------
Step "[4/8] Ensuring image $ImageTag..."
$composeText = Get-Content -LiteralPath $ComposeFile -Raw
if ($composeText -match '(?m)^\s+build\s*:') {
    Info 'compose file defines build: running docker compose build...'
    Invoke-Compose @('build')
    Ok 'image built'
} else {
    $pull = Invoke-Docker @('pull', $ImageTag) -AllowFail
    if ($pull.ExitCode -eq 0) {
        Ok 'image pulled (up to date)'
    } else {
        $hasLocal = (Invoke-Docker @('image', 'inspect', $ImageTag) -AllowFail).ExitCode -eq 0
        if ($hasLocal) { Info 'pull failed - using existing local image' }
        else { Err "image unavailable and pull failed:`n$($pull.Output.Trim())"; exit 1 }
    }
}

# --- [5/8] start containers ----------------------------------------------------
Step '[5/8] Starting containers...'
Invoke-Compose @('up', '-d') | Out-Null
Ok "containers started (project $Stack)"

# --- [6/8] save state ----------------------------------------------------------
Step '[6/8] Saving state...'
$now = (Get-Date).ToString('o')
$installedAt = $now
if ($state -and $state.installedAt) { $installedAt = $state.installedAt }
$stateOut = [ordered]@{
    version        = 1
    stack          = $Stack
    composeFile    = $ComposeFile
    containerName  = $ContainerName
    volumeName     = $VolumeName
    volumes        = @($VolumeName)
    imageName      = $ImageTag
    publishPort    = [int]$port
    internalPort   = [int]$InternalPort
    networkName    = $NetworkName
    networkCreated = [bool]$networkCreated
    localAddress   = "$Addr"
    cliInstalled   = $false
    installedAt    = $installedAt
    updatedAt      = $now
}
$stateOut | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $StatePath -Encoding UTF8
Ok "state saved: $StatePath (port $port and names reused on every future run)"
Set-EnvPublishPort $EnvFile ([int]$port)

# Drop a stale image tag when the configured tag changed.
if ($state -and $state.imageName -and ($state.imageName -ne $ImageTag)) {
    $users = Invoke-Docker @('ps', '-a', '--filter', "ancestor=$($state.imageName)", '--format', '{{.Names}}') -AllowFail
    $userList = @($users.Output -split "`n" | Where-Object { $_.Trim() })
    if ($userList.Count -eq 0) {
        $old = Invoke-Docker @('rmi', $state.imageName) -AllowFail
        if ($old.ExitCode -eq 0) { Ok "old image removed: $($state.imageName)" }
    } else {
        Info "old image $($state.imageName) still used by: $($userList -join ', ') - kept"
    }
}

# --- [7/8] hosts entry (127.0.0.1 <local-address>) -----------------------------
Step "[7/8] Ensuring hosts entry 127.0.0.1 $Addr..."
Invoke-HostsEdit 'add' $Addr | Out-Null

# --- [8/8] verify --------------------------------------------------------------
Step '[8/8] Verifying containers, ports and reachability...'
$running = $false
for ($i = 0; $i -lt 15; $i++) {
    $r = Invoke-Docker @('inspect', '-f', '{{.State.Running}}', $ContainerName) -AllowFail
    if ($r.Output.Trim() -eq 'true') { $running = $true; break }
    Start-Sleep -Seconds 2
}
if (-not $running) { Err "container $ContainerName is not running (docker logs $ContainerName)"; exit 1 }
Ok "container $ContainerName running"

$bound = Get-PublishedPort $ContainerName $InternalPort
if ($bound -eq [int]$port) { Ok "port published: host $bound -> container $InternalPort" }
else { Err "expected port $port published, got '$bound'"; exit 1 }

$httpOk = $false
for ($i = 0; $i -lt 30; $i++) {
    try {
        $resp = Invoke-WebRequest -Uri "http://127.0.0.1:$port/" -UseBasicParsing -TimeoutSec 5
        if ($resp.StatusCode -ge 200 -and $resp.StatusCode -lt 400) { $httpOk = $true; break }
    } catch { Start-Sleep -Seconds 3 }
}
if ($httpOk) { Ok "host reachable: http://127.0.0.1:$port/" }
else { Info "http://127.0.0.1:$port/ not answering yet (cold start can take a while) - docker logs $ContainerName" }

try {
    Invoke-WebRequest -Uri "http://${Addr}:$port/" -UseBasicParsing -TimeoutSec 5 | Out-Null
    Ok "local-address reachable: http://${Addr}:$port/"
} catch { Info "http://${Addr}:$port/ not answering yet" }
try {
    Invoke-WebRequest -Uri "http://$Addr/" -UseBasicParsing -TimeoutSec 5 | Out-Null
    Ok "canonical reachable: http://$Addr/"
} catch { Info "http://$Addr/ not answering (nginx-gateway lives outside this stack)" }

$dns = Invoke-Docker @('exec', $ContainerName, 'curl', '-fsS', '-m', '5', "http://${ContainerName}:$InternalPort/health") -AllowFail
if ($dns.ExitCode -eq 0) { Ok "in-network reachable: http://${ContainerName}:$InternalPort/health" }
else { Info 'in-network health check not answering yet' }

if (Test-HostsEntry $Addr) { Ok "hosts: 127.0.0.1 $Addr present (no duplicates)" }
else { Info "hosts: $Addr missing - from an elevated shell add: 127.0.0.1 $Addr" }
Info 'CLI: not applicable for this stack (web service - no PATH entry managed)'

Ok "Done ($mode). container=$ContainerName port=$port volume=$VolumeName"
Write-Host "  local:  http://$Addr/" -ForegroundColor Cyan
Write-Host "  direct: http://127.0.0.1:$port/" -ForegroundColor Cyan
Write-Host "  path:   http://pc-armin/maya  or  http://10.20.9.59/maya  (302 -> http://$Addr/)" -ForegroundColor Cyan
