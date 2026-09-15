# Sync TFS RAG report catalogs into Maya (Open WebUI) Knowledge.
# Source: C:\Users\armin\TFS\Source\.armin\rag\user-65778-reports*.md
# Target: Knowledge "ERP Reports User 65778" on Cursor-API-Composer + all cursor-sdk-to-openai models

param(
  [string]$WebUiUrl = "http://127.0.0.1:3080",
  [string]$Email = "armin@local",
  [string]$Password = "dopadopa123",
  [string]$RagDir = "C:\Users\armin\TFS\Source\.armin\rag",
  [string]$KnowledgeName = "ERP Reports User 65778",
  [string]$ModelId = "erp-reports-65778",
  [string]$ModelName = "Cursor-API-Composer",
  [string]$BaseModelId = "pc-armin/maya:latest"
)

$ErrorActionPreference = "Stop"
$wantedNames = @("user-65778-reports-index.md", "user-65778-reports.md")
$files = @(
  (Join-Path $RagDir "user-65778-reports-index.md"),
  (Join-Path $RagDir "user-65778-reports.md")
)
foreach ($f in $files) {
  if (-not (Test-Path $f)) { throw "Missing RAG file: $f" }
}

$signin = Invoke-RestMethod -Uri "$WebUiUrl/api/v1/auths/signin" -Method POST `
  -Body (@{ email = $Email; password = $Password } | ConvertTo-Json) `
  -ContentType "application/json"
$token = $signin.token
$auth = @{ Authorization = "Bearer $token"; Accept = "application/json" }

$kbList = Invoke-RestMethod -Uri "$WebUiUrl/api/v1/knowledge/" -Headers $auth
$kb = @($kbList.items) | Where-Object { $_.name -eq $KnowledgeName } | Select-Object -First 1
if (-not $kb) {
  $kb = Invoke-RestMethod -Uri "$WebUiUrl/api/v1/knowledge/create" -Method POST `
    -Headers $auth -ContentType "application/json" `
    -Body (@{
      name = $KnowledgeName
      description = "ERP report catalog for ccUser=65778 (mkarimi). Synced from $RagDir"
    } | ConvertTo-Json)
  Write-Host "Created knowledge $($kb.id)"
} else {
  Write-Host "Using knowledge $($kb.id)"
}
$kbId = $kb.id

function Get-OpenWebUiFiles {
  $list = Invoke-RestMethod -Uri "$WebUiUrl/api/v1/files/" -Headers $auth
  return @($list.items)
}

function Find-FileByName([string]$name) {
  $matches = @(Get-OpenWebUiFiles | Where-Object {
    $_.filename -eq $name -or ($_.meta -and $_.meta.name -eq $name)
  })
  foreach ($candidate in $matches) {
    try {
      $st = Invoke-RestMethod -Uri "$WebUiUrl/api/v1/files/$($candidate.id)/process/status" -Headers $auth
      if ($st.status -eq "completed") { return $candidate }
    } catch { }
  }
  return $null
}

function Wait-FileProcessed([string]$fileId) {
  for ($i = 0; $i -lt 120; $i++) {
    $st = Invoke-RestMethod -Uri "$WebUiUrl/api/v1/files/$fileId/process/status" -Headers $auth
    if ($st.status -eq "completed") { return }
    if ($st.status -eq "failed") { throw "Processing failed for $fileId" }
    Start-Sleep -Seconds 2
  }
  throw "Timed out processing $fileId"
}

function Add-FileToKnowledge([string]$fileId, [string]$name) {
  try {
    Invoke-RestMethod -Uri "$WebUiUrl/api/v1/knowledge/$kbId/file/add" -Method POST `
      -Headers $auth -ContentType "application/json" `
      -Body (@{ file_id = $fileId } | ConvertTo-Json) | Out-Null
    Write-Host "Linked $name"
  } catch {
    $msg = $_.ErrorDetails.Message
    if ($msg -match "Duplicate content") {
      Write-Host "Already in knowledge (duplicate content): $name"
    } else {
      throw
    }
  }
}

# Detach old same-named files from the collection (best-effort)
$detail = Invoke-RestMethod -Uri "$WebUiUrl/api/v1/knowledge/$kbId" -Headers $auth
foreach ($existing in @($detail.files)) {
  $name = $null
  if ($existing.meta) { $name = $existing.meta.name }
  if ($name -in $wantedNames) {
    try {
      Invoke-RestMethod -Uri "$WebUiUrl/api/v1/knowledge/$kbId/file/remove" -Method POST `
        -Headers $auth -ContentType "application/json" `
        -Body (@{ file_id = $existing.id } | ConvertTo-Json) | Out-Null
      Write-Host "Removed old $name from knowledge"
    } catch {
      Write-Warning "Could not remove $name : $($_.Exception.Message)"
    }
  }
}

$linkedFileIds = @()
foreach ($path in $files) {
  $name = [IO.Path]::GetFileName($path)
  $existing = Find-FileByName $name
  if ($existing) {
    Write-Host "Reusing uploaded file $name ($($existing.id))"
    Wait-FileProcessed $existing.id
    Add-FileToKnowledge $existing.id $name
    $linkedFileIds += $existing.id
    continue
  }

  Write-Host "Uploading $name ..."
  $raw = & curl.exe -sS -X POST "$WebUiUrl/api/v1/files/" `
    -H "Authorization: Bearer $token" `
    -H "Accept: application/json" `
    -F "file=@$path;filename=$name;type=text/markdown"
  $uploaded = $raw | ConvertFrom-Json
  if (-not $uploaded.id) { throw "Upload failed for $name : $raw" }
  Wait-FileProcessed $uploaded.id
  Add-FileToKnowledge $uploaded.id $name
  $linkedFileIds += $uploaded.id
}

# Force knowledge.files membership (Open WebUI sometimes drops it after file/add)
Invoke-RestMethod -Uri "$WebUiUrl/api/v1/knowledge/$kbId/update" -Method POST `
  -Headers $auth -ContentType "application/json" `
  -Body (@{
    name = $KnowledgeName
    description = "ERP report catalog for ccUser=65778 (mkarimi). Synced from $RagDir"
    data = @{ file_ids = $linkedFileIds }
  } | ConvertTo-Json -Depth 5) | Out-Null

$verifyFiles = Invoke-RestMethod -Uri "$WebUiUrl/api/v1/knowledge/$kbId/files" -Headers $auth
$fileCount = @($verifyFiles.items).Count
Write-Host "Knowledge files after update: $fileCount"
if ($fileCount -lt 1) {
  throw "Knowledge has no files after sync"
}

# Non-admins need Knowledge read or RAG retrieval fails even when model has meta.knowledge.
Invoke-RestMethod -Uri "$WebUiUrl/api/v1/knowledge/$kbId/access/update" -Method POST `
  -Headers $auth -ContentType "application/json" `
  -Body (@{
    id = $kbId
    access_grants = @(
      @{ principal_type = "user"; principal_id = "*"; permission = "read" }
    )
  } | ConvertTo-Json -Depth 6) | Out-Null
Write-Host "Knowledge public read granted: $KnowledgeName"

$ragSystem = @"
You are Maya's ERP report finder for user 65778 (mkarimi).
Always use the attached knowledge collection first.
For each match return: 1) Persian title 2) Menu path 3) Local link 4) Production link if present.
Answer in the user's language. Do not invent pages that are not in the knowledge.
"@

$modelBody = @{
  id = $ModelId
  name = $ModelName
  base_model_id = $BaseModelId
  meta = @{
    description = "Ollama ($BaseModelId) + RAG for ERP reports (ccUser 65778). Knowledge: $KnowledgeName"
    hidden = $false
    knowledge = @(@{ id = $kbId; name = $KnowledgeName; type = "collection" })
  }
  params = @{
    # Open WebUI native FC exposes knowledge as tools (+ calendar). Gemma often
    # skips query_knowledge_files and claims "no access". Legacy injects RAG.
    function_calling = "legacy"
    system = $ragSystem
  }
  access_grants = @(
    @{ principal_type = "user"; principal_id = "*"; permission = "read" }
  )
} | ConvertTo-Json -Depth 8

try {
  Invoke-RestMethod -Uri "$WebUiUrl/api/v1/models/model/update" -Method POST `
    -Headers $auth -ContentType "application/json" -Body $modelBody | Out-Null
  Write-Host "Updated model $ModelId (base=$BaseModelId)"
} catch {
  Invoke-RestMethod -Uri "$WebUiUrl/api/v1/models/create" -Method POST `
    -Headers $auth -ContentType "application/json" -Body $modelBody | Out-Null
  Write-Host "Created model $ModelId (base=$BaseModelId)"
}

# Keep cursor-sdk-to-openai reachable from the Maya container (Docker DNS, not localhost).
# Public read on provider models is required so non-admin users do not get "Model not found".
Invoke-RestMethod -Uri "$WebUiUrl/openai/config/update" -Method POST `
  -Headers $auth -ContentType "application/json" `
  -Body (@{
    ENABLE_OPENAI_API = $true
    OPENAI_API_BASE_URLS = @("http://cursor-sdk-to-openai-api-1:8140/v1")
    OPENAI_API_KEYS = @("local")
    OPENAI_API_CONFIGS = @{
      "0" = @{
        enable = $true
        tags = @(@{ name = "cursor-sdk-to-openai" })
        connection_type = "external"
        auth_type = "bearer"
        prefix_id = ""
        model_ids = @()
      }
    }
  } | ConvertTo-Json -Depth 6) | Out-Null

Invoke-RestMethod -Uri "$WebUiUrl/ollama/config/update" -Method POST `
  -Headers $auth -ContentType "application/json" `
  -Body (@{
    ENABLE_OLLAMA_API = $true
    OLLAMA_BASE_URLS = @("http://host.docker.internal:11434")
    OLLAMA_API_CONFIGS = @{
      "0" = @{
        enable = $true
        model_ids = @($BaseModelId)
      }
    }
  } | ConvertTo-Json -Depth 6) | Out-Null

function Set-ModelPublicRead([string]$modelId, [bool]$hidden, [bool]$active) {
  try {
    $row = Invoke-RestMethod -Uri "$WebUiUrl/api/v1/models/model?id=$([uri]::EscapeDataString($modelId))" -Headers $auth
    if (-not $row -or -not $row.id) { return }
    $meta = @{}
    if ($row.meta) { $row.meta.PSObject.Properties | ForEach-Object { $meta[$_.Name] = $_.Value } }
    $meta["hidden"] = $hidden
    $body = @{
      id = $row.id
      name = $row.name
      base_model_id = $row.base_model_id
      meta = $meta
      params = $row.params
      access_grants = @(
        @{ principal_type = "user"; principal_id = "*"; permission = "read" }
      )
      is_active = $active
    } | ConvertTo-Json -Depth 8
    Invoke-RestMethod -Uri "$WebUiUrl/api/v1/models/model/update" -Method POST `
      -Headers $auth -ContentType "application/json" -Body $body | Out-Null
    Write-Host "Model $modelId active=$active hidden=$hidden public_read=true"
  } catch {
    Write-Host "Model row missing (ok if provider-only): $modelId"
  }
}

function Set-ProviderModelWithRag([string]$modelId) {
  try {
    $row = $null
    try {
      $row = Invoke-RestMethod -Uri "$WebUiUrl/api/v1/models/model?id=$([uri]::EscapeDataString($modelId))" -Headers $auth
    } catch { }

    $meta = @{}
    if ($row -and $row.meta) {
      $row.meta.PSObject.Properties | ForEach-Object { $meta[$_.Name] = $_.Value }
    }
    $meta["hidden"] = $false
    $meta["knowledge"] = @(@{ id = $kbId; name = $KnowledgeName; type = "collection" })
    $meta["description"] = "cursor-sdk-to-openai ($modelId) + RAG ($KnowledgeName)"

    $params = @{}
    if ($row -and $row.params) {
      $row.params.PSObject.Properties | ForEach-Object { $params[$_.Name] = $_.Value }
    }
    $params["function_calling"] = "legacy"
    $params["system"] = $ragSystem

    $body = @{
      id = $modelId
      name = $(if ($row -and $row.name) { $row.name } else { $modelId })
      base_model_id = $null
      meta = $meta
      params = $params
      access_grants = @(
        @{ principal_type = "user"; principal_id = "*"; permission = "read" }
      )
      is_active = $true
    } | ConvertTo-Json -Depth 10

    if ($row -and $row.id) {
      Invoke-RestMethod -Uri "$WebUiUrl/api/v1/models/model/update" -Method POST `
        -Headers $auth -ContentType "application/json" -Body $body | Out-Null
    } else {
      try {
        Invoke-RestMethod -Uri "$WebUiUrl/api/v1/models/create" -Method POST `
          -Headers $auth -ContentType "application/json" -Body $body | Out-Null
      } catch {
        Invoke-RestMethod -Uri "$WebUiUrl/api/v1/models/model/update" -Method POST `
          -Headers $auth -ContentType "application/json" -Body $body | Out-Null
      }
    }
    Write-Host "Provider+RAG $modelId"
  } catch {
    Write-Warning "Provider+RAG failed for $modelId : $($_.Exception.Message)"
  }
}

# Hide unused Ollama siblings; do NOT strip RAG from cursor-sdk-to-openai models.
foreach ($otherId in @("pc-armin/maya", "pc-armin/qwen", "gemma4:e4b", "qwen2.5:3b")) {
  Set-ModelPublicRead $otherId $true $false
}

# Open WebUI 0.11+: workspace model needs base id active + readable by the user.
# Hide Ollama base from picker; keep public read so non-admins can use Cursor-API-Composer.
Set-ModelPublicRead $BaseModelId $true $true

# Attach TFS RAG Knowledge to every cursor-sdk-to-openai model (all users).
try {
  $listed = Invoke-RestMethod -Uri "$WebUiUrl/openai/models" -Headers $auth
  $providerIds = @()
  if ($listed.data) { $providerIds = @($listed.data | ForEach-Object { $_.id }) }
  foreach ($pid in $providerIds) {
    Set-ProviderModelWithRag $pid
  }
  Write-Host "cursor-sdk-to-openai models with RAG: $($providerIds.Count)"
} catch {
  Write-Warning "Could not list/attach RAG on cursor-sdk-to-openai models: $($_.Exception.Message)"
}

Invoke-RestMethod -Uri "$WebUiUrl/api/v1/configs/models" -Method POST `
  -Headers $auth -ContentType "application/json" `
  -Body (@{
    DEFAULT_MODELS = $ModelId
    DEFAULT_PINNED_MODELS = $null
    MODEL_ORDER_LIST = @($ModelId)
    DEFAULT_MODEL_METADATA = @{}
    DEFAULT_MODEL_PARAMS = @{}
  } | ConvertTo-Json -Depth 5) | Out-Null
Write-Host "Default model set to $ModelId ($ModelName)"

Write-Host "Done. Default='$ModelName' + all cursor-sdk-to-openai models use RAG Knowledge '$KnowledgeName' (from $RagDir)."
