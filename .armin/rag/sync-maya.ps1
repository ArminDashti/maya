# Sync Maya: RAG knowledge, public models, skills, users.
# RAG: C:\Users\armin\TFS\rag-for-ai\reports\
# OpenAI: cursor-sdk-to-openai /v1 (OpenAI-compatible; headless is not)
# Ollama local: host.docker.internal:11434  |  server: 10.10.16.118:11434

param(
  [string]$WebUiUrl = "http://127.0.0.1:3080",
  [string]$AdminEmail = "armin@local",
  [string]$AdminPassword = "dopadopa123",
  [string]$SharedPassword = "123456",
  [string]$RagDir = "C:\Users\armin\TFS\rag-for-ai\reports",
  [string]$KnowledgeName = "ERP Reports",
  [string]$OpenAiBaseUrl = "http://cursor-sdk-to-openai-api-1:8140/v1",
  [string]$OpenAiKey = "local",
  # Maya container → openrouter-api on pc-armin-local
  [string]$OpenRouterBaseUrl = "http://openrouter-api:8080/v1",
  # Sync host → nginx hostname (for listing free display ids)
  [string]$OpenRouterHostUrl = "http://openrouter-to-openai-compatible-api.local/v1",
  [string]$OpenRouterKey = "local",
  [string]$OllamaLocalUrl = "http://host.docker.internal:11434",
  [string]$OllamaServerUrl = "http://10.10.16.118:11434"
)

$ErrorActionPreference = "Stop"

$wantedNames = @("reports-index.md", "reports.md")
$files = @(
  (Join-Path $RagDir "reports-index.md"),
  (Join-Path $RagDir "reports.md")
)
foreach ($f in $files) {
  if (-not (Test-Path -LiteralPath $f)) { throw "Missing RAG file: $f" }
}

$ragSystem = @"
You are Maya's ERP report finder.
Retrieval order (do not skip or invent):
1) Prefer the injected system block "### ERP vector candidates (collection erp_reports)" — that IS the vector search; treat it as done. Never emit fake tool-call XML.
2) Treat the listed rows as potential candidates (NameSystem + ParentSystemtxt).
3) Keep all relevant candidates; drop clear mismatches only.
4) Reply with a markdown table whose only columns are NameSystem and ParentSystemtxt. No other columns.
Optional: tool search_erp_report_access or reports-access-*.md / reports-index.md / reports.md only to confirm details when present — never invent rows. If neither candidates nor context exist, say no matching rows. Answer in the user's language.
"@

# SmolLM2-360M: vector search -> collect candidates -> pick the best ones.
$smolmSystem = @"
You are Maya's ERP report finder and candidate selector.
Your responsibility, in this exact order:
1) Prefer the injected system block "### ERP vector candidates (collection erp_reports)" (that IS the vector search). Never emit fake tool-call XML.
2) Candidates: use every NameSystem / ParentSystemtxt row from that block that could match the question.
3) Keep all relevant candidates; drop clear mismatches only.
4) Reply with a markdown table whose only columns are NameSystem and ParentSystemtxt.
Never invent. If no candidate matches, say so. Answer in the user's language.
"@

# SmolLM2-1.7B: vector candidates -> choose relevant -> write final table.
$smolm17System = @"
You are Maya's ERP report finder and candidate selector (rerank pipeline).
Your responsibility, in this exact order (do not skip or reorder steps):
1) Get candidates: prefer the injected system block "### ERP vector candidates (collection erp_reports)" (that IS the vector search). Never emit fake tool-call XML. Collect every NameSystem / ParentSystemtxt row that could match.
2) Rerank them: score each candidate against the user's question (title match, menu-path relevance, spelling/kashida variants). Sort strongest first; drop obvious mismatches.
3) Choose from the reranked items: keep all relevant rows (or say none match). Prefer higher ranks unless a lower rank clearly fits better.
4) Write final results: reply with a markdown table whose only columns are NameSystem and ParentSystemtxt. Never invent. Answer in the user's language. If no candidate matches, say so.
"@

# Display name -> workspace id -> base model id (after Ollama prefix / OpenAI id)
# Optional System/Params keys override the shared RAG prompt/params per model.
$models = @(
  @{ Id = "cursor-headless-cli-auto"; Name = "Cursor-Headless-CLI-Auto"; Base = "auto"; Kind = "openai" },
  @{ Id = "local-armin-gemma-4-e4b"; Name = "Local-Armin-Gemma-4-e4b"; Base = "local.gemma4:e4b"; Kind = "ollama" },
  @{ Id = "local-armin-qwen-2.5-2b"; Name = "Local-Armin-Qwen-2.5-2B"; Base = "local.qwen2.5:3b"; Kind = "ollama" },
  @{ Id = "server-gemma-4-e4b"; Name = "Server-Gemma-4-e4b"; Base = "server.gemma4:e4b"; Kind = "ollama" },
  @{ Id = "server-qwen-2.5-2b"; Name = "Server-Qwen-2.5-2b"; Base = "server.qwen2.5:3b"; Kind = "ollama" },
  @{ Id = "local-armin-smollm2-360m"; Name = "Local-Armin-SmolLM2-360M"; Base = "local.smollm2:360m"; Kind = "ollama"; System = $smolmSystem; Params = @{ num_ctx = 8192 } },
  @{ Id = "local-armin-smollm2-1.7b"; Name = "Local-Armin-SmolLM2-1.7B"; Base = "local.smollm2:1.7b"; Kind = "ollama"; System = $smolm17System; Params = @{ num_ctx = 8192 } }
)

$users = @(
  @{ Name = "Shima Seifollahi"; Email = "s.seifollahi@ondpline.com"; Role = "user" },
  @{ Name = "Armin Dashti"; Email = "a.dashti@ondpline.com"; Role = "admin" },
  @{ Name = "Mozaffar Sabzevari"; Email = "m.sabzevari@ondpline.com"; Role = "user" },
  @{ Name = "Amin Bazri"; Email = "a.bazri@ondpline.com"; Role = "user" },
  @{ Name = "Ali Barati"; Email = "a.barati@ondpline.com"; Role = "user" },
  @{ Name = "MJ Amiri"; Email = "m.amiri@ondpline.com"; Role = "user" }
)

$skills = @(
  @{
    Id = "find-erp-report"
    Name = "Find ERP Report"
    Description = "Locate ERP reports from Maya erp_reports vector candidates by Persian title, English page name, or menu path."
    # Single-quoted here-string: backticks in markdown must not be PowerShell escapes (`r = CR).
    Content = @'
# Find ERP Report

Order: injected ERP vector candidates first (counts as vector search), then .md files.

1. Prefer the system block "### ERP vector candidates (collection erp_reports)". Do not emit fake tool-call XML. Tool search_erp_report_access is optional for who-can-access only.
2. Treat listed NameSystem / ParentSystemtxt rows as candidates; keep all relevant ones.
3. Reply with a markdown table whose only columns are NameSystem and ParentSystemtxt.
4. If nothing matches, say so - do not invent report names. Never refuse solely because you did not invoke a tool when candidates are already present.
'@
  },
  @{
    Id = "report-index-first"
    Name = "Report Index First"
    Description = "Prefer injected erp_reports candidates; use reports-index.md only as secondary confirm."
    Content = @'
# Report Index First

When the user asks for a report:
- Step 1: use the injected "### ERP vector candidates (collection erp_reports)" block (that counts as the vector search). Never emit fake tool-call XML.
- Step 2: optional confirm via **reports-index.md** / **reports.md** only if needed; final answer stays the NameSystem / ParentSystemtxt table.
- Answer from injected candidates when present; do not refuse for missing a personal tool call.
'@
  },
  @{
    Id = "persian-title-match"
    Name = "Persian Title Match"
    Description = "Match Persian report titles and transliterations from erp_reports candidates."
    Content = @'
# Persian Title Match

Users often ask in Persian: use the injected erp_reports candidates (semantic match absorbs spelling and kashida variations).
Also accept English page names (e.g. CustomerCreditIncreaseReport).
Final answer: markdown table with columns NameSystem and ParentSystemtxt only. Never invent titles not present in the candidates.
'@
  }
)

function Invoke-Json {
  param([string]$Method, [string]$Uri, [hashtable]$Headers, $Body)
  $params = @{ Uri = $Uri; Method = $Method; Headers = $Headers }
  if ($null -ne $Body) {
    $params.ContentType = "application/json; charset=utf-8"
    $json = if ($Body -is [string]) { $Body } else { $Body | ConvertTo-Json -Depth 12 }
    $params.Body = [System.Text.Encoding]::UTF8.GetBytes($json)
  }
  return Invoke-RestMethod @params
}

# --- auth (try shared password first, then legacy bootstrap) ---
$token = $null
foreach ($pw in @($SharedPassword, $AdminPassword, "dopadopa123", "123456")) {
  try {
    $signin = Invoke-Json POST "$WebUiUrl/api/v1/auths/signin" @{} @{ email = $AdminEmail; password = $pw }
    $token = $signin.token
    $AdminPassword = $pw
    Write-Host "Signed in as $AdminEmail"
    break
  } catch { }
}
if (-not $token) { throw "Could not sign in as $AdminEmail" }
$auth = @{ Authorization = "Bearer $token"; Accept = "application/json" }

# --- providers ---
Invoke-Json POST "$WebUiUrl/openai/config/update" $auth @{
  ENABLE_OPENAI_API = $true
  OPENAI_API_BASE_URLS = @($OpenAiBaseUrl, $OpenRouterBaseUrl)
  OPENAI_API_KEYS = @($OpenAiKey, $OpenRouterKey)
  OPENAI_API_CONFIGS = @{
    "0" = @{
      enable = $true
      tags = @(@{ name = "cursor-sdk-to-openai" })
      connection_type = "external"
      auth_type = "bearer"
      prefix_id = ""
      # Only expose Auto for the Cursor-Headless-CLI-Auto workspace model
      model_ids = @("auto")
    }
    "1" = @{
      enable = $true
      tags = @(@{ name = "openrouter-free" })
      connection_type = "external"
      auth_type = "bearer"
      prefix_id = ""
      # Proxy already filters to OpenRouter-*-Free ids; empty = all from that connection
      model_ids = @()
    }
  }
} | Out-Null
Write-Host "OpenAI -> $OpenAiBaseUrl (auto) + $OpenRouterBaseUrl (free only)"

Invoke-Json POST "$WebUiUrl/ollama/config/update" $auth @{
  ENABLE_OLLAMA_API = $true
  OLLAMA_BASE_URLS = @($OllamaLocalUrl, $OllamaServerUrl)
  OLLAMA_API_CONFIGS = @{
    "0" = @{
      enable = $true
      prefix_id = "local"
      connection_type = "local"
      model_ids = @("gemma4:e4b", "qwen2.5:3b", "smollm2:360m", "smollm2:1.7b")
    }
    "1" = @{
      enable = $true
      prefix_id = "server"
      connection_type = "external"
      model_ids = @("gemma4:e4b", "qwen2.5:3b")
    }
  }
} | Out-Null
Write-Host "Ollama local=$OllamaLocalUrl server=$OllamaServerUrl"

# --- knowledge ---
$kbList = Invoke-Json GET "$WebUiUrl/api/v1/knowledge/" $auth $null
$kb = @($kbList.items) | Where-Object { $_.name -eq $KnowledgeName } | Select-Object -First 1
if (-not $kb) {
  $kb = Invoke-Json POST "$WebUiUrl/api/v1/knowledge/create" $auth @{
    name = $KnowledgeName
    description = "ERP report catalog. Synced from $RagDir"
  }
  Write-Host "Created knowledge $($kb.id)"
} else {
  Write-Host "Using knowledge $($kb.id)"
}
$kbId = $kb.id

function Get-OpenWebUiFiles {
  return @((Invoke-Json GET "$WebUiUrl/api/v1/files/" $auth $null).items)
}

function Find-FileByName([string]$name) {
  $matches = @(Get-OpenWebUiFiles | Where-Object {
    $_.filename -eq $name -or ($_.meta -and $_.meta.name -eq $name)
  })
  foreach ($candidate in $matches) {
    try {
      $st = Invoke-Json GET "$WebUiUrl/api/v1/files/$($candidate.id)/process/status" $auth $null
      if ($st.status -eq "completed") { return $candidate }
    } catch { }
  }
  return $null
}

function Wait-FileProcessed([string]$fileId) {
  for ($i = 0; $i -lt 180; $i++) {
    $st = Invoke-Json GET "$WebUiUrl/api/v1/files/$fileId/process/status" $auth $null
    if ($st.status -eq "completed") { return }
    if ($st.status -eq "failed") { throw "Processing failed for $fileId" }
    Start-Sleep -Seconds 2
  }
  throw "Timed out processing $fileId"
}

function Add-FileToKnowledge([string]$fileId, [string]$name) {
  try {
    Invoke-Json POST "$WebUiUrl/api/v1/knowledge/$kbId/file/add" $auth @{ file_id = $fileId } | Out-Null
    Write-Host "Linked $name"
  } catch {
    $msg = $_.ErrorDetails.Message
    if ($msg -match "Duplicate content") {
      Write-Host "Already in knowledge: $name"
    } else { throw }
  }
}

$detail = Invoke-Json GET "$WebUiUrl/api/v1/knowledge/$kbId" $auth $null
foreach ($existing in @($detail.files)) {
  $name = $null
  if ($existing.meta) { $name = $existing.meta.name }
  if ($name -in $wantedNames) {
    try {
      Invoke-Json POST "$WebUiUrl/api/v1/knowledge/$kbId/file/remove" $auth @{ file_id = $existing.id } | Out-Null
      Write-Host "Removed old $name"
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
    Write-Host "Reusing $name ($($existing.id))"
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

Invoke-Json POST "$WebUiUrl/api/v1/knowledge/$kbId/update" $auth @{
  name = $KnowledgeName
  description = "ERP report catalog. Synced from $RagDir"
  data = @{ file_ids = $linkedFileIds }
} | Out-Null

$verifyFiles = Invoke-Json GET "$WebUiUrl/api/v1/knowledge/$kbId/files" $auth $null
$fileCount = @($verifyFiles.items).Count
Write-Host "Knowledge files: $fileCount"
if ($fileCount -lt 1) { throw "Knowledge has no files after sync" }

Invoke-Json POST "$WebUiUrl/api/v1/knowledge/$kbId/access/update" $auth @{
  id = $kbId
  access_grants = @(
    @{ principal_type = "user"; principal_id = "*"; permission = "read" }
  )
} | Out-Null
Write-Host "Knowledge public read: $KnowledgeName"

# --- skills ---
$skillIds = @()
foreach ($sk in $skills) {
  $body = @{
    id = $sk.Id
    name = $sk.Name
    description = $sk.Description
    content = $sk.Content
    meta = @{ tags = @() }
    is_active = $true
    access_grants = @(
      @{ principal_type = "user"; principal_id = "*"; permission = "read" }
    )
  }
  try {
    $existingSkill = $null
    try {
      $existingSkill = Invoke-Json GET "$WebUiUrl/api/v1/skills/id/$($sk.Id)" $auth $null
    } catch { }
    if ($existingSkill -and $existingSkill.id) {
      Invoke-Json POST "$WebUiUrl/api/v1/skills/id/$($sk.Id)/update" $auth $body | Out-Null
      Write-Host "Updated skill $($sk.Id)"
    } else {
      Invoke-Json POST "$WebUiUrl/api/v1/skills/create" $auth $body | Out-Null
      Write-Host "Created skill $($sk.Id)"
    }
  } catch {
    Write-Warning "Skill $($sk.Id): $($_.Exception.Message)"
  }
  $skillIds += $sk.Id
  try {
    Invoke-Json POST "$WebUiUrl/api/v1/skills/id/$($sk.Id)/access/update" $auth @{
      id = $sk.Id
      access_grants = @(
        @{ principal_type = "user"; principal_id = "*"; permission = "read" }
      )
    } | Out-Null
  } catch { }
}

# --- models ---
# Append OpenRouter free display models (same RAG as Cursor-Headless-CLI-Auto)
try {
  $orList = Invoke-RestMethod -Uri "$OpenRouterHostUrl/models" -Headers @{
    Authorization = "Bearer $OpenRouterKey"
    Accept = "application/json"
  }
  $orRows = @()
  foreach ($row in @($orList.data)) {
    $disp = [string]$row.id
    if ([string]::IsNullOrWhiteSpace($disp)) { continue }
    if ($disp -notlike "OpenRouter-*-Free") { continue }
    $slug = ($disp.ToLower() -replace "[^a-z0-9]+", "-").Trim("-")
    $orRows += @{ Id = $slug; Name = $disp; Base = $disp; Kind = "openai-openrouter" }
  }
  if ($orRows.Count -gt 0) {
    $models = @($models) + $orRows
    Write-Host "OpenRouter free models + RAG: $($orRows.Count)"
  } else {
    Write-Warning "OpenRouter /models returned no OpenRouter-*-Free ids (rebuild proxy?)"
  }
} catch {
  Write-Warning "OpenRouter models fetch failed ($OpenRouterHostUrl): $($_.Exception.Message)"
}

function Upsert-WorkspaceModel($m) {
  $meta = @{
    description = "$($m.Name) + shared RAG ($KnowledgeName). Base=$($m.Base)"
    hidden = $false
    knowledge = @(@{ id = $kbId; name = $KnowledgeName; type = "collection" })
    skillIds = $skillIds
  }
  $params = @{
    function_calling = "legacy"
    system = $(if ($m.System) { $m.System } else { $ragSystem })
  }
  if ($m.Params) { foreach ($key in $m.Params.Keys) { $params[$key] = $m.Params[$key] } }
  $body = @{
    id = $m.Id
    name = $m.Name
    base_model_id = $m.Base
    meta = $meta
    params = $params
    access_grants = @(
      @{ principal_type = "user"; principal_id = "*"; permission = "read" }
    )
    is_active = $true
  }

  try {
    $row = Invoke-Json GET "$WebUiUrl/api/v1/models/model?id=$([uri]::EscapeDataString($m.Id))" $auth $null
  } catch { $row = $null }

  if ($row -and $row.id) {
    Invoke-Json POST "$WebUiUrl/api/v1/models/model/update" $auth $body | Out-Null
    Write-Host "Updated model $($m.Name)"
  } else {
    try {
      Invoke-Json POST "$WebUiUrl/api/v1/models/create" $auth $body | Out-Null
      Write-Host "Created model $($m.Name)"
    } catch {
      Invoke-Json POST "$WebUiUrl/api/v1/models/model/update" $auth $body | Out-Null
      Write-Host "Upserted model $($m.Name)"
    }
  }
}

function Set-BaseModelVisible([string]$modelId, [bool]$hidden, [bool]$active) {
  try {
    $row = Invoke-Json GET "$WebUiUrl/api/v1/models/model?id=$([uri]::EscapeDataString($modelId))" $auth $null
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
    }
    Invoke-Json POST "$WebUiUrl/api/v1/models/model/update" $auth $body | Out-Null
    Write-Host "Base $modelId active=$active hidden=$hidden"
  } catch {
    Write-Host "Base missing (ok): $modelId"
  }
}

foreach ($m in $models) {
  Upsert-WorkspaceModel $m
  # Ensure base row exists: active + public read + hidden from picker (OWUI 0.11+)
  $baseBody = @{
    id = $m.Base
    name = $m.Base
    base_model_id = $null
    meta = @{ hidden = $true; description = "Hidden base for $($m.Name)" }
    params = @{}
    access_grants = @(@{ principal_type = "user"; principal_id = "*"; permission = "read" })
    is_active = $true
  }
  try {
    Invoke-Json POST "$WebUiUrl/api/v1/models/model/update" $auth $baseBody | Out-Null
  } catch {
    try {
      Invoke-Json POST "$WebUiUrl/api/v1/models/create" $auth $baseBody | Out-Null
    } catch {
      Write-Warning "Base upsert $($m.Base): $($_.Exception.Message)"
    }
  }
  Set-BaseModelVisible $m.Base $true $true
}

# Hide leftover raw tags / old models from picker
foreach ($otherId in @(
  "pc-armin/maya", "pc-armin/maya:latest", "pc-armin/qwen",
  "gemma4:e4b", "qwen2.5:3b", "erp-reports-65778",
  "local.pc-armin/maya:latest", "server.pc-armin/maya:latest",
  "server.deepseek-r1:14b"
)) {
  Set-BaseModelVisible $otherId $true $false
}

# Hide every other stored model not in the public Maya set (keep required bases active)
$keepIds = @($models | ForEach-Object { $_.Id })
$requiredBases = @($models | ForEach-Object { $_.Base })
try {
  $allBase = @(Invoke-Json GET "$WebUiUrl/api/v1/models/base" $auth $null)
  foreach ($row in $allBase) {
    if ($keepIds -contains $row.id) { continue }
    $meta = @{}
    if ($row.meta) { $row.meta.PSObject.Properties | ForEach-Object { $meta[$_.Name] = $_.Value } }
    $meta["hidden"] = $true
    $active = $requiredBases -contains $row.id
    $body = @{
      id = $row.id
      name = $row.name
      base_model_id = $row.base_model_id
      meta = $meta
      params = $row.params
      access_grants = @(@{ principal_type = "user"; principal_id = "*"; permission = "read" })
      is_active = $active
    }
    try {
      Invoke-Json POST "$WebUiUrl/api/v1/models/model/update" $auth $body | Out-Null
    } catch { }
  }
  Write-Host "Hidden non-Maya models (bases kept active where required)"
} catch {
  Write-Warning "Bulk hide skipped: $($_.Exception.Message)"
}

$order = @($models | ForEach-Object { $_.Id })
Invoke-Json POST "$WebUiUrl/api/v1/configs/models" $auth @{
  DEFAULT_MODELS = $order[0]
  DEFAULT_PINNED_MODELS = $null
  MODEL_ORDER_LIST = $order
  DEFAULT_MODEL_METADATA = @{}
  DEFAULT_MODEL_PARAMS = @{}
} | Out-Null
Write-Host "Default model $($order[0]); order=$($order -join ', ')"

# --- users ---
foreach ($u in $users) {
  try {
    Invoke-Json POST "$WebUiUrl/api/v1/auths/add" $auth @{
      name = $u.Name
      email = $u.Email
      password = $SharedPassword
      role = $u.Role
      profile_image_url = "/user.png"
    } | Out-Null
    Write-Host "Created user $($u.Email) role=$($u.Role)"
  } catch {
    $msg = "$($_.Exception.Message) $($_.ErrorDetails.Message)"
    if ($msg -match "taken|exist|already|EMAIL") {
      Write-Host "User exists: $($u.Email)"
    } else {
      Write-Warning "User $($u.Email): $msg"
    }
  }
}

# Set shared password on bootstrap admin (best-effort)
try {
  Invoke-Json POST "$WebUiUrl/api/v1/auths/update/password" $auth @{
    password = $AdminPassword
    new_password = $SharedPassword
  } | Out-Null
  Write-Host "Updated admin password for $AdminEmail -> shared"
  $AdminPassword = $SharedPassword
} catch {
  Write-Warning "Could not change $AdminEmail password (may already be shared): $($_.Exception.Message)"
}

Write-Host "Done. Models + RAG + skills + users ready."
Write-Host "  UI: http://maya.local/"
Write-Host "  Path bookmarks: http://pc-armin/maya  http://10.20.9.59/maya  (302 -> http://maya.local/)"
Write-Host "  Note: Qwen display names say 2B; installed Ollama tag is qwen2.5:3b on both hosts."
Write-Host "  Note: Cursor-Headless-CLI-Auto uses cursor-sdk-to-openai -> auto (OpenAI-compat). Headless CLI API is not /v1 chat."
Write-Host "  Note: OpenRouter free models via openrouter-api:8080 (OpenRouter-*-Free + Auto-Free) share ERP RAG; erp_reports hits come from global filter erp_reports_inject (run python scripts/sync_maya_reports_access.py)."
