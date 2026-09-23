# Maya

Local **Open WebUI** chatbot branded **Maya**, at [http://maya.local/](http://maya.local/), with dual Ollama + OpenAI-compatible Cursor models and shared ERP RAG.

| Piece | Source |
|-------|--------|
| UI | Official image `ghcr.io/open-webui/open-webui` ([docs](https://docs.openwebui.com/getting-started/quick-start/), [repo](https://github.com/open-webui/open-webui)) |
| LLM providers | Local Ollama (`host.docker.internal:11434`) + server Ollama (`10.10.16.118:11434`) + OpenAI-compatible `cursor-sdk-to-openai` + free-only `openrouter-api` |
| Entry | [nginx-local](https://github.com/ArminDashti/nginx-local) serves `http://maya.local/` on port 80; `/maya` bookmarks 302 → `maya.local` (never `:3080`) |

## Prerequisites

1. Docker Desktop running
2. Host Ollama with `gemma4:e4b` and `qwen2.5:3b` (also on `10.10.16.118`)
3. External network `pc-armin-local`
4. `cursor-sdk-to-openai` stack up on `pc-armin-local` (Auto)
5. `openrouter-to-openai-compatible-api` stack up on `pc-armin-local` (free models)
6. `nginx-gateway` (restart unless-stopped) for `http://maya.local/` and `/maya` → `maya.local`

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
| Cursor-Headless-CLI-Auto | `cursor-sdk-to-openai` → `auto` |
| OpenRouter-Auto-Free | `openrouter-api` → `openrouter/free` |
| OpenRouter-*-Free | `openrouter-api` → matching `:free` model |
| Local-Armin-Gemma-4-e4b | local Ollama `gemma4:e4b` |
| Local-Armin-Qwen-2.5-2B | local Ollama `qwen2.5:3b` (installed tag; no 2b on hosts) |
| Server-Gemma-4-e4b | server Ollama `gemma4:e4b` @ 10.10.16.118 |
| Server-Qwen-2.5-2b | server Ollama `qwen2.5:3b` @ 10.10.16.118 |

All of these share Knowledge **ERP Reports** from `C:\Users\armin\TFS\rag-for-ai\reports\` (`reports-index.md`, `reports.md`) plus Skills: Find ERP Report, Report Index First, Persian Title Match. Paid OpenRouter models stay hidden (proxy filters `/v1/models`).

Re-sync after RAG or user changes:

```powershell
.\.armin\rag\sync-maya.ps1
```

Performance defaults (low-resource server; tuned 2026-09-23):

| Setting | Value | Why |
|---------|-------|-----|
| Default + pinned model | **Server-Gemma-4-e4b** | Preferred chat model; only the main answer runs on the server |
| Task model (`TASK_MODEL`, `TASK_MODEL_EXTERNAL`) | **Local-Armin-Qwen-2.5-2B** | Titles/tags/follow-ups/search-query gen/tool decisions run on local Ollama, keeping ~90s of aux LLM calls off the server |
| Retrieval | vector search in Qdrant first → related `.md` chunks, `TOP_K=5`, hybrid on, `RELEVANCE_THRESHOLD=0.4` | Score gap is 0.48+ relevant vs ≤0.27 irrelevant; junk queries return 0 chunks |
| `num_ctx` (all four Ollama chat models) | **8192** | A RAG first turn is ~2.4–3.8k prompt tokens; the Ollama default 4096 overflows on turn two (server has ~25 GB RAM free) |

## Vector database (Qdrant) + ERP report-access data

Maya's retrieval does not run on the in-container Chroma DB any more: `VECTOR_DB=qdrant` points it at the Qdrant container, so both RAG retrieval and the ERP access search are real vector queries.

| Piece | Detail |
|-------|--------|
| Vector DB | `qdrant/qdrant` container, host publish `:6333`, storage on `C:\Users\armin\qdrant_storage` |
| Maya RAG collections | `maya_knowledge`, `maya_files` (`QDRANT_COLLECTION_PREFIX=maya`), 384-d cosine |
| Embedding model | `sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2` — the previous default `all-MiniLM-L6-v2` is English-only and ranks Persian queries badly |
| ERP access collection | `erp_reports` — 3732 vectors from `rep_converted.deduped.json`, payload = `NameSystem`, `ParentSystemtxt`, `FullNamePersonel` |
| Chat tool | **Qdrant ERP Report Access Search** (`.armin/rag/tools/qdrant_erp_search.py`) — semantic search over `erp_reports`, optional `person` filter |
| RAG markdown | `.armin/rag/generated/reports-access/*.md` → knowledge **ERP Reports Access** |

Rebuild all three pieces:

```powershell
# 1) vectors for the access dataset (runs inside maya-openwebui: reuses the cached embedding model)
docker cp "C:/Users/armin/Desktop/rep_converted.deduped.json" maya-openwebui:/tmp/rep.json
docker cp scripts/qdrant_ingest_erp_reports.py maya-openwebui:/tmp/qdrant_ingest.py
docker exec maya-openwebui python /tmp/qdrant_ingest.py --json /tmp/rep.json --recreate

# 2) RAG-ready markdown from the same dataset
python scripts/generate_reports_access_md.py --json "C:/Users/armin/Desktop/rep_converted.deduped.json" --out ".armin/rag/generated/reports-access"

# 3) knowledge collection + tool + attach both to every shared-RAG model
python scripts\sync_maya_reports_access.py
```

Checks:

```powershell
curl.exe http://localhost:6333/collections                 # erp_reports, maya_knowledge, maya_files
curl.exe http://localhost:6333/collections/erp_reports     # points_count = 3732
```

In chat, ask e.g. «چه کسانی به گزارش لیست دریافت و پرداخت دسترسی دارند؟» — the model answers from the Qdrant tool and from the **ERP Reports Access** knowledge.


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
- Server Ollama `10.10.16.118:11434` is reachable from Maya (`/ollama/api/tags/1` lists `qwen2.5:3b`, `gemma4:e4b`, `deepseek-r1:14b`). `gemma4:e4b` loads fine there since the 2026-09-23 upgrade to Ollama 0.34.3 (the old broken-blob failure is gone); it is CPU-only (~10 tok/s generate, ~58 tok/s prefill).
- Qdrant runs outside this compose project (container `pensive_wright`, `qdrant/qdrant`, storage `C:\Users\armin\qdrant_storage`); Maya only needs `host.docker.internal:6333`.
- Embedding models live in the `maya-openwebui-data` volume and the container runs with `HF_HUB_OFFLINE=1`; after adding a new model to the config, set `HF_HUB_OFFLINE=0`, restart, then set it back.
- Triggering the **Qdrant ERP Report Access Search** tool depends on the chat model's function calling; Maya also retrieves the same data through the **ERP Reports Access** knowledge, so answers work either way.