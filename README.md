# Maya

Local **Open WebUI** chatbot branded **Maya**, at [http://maya.local/](http://maya.local/), with dual Ollama + OpenAI-compatible Cursor models and shared ERP RAG.

| Piece | Source |
|-------|--------|
| UI | Official image `ghcr.io/open-webui/open-webui` ([docs](https://docs.openwebui.com/getting-started/quick-start/), [repo](https://github.com/open-webui/open-webui)) |
| LLM providers | Local Ollama (`host.docker.internal:11434`) + server Ollama (`10.10.16.118:11434`) + OpenAI-compatible `cursor-sdk-to-openai` |
| Entry | [nginx-local](https://github.com/ArminDashti/nginx-local) serves `http://maya.local/` on port 80; `/maya` bookmarks 302 → `maya.local` (never `:3080`) |

## Prerequisites

1. Docker Desktop running
2. Host Ollama with `gemma4:e4b` and `qwen2.5:3b` (also on `10.10.16.118`)
3. External network `pc-armin-local`
4. `cursor-sdk-to-openai` stack up on `pc-armin-local` (Gemini 3.8)
5. `nginx-gateway` (restart unless-stopped) for `http://maya.local/` and `/maya` → `maya.local`

## Quick start

```powershell
cd C:\Users\armin\GitHub\maya
copy .env.example .env
# Set OPENAI_API_KEY from cursor-sdk-to-openai-api AUTH_KEY if set; else leave "local"

.\scripts\install-local-docker.ps1
.\.armin\rag\sync-maya.ps1
```

| URL | Notes |
|-----|--------|
| http://maya.local/ | Canonical URL (nginx :80 → container) |
| http://pc-armin/maya | Bookmark; 302 → `http://maya.local/` |
| http://10.20.9.59/maya | Bookmark; 302 → `http://maya.local/` |
| http://127.0.0.1:3080/ | Direct publish port (debug only) |

Stack: `maya` · container: `maya-openwebui` · update keeps volumes/DB.

Shared password for seeded users + bootstrap admin: `123456`.

## Models (all users)

| Picker name | Backend |
|-------------|---------|
| Cursor-Gemini-3.8 | `cursor-sdk-to-openai` → `gemini-3.8-flash` |
| Local-Armin-Gemma-4-e4b | local Ollama `gemma4:e4b` |
| Local-Armin-Qwen-2.5-2B | local Ollama `qwen2.5:3b` (installed tag; no 2b on hosts) |
| Server-Gemma-4-e4b | server Ollama `gemma4:e4b` @ 10.10.16.118 |
| Server-Qwen-2.5-2b | server Ollama `qwen2.5:3b` @ 10.10.16.118 |

All five share Knowledge **ERP Reports** from `C:\Users\armin\TFS\rag-for-ai\reports\` (`reports-index.md`, `reports.md`) plus Skills: Find ERP Report, Report Index First, Persian Title Match.

Re-sync after RAG or user changes:

```powershell
.\.armin\rag\sync-maya.ps1
```

## OpenAI-compatible provider

Maya needs `/v1/chat/completions`. Use **cursor-sdk-to-openai**, not `cursor-headless-cli-to-api.local` (that service is a custom `/api/v1/runs` bridge).

```text
baseURL = http://cursor-sdk-to-openai-api-1:8140/v1
apiKey  = local   # or AUTH_KEY
```

Host clients: `http://127.0.0.1:8173/v1`.

## Seeded users

| Name | Email | Role |
|------|-------|------|
| Shima Seifollahi | s.seifollahi@ondpline.com | user |
| Armin Dashti | a.dashti@ondpline.com | admin |
| Mozaffar Sabzevari | m.sabzevari@ondpline.com | user |
| Amin Bazri | a.bazri@ondpline.com | user |
| Ali Barati | a.barati@ondpline.com | user |
| MJ Amiri | m.amiri@ondpline.com | user |

Password for all (and bootstrap `armin@local`): `123456`.

## Remove

```powershell
.\scripts\remove-local-docker.ps1
```

Full wipe:

```powershell
.\scripts\reinstall-local-docker.ps1
```

## Notes

- Open WebUI has no subdirectory base path; `/maya` redirects to `http://maya.local/` (port 80), not `:3080`.
- Compose uses `restart: unless-stopped` so Maya starts with Docker.
- Branding env `WEBUI_NAME=Maya` becomes **Maya (Open WebUI)** under the project license.
- Docker DNS name `ollama` on `pc-armin-local` may be an empty volume; Maya uses `host.docker.internal:11434` for local models.
