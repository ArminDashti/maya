# Remove the local Maya Open WebUI Docker stack completely: containers (incl. project
# orphans), image, named volumes (FULL WIPE - database and models), the compose default
# network, the hosts entry and the state file. The shared/external network is only
# removed when this script created it. Requires confirmation unless -Force.
#
# Colors: Cyan = step, Yellow = info, Green = ok, Red = error.
param(
    [string]$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path,
    [switch]$Force,
    # Internal: elevated re-entry used only to edit the hosts file. The action is gated
    # by state.json (remove only while the stack is gone) so a late UAC approval can
    # never strip the entry from a reinstalled stack.
    [ValidateSet('none', 'add', 'remove')]
    [string]$HostsAction = 'none'
)

$ErrorActionPreference = 'Stop'
$StatePath = Join-Path $PSScriptRoot 'state.json'
$YamlPath = Join-Path $PSScriptRoot 'install.yaml'
$HostsPath = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
$HostsWaitSeconds = 30

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

function Get-ContainerNamesByLabel([string]$Label) {
    $r = Invoke-Docker @('ps', '-a', '--filter', $Label, '--format', '{{.Names}}') -AllowFail
    $names = @()
    foreach ($line in ($r.Output -split "`n")) { $n = $line.Trim(); if ($n) { $names += $n } }
    return $names
}

function Get-VolumeNamesByLabel([string]$Label) {
    $r = Invoke-Docker @('volume', 'ls', '--filter', $Label, '--format', '{{.Name}}') -AllowFail
    $names = @()
    foreach ($line in ($r.Output -split "`n")) { $n = $line.Trim(); if ($n) { $names += $n } }
    return $names
}

function Test-NetName([string]$Name) {
    if (-not $Name) { return $false }
    $r = Invoke-Docker @('network', 'ls', '--format', '{{.Name}}') -AllowFail
    foreach ($line in ($r.Output -split "`n")) { if ($line.Trim() -eq $Name) { return $true } }
    return $false
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
            Ok "hosts: 127.0.0.1 $Addr processed"
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
$Addr = Resolve-LocalAddress $yaml
if (-not $Stack) { Err 'stack_name missing in install.yaml'; exit 1 }
if (-not $ContainerName) { $ContainerName = 'maya-openwebui' }
if (-not $VolumeName) { $VolumeName = 'maya-openwebui-data' }

$ComposeFile = Join-Path $ProjectRoot 'docker-compose.yml'
if (-not (Test-Path -LiteralPath $ComposeFile)) {
    $rel = Get-YamlValue $yaml 'compose_file'
    if ($rel) {
        $ComposeFile = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ($rel -replace '/', [IO.Path]::DirectorySeparatorChar)))
    }
}
if (-not (Test-Path -LiteralPath $ComposeFile)) { Err "Compose file not found: $ComposeFile"; exit 1 }
$EnvFile = Join-Path $ProjectRoot '.env'

$state = $null
if (Test-Path -LiteralPath $StatePath) {
    try { $state = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json }
    catch { Info "state file unreadable - falling back to install.yaml: $($_.Exception.Message)" }
}
if ($state -and $state.publishPort) { $env:PUBLISH_PORT = "$([int]$state.publishPort)" }

$images = New-Object 'System.Collections.Generic.List[string]'
if ($state -and $state.imageName) { [void]$images.Add($state.imageName) }
if ($ImageTag) { [void]$images.Add($ImageTag) }
$imageList = @($images | Select-Object -Unique)

# --- [2/8] removal plan + confirmation -----------------------------------------
Step '[2/8] Removal plan:'
$extraNet = 'none'
if ($NetworkName) { $extraNet = "$NetworkName (removed only if created by this script)" }
Write-Host "  project   : $Stack  ($ComposeFile)"
Write-Host "  containers: $ContainerName, $LegacyContainer + all labeled '$Stack'/'$LegacyStack' (incl. orphans like 'ollama')"
Write-Host "  volumes   : $VolumeName, $LegacyVolume + labeled leftovers" -ForegroundColor Yellow
Write-Host "              WARNING: DATABASE AND EMBEDDING MODELS WILL BE PERMANENTLY DELETED" -ForegroundColor Yellow
Write-Host "  images    : $($imageList -join ', ')"
Write-Host "  networks  : ${Stack}_default, $extraNet"
Write-Host "  hosts     : 127.0.0.1 $Addr    PATH: no CLI entry (N/A)"
Write-Host "  state     : $StatePath"
if ($Force) {
    Info '-Force supplied - proceeding without confirmation'
} else {
    $answer = Read-Host "Type 'yes' to permanently delete everything listed above"
    if ($answer -ne 'yes') { Info 'Aborted - nothing was changed.'; exit 0 }
}

# --- [3/8] containers ----------------------------------------------------------
Step '[3/8] Removing containers (stack + legacy + orphans)...'
$down = Invoke-Docker @('compose', '-p', $Stack, '-f', $ComposeFile, '--env-file', $EnvFile, 'down', '-v', '--remove-orphans') -AllowFail
if ($down.ExitCode -eq 0) { Ok 'compose down: containers, declared volumes and default network removed' }
else { Info "compose down: $($down.Output.Trim())" }

if ($LegacyStack -and $LegacyStack -ne $Stack) {
    Invoke-Docker @('compose', '-p', $LegacyStack, '-f', $ComposeFile, '--env-file', $EnvFile, 'down', '-v', '--remove-orphans') -AllowFail | Out-Null
}
foreach ($name in @($ContainerName, $LegacyContainer)) {
    if ($name -and (Test-Container $name)) {
        Invoke-Docker @('rm', '-f', $name) -AllowFail | Out-Null
        Ok "removed container $name"
    }
}
$projectLabels = @("label=com.docker.compose.project=$Stack")
if ($LegacyStack) { $projectLabels += "label=com.docker.compose.project=$LegacyStack" }
foreach ($label in $projectLabels) {
    foreach ($name in (Get-ContainerNamesByLabel $label)) {
        Invoke-Docker @('rm', '-f', $name) -AllowFail | Out-Null
        Ok "removed leftover container $name"
    }
}

# --- [4/8] volumes (full wipe) -------------------------------------------------
Step '[4/8] Removing named volumes (FULL WIPE - DB and models)...'
$volCandidates = New-Object 'System.Collections.Generic.HashSet[string]'
foreach ($v in @($VolumeName, $LegacyVolume, 'maya_maya-openwebui-data', 'maya_maya-open-webui-data', 'maya-local_maya-open-webui-data')) {
    if ($v) { [void]$volCandidates.Add($v) }
}
if ($state -and $state.volumes) { foreach ($v in @($state.volumes)) { if ($v) { [void]$volCandidates.Add($v) } } }
foreach ($label in $projectLabels) {
    foreach ($v in (Get-VolumeNamesByLabel $label)) { [void]$volCandidates.Add($v) }
}
$volRemoved = 0
foreach ($v in $volCandidates) {
    if (Test-Volume $v) {
        $r = Invoke-Docker @('volume', 'rm', $v) -AllowFail
        if ($r.ExitCode -eq 0) { $volRemoved++; Ok "removed volume $v" }
        else { Err "could not remove volume ${v}: $($r.Output.Trim())" }
    }
}
if ($volRemoved -eq 0) { Info 'no matching volumes present' }

# --- [5/8] images --------------------------------------------------------------
Step '[5/8] Removing images...'
$imageRemoved = 0
foreach ($img in $imageList) {
    $inspect = Invoke-Docker @('image', 'inspect', $img) -AllowFail
    if ($inspect.ExitCode -ne 0) { Info "image not present: $img"; continue }
    $ur = Invoke-Docker @('ps', '-a', '--filter', "ancestor=$img", '--format', '{{.Names}}') -AllowFail
    $userNames = @()
    foreach ($line in ($ur.Output -split "`n")) { $n = $line.Trim(); if ($n) { $userNames += $n } }
    if ($userNames.Count -gt 0) {
        Info "image $img still used by [$($userNames -join ', ')] - kept"
        continue
    }
    $r = Invoke-Docker @('rmi', $img) -AllowFail
    if ($r.ExitCode -eq 0) { $imageRemoved++; Ok "removed image $img" }
    else { Err "could not remove image ${img}: $($r.Output.Trim())" }
}

# --- [6/8] networks ------------------------------------------------------------
Step '[6/8] Removing networks...'
$failNetwork = $false
$defaultNet = "${Stack}_default"
if (Test-NetName $defaultNet) {
    $eps = Invoke-Docker @('network', 'inspect', '--format', '{{len .Containers}}', $defaultNet) -AllowFail
    if ($eps.Output.Trim() -eq '0') {
        $r = Invoke-Docker @('network', 'rm', $defaultNet) -AllowFail
        if ($r.ExitCode -eq 0) { Ok "removed network $defaultNet" }
        else { Err "could not remove network ${defaultNet}: $($r.Output.Trim())"; $failNetwork = $true }
    } else {
        Err "network $defaultNet still has endpoints: $($eps.Output.Trim())"
        $failNetwork = $true
    }
} else {
    Ok "network $defaultNet already absent"
}
if ($NetworkName) {
    if (Test-NetName $NetworkName) {
        $created = $false
        if ($state) { $created = [bool]$state.networkCreated }
        if ($created) {
            $eps = Invoke-Docker @('network', 'inspect', '--format', '{{len .Containers}}', $NetworkName) -AllowFail
            if ($eps.Output.Trim() -eq '0') {
                $r = Invoke-Docker @('network', 'rm', $NetworkName) -AllowFail
                if ($r.ExitCode -eq 0) { Ok "removed network $NetworkName (created by this script)" }
                else { Err "could not remove network ${NetworkName}: $($r.Output.Trim())"; $failNetwork = $true }
            } else {
                Info "network $NetworkName still has endpoints - kept"
            }
        } else {
            Info "network $NetworkName kept (shared/external - not created by this script, other stacks use it)"
        }
    } else {
        Ok "network $NetworkName already absent"
    }
}

# --- [7/8] hosts, PATH, state file ---------------------------------------------
Step "[7/8] Removing hosts entry, PATH entry and state file..."
$hostsOk = $true
if (Test-HostsEntry $Addr) {
    Invoke-HostsEdit 'remove' $Addr | Out-Null
    if (Test-HostsEntry $Addr) { $hostsOk = $false }
} else {
    Ok "hosts: $Addr entry already absent"
}
if ($state -and $state.cliInstalled) {
    Info 'state indicates a CLI PATH entry - removing it'
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if ($userPath) {
        $parts = @($userPath -split ';' | Where-Object { $_ -and ($_ -notlike '*\maya*') })
        [Environment]::SetEnvironmentVariable('Path', ($parts -join ';'), 'User')
        Ok 'PATH: CLI entry removed'
    }
} else {
    Ok 'PATH: no CLI entry installed (N/A)'
}
if (Test-Path -LiteralPath $StatePath) {
    Remove-Item -LiteralPath $StatePath -Force
    Ok "state file removed: $StatePath"
} else {
    Ok 'state file already absent'
}

# --- [8/8] verify --------------------------------------------------------------
Step '[8/8] Verifying removal...'
$fail = 0

$leftover = @()
foreach ($name in @($ContainerName, $LegacyContainer)) {
    if ($name -and (Test-Container $name)) { $leftover += $name }
}
foreach ($label in $projectLabels) { $leftover += Get-ContainerNamesByLabel $label }
$leftover = @($leftover | Sort-Object -Unique)
if ($leftover.Count -gt 0) { Err "containers remain: $($leftover -join ', ')"; $fail++ }
else { Ok 'containers: none left (incl. project orphans)' }

$vLeft = @()
foreach ($v in $volCandidates) { if (Test-Volume $v) { $vLeft += $v } }
if ($vLeft.Count -gt 0) { Err "volumes remain: $($vLeft -join ', ')"; $fail++ }
else { Ok 'volumes: none left (DB + models wiped)' }

$iLeft = @()
foreach ($img in $imageList) {
    if ((Invoke-Docker @('image', 'inspect', $img) -AllowFail).ExitCode -eq 0) { $iLeft += $img }
}
if ($iLeft.Count -gt 0) { Err "images remain: $($iLeft -join ', ')"; $fail++ }
else { Ok 'images: none left' }

if (Test-NetName $defaultNet) { Err "network remains: $defaultNet"; $fail++ }
else { Ok "network: $defaultNet gone" }
if ($NetworkName -and (Test-NetName $NetworkName)) {
    if ($state -and $state.networkCreated) { Err "network remains: $NetworkName"; $fail++ }
    else { Ok "network: $NetworkName kept (shared/external - expected)" }
} else {
    Ok "network: $NetworkName absent"
}

if (Test-HostsEntry $Addr) { Err "hosts: 127.0.0.1 $Addr still present (needs an elevated run or UAC approval)"; $fail++ }
else { Ok "hosts: 127.0.0.1 $Addr removed" }
Ok 'PATH: no CLI entry was ever installed (N/A)'

if ($fail -gt 0) {
    Err "Removal incomplete: $fail check(s) failed"
    exit 1
}
Ok "Stack '$Stack' fully removed."
