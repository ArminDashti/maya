# Sync TFS RAG report catalogs into Maya (Open WebUI) Knowledge.
# Source: C:\Users\armin\TFS\Source\.armin\rag\user-65778-reports*.md
# Target: Knowledge "ERP Reports User 65778" + model erp-reports-65778

param(
  [string]$WebUiUrl = "http://127.0.0.1:3080",
  [string]$Email = "armin@local",
  [string]$Password = "dopadopa123",
  [string]$RagDir = "C:\Users\armin\TFS\Source\.armin\rag",
  [string]$KnowledgeName = "ERP Reports User 65778",
  [string]$ModelId = "erp-reports-65778"
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

$verify = Invoke-RestMethod -Uri "$WebUiUrl/api/v1/knowledge/$kbId" -Headers $auth
$fileCount = @($verify.files).Count
Write-Host "Knowledge files after update: $fileCount"
if ($fileCount -lt 1) {
  throw "Knowledge has no files after sync"
}

$modelBody = @{
  id = $ModelId
  name = "ERP Reports 65778"
  base_model_id = "composer-2.5"
  meta = @{
    description = "RAG model for ERP reports (ccUser 65778). Knowledge: $KnowledgeName"
    knowledge = @(@{ id = $kbId; name = $KnowledgeName; type = "collection" })
  }
  params = @{
    system = @"
You are Maya's ERP report finder for user 65778 (mkarimi).
Always use the attached knowledge collection first.
For each match return: 1) Persian title 2) Menu path 3) Local link 4) Production link if present.
Answer in the user's language. Do not invent pages that are not in the knowledge.
"@
  }
} | ConvertTo-Json -Depth 8

try {
  Invoke-RestMethod -Uri "$WebUiUrl/api/v1/models/model/update" -Method POST `
    -Headers $auth -ContentType "application/json" -Body $modelBody | Out-Null
  Write-Host "Updated model $ModelId"
} catch {
  Invoke-RestMethod -Uri "$WebUiUrl/api/v1/models/create" -Method POST `
    -Headers $auth -ContentType "application/json" -Body $modelBody | Out-Null
  Write-Host "Created model $ModelId"
}

# Make the RAG model the default so new chats attach knowledge automatically.
Invoke-RestMethod -Uri "$WebUiUrl/api/v1/configs/models" -Method POST `
  -Headers $auth -ContentType "application/json" `
  -Body (@{
    DEFAULT_MODELS = $ModelId
    DEFAULT_PINNED_MODELS = $null
    MODEL_ORDER_LIST = @($ModelId, "composer-2.5")
    DEFAULT_MODEL_METADATA = @{}
    DEFAULT_MODEL_PARAMS = @{}
  } | ConvertTo-Json -Depth 5) | Out-Null
Write-Host "Default model set to $ModelId"

Write-Host "Done. In Maya select model 'ERP Reports 65778' or attach knowledge '#$KnowledgeName'."
Write-Host "Default model is now $ModelId (RAG). Plain composer-2.5 has no report catalog unless you attach #knowledge."
