# Sync Maya: RAG knowledge, the four public models, skills, users.
# RAG: C:\Users\armin\TFS\rag-for-ai\reports\
#
# Models: exactly four, everything else stays hidden/disabled.
#   OpenRouter-Auto            -> openrouter/auto        (OpenRouter, OPENROUTER_API_KEY)
#   OpenCode-Mimo-v2.6-Flash   -> mimo-v2.6-flash        (OpenCode Go, OPENCODE_API_KEY)
#   OpenCode-DeepSeek-4.1-Flash-> deepseek-v4.1-flash    (OpenCode Go)
#   OpenCode-GPT-6-Luna        -> gpt-6-luna             (OpenCode Go, Responses API only)
# All four share the same RAG: knowledge (.md) + the ERP vector rows, and Qdrant
# holds exactly one collection ("maya") - see scripts/qdrant_merge_collections.py.

param(
  [string]$WebUiUrl = "http://127.0.0.1:3080",
  [string]$AdminEmail = "armin@local",
  [string]$AdminPassword = "dopadopa123",
  [string]$SharedPassword = "123456",
  [string]$RagDir = "C:\Users\armin\TFS\rag-for-ai\reports",
  [string]$KnowledgeName = "ERP Reports",
  # Keys come from the environment (never from .env / git).
  [string]$OpenRouterBaseUrl = "https://openrouter.ai/api/v1",
  [string]$OpenRouterKey = $env:OPENROUTER_API_KEY,
  # OpenCode Go serves chat/completions and - for some models - only /responses.
  [string]$OpenCodeBaseUrl = "https://opencode.ai/zen/go/v1",
  [string]$OpenCodeKey = $env:OPENCODE_API_KEY,
  # Go wants a stable session id per conversation; {{CHAT_ID}} is substituted
  # per request by Open WebUI (empty chat id -> "maya-").
  [string]$OpenCodeSession = "maya-{{CHAT_ID}}",
  [string]$QdrantUrl = "http://localhost:6333",
  [string]$QdrantCollection = "maya",
  # Re-embed the .md files (purges their vectors in Qdrant first). Off by default:
  # linking an already-linked file again duplicates chunks in the shared collection.
  [switch]$RefreshKnowledge,
  [string]$OllamaLocalUrl = "http://host.docker.internal:11434",
  [string]$OllamaServerUrl = "http://10.10.16.118:11434"
)

$ErrorActionPreference = "Stop"

if (-not $OpenRouterKey) { throw "OPENROUTER_API_KEY is not set in the environment" }
if (-not $OpenCodeKey) { throw "OPENCODE_API_KEY is not set in the environment" }

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
1) Prefer the injected system block "### ERP vector candidates (collection maya)" — that IS the vector search; treat it as done. Never emit fake tool-call XML.
2) Treat the listed rows as potential candidates (NameSystem + ParentSystemtxt).
3) Keep all relevant candidates; drop clear mismatches only.
4) All user-facing messages must be in Persian. Preserve report names, page paths, and URLs as provided by the source.
5) Reply with a Markdown table with exactly three Persian columns: نام گزارش, آدرس در صفحه, and پیوند.
   Use NameSystem as the report name and ParentSystemtxt as the page path/address. Put a clickable Persian link in پیوند using http://erp.dpdc.co:8880/<URL-encoded-ParentSystemtxt>, preserving / and - in the URL path. If ParentSystemtxt is missing, show آدرس موجود نیست and provide no link. Do not include score or employee.
6) Only answer within ERP report-finding and report-access scope. For unrelated requests, do not answer the topic; reply in Persian: «متأسفم، نمی‌توانم درباره این موضوع پاسخ بدهم؛ رئیسم، آرمین، اجازه نمی‌دهد، هرچند اطلاعات زیادی دارم.»
7) End every report response, including no-match responses, with «{نام کاربر} عزیز، آیا به کمک بیشتری نیاز دارید؟». Use the user's name from the conversation/profile when available; never guess a name. If unavailable, ask «آیا به کمک بیشتری نیاز دارید؟».
Optional: tool search_erp_report_access or reports-access-*.md / reports-index.md / reports.md only to confirm details when present — never invent rows. If neither candidates nor context exist, say so in Persian.
"@

# Display name -> workspace id -> base model id (OpenAI-compatible connection id).
# Optional System/Params keys override the shared RAG prompt/params per model.
$models = @(
  # OpenRouter meters by credits: an unbounded max_tokens (131k) is rejected when
  # the balance only covers ~37k, so cap the completion size on that model.
  @{ Id = "openrouter-auto"; Name = "OpenRouter-Auto"; Base = "openrouter/auto"; Kind = "openai"; Params = @{ max_tokens = 8192 } },
  @{ Id = "opencode-mimo-v2-6-flash"; Name = "OpenCode-Mimo-v2.6-Flash"; Base = "mimo-v2.6-flash"; Kind = "opencode" },
  @{ Id = "opencode-deepseek-4-1-flash"; Name = "OpenCode-DeepSeek-4.1-Flash"; Base = "deepseek-v4.1-flash"; Kind = "opencode" },
  @{ Id = "opencode-gpt-6-luna"; Name = "OpenCode-GPT-6-Luna"; Base = "gpt-6-luna"; Kind = "opencode" }
)

$users = @(
  @{ Name = "Shima Seifollahi"; Email = "s.seifollahi@ondpline.com"; Role = "user" },
  @{ Name = "Armin Dashti"; Email = "a.dashti@ondpline.com"; Role = "admin" },
  @{ Name = "Mozaffar Sabzevari"; Email = "m.sabzevari@ondpline.com"; Role = "user" },
  @{ Name = "Amin Bazri"; Email = "a.bazri@ondpline.com"; Role = "user" },
  @{ Name = "Ali Barati"; Email = "a.barati@ondpline.com"; Role = "user" },
  @{ Name = "MJ Amiri"; Email = "m.amiri@ondpline.com"; Role = "user" }
)

# One unified skill (the former Report Index First + Persian Title Match content
# folded into Find ERP Report).
$skills = @(
  @{
    Id = "find-erp-report"
    Name = "Find ERP Report"
    Description = "Locate ERP reports from the injected ERP vector candidates (collection maya) by Persian title, English page name, or menu path. Prefer injected candidates; use reports-index.md only as secondary confirm."
    # Single-quoted here-string: backticks in markdown must not be PowerShell escapes (`r = CR).
    Content = @'
# Find ERP Report

Order: injected ERP vector candidates first (counts as vector search), then .md files.

1. Prefer the system block "### ERP vector candidates (collection maya)". That IS the vector search - treat it as done. Never emit fake tool-call XML. Tool search_erp_report_access is optional for who-can-access only.
2. Treat listed NameSystem / ParentSystemtxt rows as candidates; keep all relevant ones, drop clear mismatches only.
3. **reports-index.md** / **reports.md** are secondary confirmation only, and only when needed - never invent rows from them.
4. Persian titles: answer from the injected candidates (semantic match absorbs spelling and kashida variations). Also accept English page names (e.g. CustomerCreditIncreaseReport).
5. If nothing matches, say so - do not invent report names or titles that are not in the candidates. Never refuse solely because you did not invoke a tool when candidates are already present.
6. Only answer within ERP report-finding and report-access scope. For unrelated requests, do not answer the topic; reply in Persian: «متأسفم، نمی‌توانم درباره این موضوع پاسخ بدهم؛ رئیسم، آرمین، اجازه نمی‌دهد، هرچند اطلاعات زیادی دارم.»
7. All user-facing messages must be in Persian. Preserve report names, page paths, and URLs as provided by the source.
8. Reply with a Markdown table with exactly three Persian columns: نام گزارش, آدرس در صفحه, and پیوند.
   Use NameSystem as the report name and ParentSystemtxt as the page path/address. Put a clickable Persian link in پیوند using http://erp.dpdc.co:8880/<URL-encoded-ParentSystemtxt>, preserving / and - in the URL path. If ParentSystemtxt is missing, show آدرس موجود نیست and provide no link. Do not include score or employee.
9. End every report response, including no-match responses, with «{نام کاربر} عزیز، آیا به کمک بیشتری نیاز دارید؟». Use the user's name from the conversation/profile when available; never guess a name. If unavailable, ask «آیا به کمک بیشتری نیاز دارید؟».
'@
  }
)

# Skills retired by the merge; deleted after the upsert loop so only the unified one stays.
$legacySkillIds = @("report-index-first", "persian-title-match")

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
# 1) OpenRouter            -> openrouter/auto          (chat/completions)
# 2) OpenCode Go           -> mimo/deepseek            (chat/completions)
# 3) OpenCode Go           -> gpt-6-luna               (Responses API only)
# OpenCode Go wants a stable x-opencode-session per conversation and a
# non-SDK user agent; both are connection headers ({{CHAT_ID}} is substituted
# per request by Open WebUI).
$openCodeHeaders = @{
  "x-opencode-session" = $OpenCodeSession
  "User-Agent" = "maya-openwebui/1.0"
}
Invoke-Json POST "$WebUiUrl/openai/config/update" $auth @{
  ENABLE_OPENAI_API = $true
  OPENAI_API_BASE_URLS = @($OpenRouterBaseUrl, $OpenCodeBaseUrl, $OpenCodeBaseUrl)
  OPENAI_API_KEYS = @($OpenRouterKey, $OpenCodeKey, $OpenCodeKey)
  OPENAI_API_CONFIGS = @{
    "0" = @{
      enable = $true
      tags = @(@{ name = "openrouter" })
      connection_type = "external"
      auth_type = "bearer"
      prefix_id = ""
      model_ids = @("openrouter/auto")
    }
    "1" = @{
      enable = $true
      tags = @(@{ name = "opencode-go" })
      connection_type = "external"
      auth_type = "bearer"
      prefix_id = ""
      model_ids = @("mimo-v2.6-flash", "deepseek-v4.1-flash")
      headers = $openCodeHeaders
    }
    "2" = @{
      enable = $true
      tags = @(@{ name = "opencode-go" })
      connection_type = "external"
      auth_type = "bearer"
      prefix_id = ""
      api_type = "responses"
      model_ids = @("gpt-6-luna")
      headers = $openCodeHeaders
    }
  }
} | Out-Null
Write-Host "Connections: openrouter/auto + opencode-go chat (mimo, deepseek) + opencode-go responses (gpt-6-luna)"

# Ollama stays configured for later, but disabled - it must not add models.
Invoke-Json POST "$WebUiUrl/ollama/config/update" $auth @{
  ENABLE_OLLAMA_API = $false
  OLLAMA_BASE_URLS = @($OllamaLocalUrl, $OllamaServerUrl)
  OLLAMA_API_CONFIGS = @{
    "0" = @{ enable = $false; prefix_id = "local"; connection_type = "local"; model_ids = @() }
    "1" = @{ enable = $false; prefix_id = "server"; connection_type = "external"; model_ids = @() }
  }
} | Out-Null
Write-Host "Ollama connection disabled (host=$OllamaLocalUrl server=$OllamaServerUrl kept for later)"

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

# Every public model gets the whole vector store: all knowledge bases (the .md
# files live in there), so all four models reach the vector DB and the .md docs.
$allKnowledge = @((Invoke-Json GET "$WebUiUrl/api/v1/knowledge/" $auth $null).items) |
  ForEach-Object { @{ id = $_.id; name = $_.name; type = "collection" } }
Write-Host ("Knowledge attached to every model: " + (($allKnowledge | ForEach-Object { $_.name }) -join ", "))

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

# Link the .md files ONCE. Re-adding an already-linked file makes Open WebUI
# re-embed it while file/remove leaves the old chunks behind, so every run used
# to duplicate vectors in the shared collection. Linked files are skipped
# unless -RefreshKnowledge is passed, which purges the knowledge/file tenants
# in Qdrant first so the re-embed starts from a clean slate.
# The knowledge detail route returns files=null in this build, so read the
# authoritative /files route (same as scripts/sync_maya_reports_access.py) -
# with $detail.files the map stayed empty and every run re-added (re-embedded)
# the files, duplicating their vectors in the shared collection.
$linkedResp = Invoke-Json GET "$WebUiUrl/api/v1/knowledge/$kbId/files" $auth $null
$linkedByName = @{}
foreach ($existing in @($linkedResp.items)) {
  if ($existing.meta -and $existing.meta.name) { $linkedByName[$existing.meta.name] = $existing.id }
}

if ($RefreshKnowledge) {
  foreach ($name in $wantedNames) {
    if ($linkedByName.ContainsKey($name)) {
      try {
        Invoke-Json POST "$WebUiUrl/api/v1/knowledge/$kbId/file/remove" $auth @{ file_id = $linkedByName[$name] } | Out-Null
        Write-Host "Removed $name (refresh)"
      } catch {
        Write-Warning "Could not remove $name : $($_.Exception.Message)"
      }
    }
  }
  $staleTenants = @($kbId) + @($linkedByName.Values | ForEach-Object { "file-$_" })
  foreach ($tenant in $staleTenants) {
    try {
      $purge = @{ filter = @{ must = @(@{ key = "tenant_id"; match = @{ value = $tenant } }) } } | ConvertTo-Json -Depth 6
      Invoke-RestMethod -Uri "$QdrantUrl/collections/$QdrantCollection/points/delete?wait=true" `
        -Method Post -ContentType "application/json" -Body $purge | Out-Null
      Write-Host "Purged stale vectors of tenant $tenant"
    } catch {
      Write-Warning "Purge of tenant $tenant failed: $($_.Exception.Message)"
    }
  }
  $linkedByName.Clear()
}

$linkedFileIds = @()
foreach ($path in $files) {
  $name = [IO.Path]::GetFileName($path)
  if ($linkedByName.ContainsKey($name)) {
    Write-Host "Already linked: $name ($($linkedByName[$name]))"
    $linkedFileIds += $linkedByName[$name]
    continue
  }

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

# --- retire skills folded into find-erp-report (best-effort) ---
$keepSkillIds = @($skills | ForEach-Object { $_.Id })
foreach ($legacyId in $legacySkillIds) {
  if ($keepSkillIds -contains $legacyId) { continue }
  try {
    Invoke-Json DELETE "$WebUiUrl/api/v1/skills/id/$legacyId/delete" $auth $null | Out-Null
    Write-Host "Removed merged skill $legacyId"
  } catch {
    Write-Host "Skill $legacyId not present (ok)"
  }
}

# --- models ---
function Upsert-WorkspaceModel($m) {
  $meta = @{
    description = "$($m.Name) + shared RAG ($KnowledgeName). Base=$($m.Base)"
    hidden = $false
    knowledge = $(if (@($allKnowledge).Count -gt 0) { @($allKnowledge) } else { @(@{ id = $kbId; name = $KnowledgeName; type = "collection" }) })
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
  # /base only lists provider models; /export lists every stored row (workspace
  # presets included) - those are the ones that must be hidden + deactivated.
  # Invoke-Json hands back the JSON array as ONE object, so @(call) would wrap
  # it into a 1-element array holding the whole list (and the loop would run
  # once with an array as $row -> 422). Assign first, wrap afterwards.
  $allBase = Invoke-Json GET "$WebUiUrl/api/v1/models/export" $auth $null
  $allBase = @($allBase)
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

# Auxiliary LLM calls (titles, tags, follow-ups, search queries) run on the cheap
# Mimo model - Ollama is disabled, so the task model must be one of the four.
Invoke-Json POST "$WebUiUrl/api/v1/configs/import" $auth @{
  config = @{ "task.model.default" = "opencode-mimo-v2-6-flash" }
} | Out-Null
Write-Host "Task model: opencode-mimo-v2-6-flash"

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

# --- verify: exactly one Qdrant collection ---
try {
  $cols = @((Invoke-RestMethod -Uri "$QdrantUrl/collections" -TimeoutSec 15).result.collections |
    ForEach-Object { $_.name })
  if ($cols.Count -eq 1 -and $cols[0] -eq $QdrantCollection) {
    Write-Host "Qdrant: exactly one collection '$QdrantCollection'"
  } else {
    Write-Warning ("Qdrant has " + $cols.Count + " collections [" + ($cols -join ", ") +
      "]; expected only '$QdrantCollection'. Merge with python scripts/qdrant_merge_collections.py --delete-sources")
  }
} catch {
  Write-Warning "Qdrant collection check failed: $($_.Exception.Message)"
}

# --- verify: exactly the four public models ---
try {
  $visible = @(Invoke-Json GET "$WebUiUrl/api/v1/models" $auth $null).data | ForEach-Object { $_.id }
  $visible = @($visible)
  # The provider base rows stay active (routing needs them) but are meta.hidden,
  # which is what the model picker filters on - so they are allowed to exist.
  $allowed = @($models | ForEach-Object { $_.Id }) + @($models | ForEach-Object { $_.Base })
  $extra = @($visible | Where-Object { $allowed -notcontains $_ })
  if ($visible.Count -eq 0) {
    Write-Warning "Model list is empty - provider check failed (connections unreachable?)"
  } elseif ($extra.Count -gt 0) {
    Write-Warning ("Unexpected models still visible: " + ($extra -join ", "))
  } else {
    Write-Host ("Visible models (" + $visible.Count + "): " + ($visible -join ", "))
  }
} catch {
  Write-Warning "Model visibility check failed: $($_.Exception.Message)"
}

Write-Host "Done. Models + RAG + skills + users ready."
Write-Host "  UI: http://maya.local/"
Write-Host "  Path bookmarks: http://pc-armin/maya  http://10.20.9.59/maya  (302 -> http://maya.local/)"
Write-Host "  Models: OpenRouter-Auto, OpenCode-Mimo-v2.6-Flash, OpenCode-DeepSeek-4.1-Flash, OpenCode-GPT-6-Luna"
Write-Host "  RAG: knowledge (.md) attached to every model + ERP rows injected by global filter erp_reports_inject (collection '$QdrantCollection')."
Write-Host "  Vectors: one Qdrant collection only - scripts/qdrant_merge_collections.py merges strays back in."
