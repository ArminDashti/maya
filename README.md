# Maya

Local **Open WebUI** chatbot branded **Maya**, at [http://maya.local/](http://maya.local/), with exactly **four** hosted models (OpenRouter + OpenCode Go) and shared ERP RAG over a **single** Qdrant collection.

| Piece | Source |
|-------|--------|
| UI | Official image `ghcr.io/open-webui/open-webui` ([docs](https://docs.openwebui.com/getting-started/quick-start/), [repo](https://github.com/open-webui/open-webui)) |
| LLM providers | OpenRouter (`openrouter/auto`) + OpenCode Go chat (`mimo-v2.6-flash`, `deepseek-v4.1-flash`) + OpenCode Go Responses API (`gpt-6-luna`); keys come from the host env `OPENROUTER_API_KEY` / `OPENCODE_API_KEY` |
| Entry | [nginx-local](https://github.com/ArminDashti/nginx-local) serves `http://maya.local/` on port 80; `/maya` bookmarks 302 → `maya.local` (never `:3080`) |

## Prerequisites

1. Docker Desktop running
2. Environment variables `OPENROUTER_API_KEY` and `OPENCODE_API_KEY` (Windows user env; compose passes them to the container)
3. External network `pc-armin-local`
4. Qdrant reachable on `host.docker.internal:6333` (single collection `maya`)
5. `nginx-gateway` (restart unless-stopped) for `http://maya.local/` and `/maya` → `maya.local`

## Quick start

```powershell
cd C:\Users\armin\GitHub\maya
copy .env.example .env
# .env has no secrets: the two API keys are read from the environment

.\scripts\install-local-docker.ps1
.\.armin\rag\sync-maya.ps1     # connections, the four models, knowledge, visibility
```

| URL | Notes |
|-----|--------|
| http://maya.local/ | Canonical URL (nginx :80 → container) |
| http://pc-armin/maya | Bookmark; 302 → `http://maya.local/` |
| http://10.20.9.59/maya | Bookmark; 302 → `http://maya.local/` |
| http://127.0.0.1:3080/ | Direct publish port (debug only) |

Stack: `maya` · container: `maya-openwebui` · update keeps volumes/DB.

Shared password for seeded users + bootstrap admin: `123456`.

## Models (all users) — exactly four

| Picker name | Backend model | Connection |
|-------------|---------------|------------|
| OpenRouter-Auto | `openrouter/auto` | `https://openrouter.ai/api/v1` (chat/completions, `max_tokens` capped at 8192 — OpenRouter meters by credits) |
| OpenCode-Mimo-v2.6-Flash | `mimo-v2.6-flash` | `https://opencode.ai/zen/go/v1` (chat/completions) |
| OpenCode-DeepSeek-4.1-Flash | `deepseek-v4.1-flash` | `https://opencode.ai/zen/go/v1` (chat/completions) |
| OpenCode-GPT-6-Luna | `gpt-6-luna` | `https://opencode.ai/zen/go/v1` (**Responses API** only — that connection is `api_type: responses`) |

Everything else is hidden + deactivated: Ollama is connected but disabled
(`ENABLE_OLLAMA_API=false`), the old Cursor connection is gone, and
`sync-maya.ps1` deactivates every stored model outside the four (the provider
base rows stay active for routing but carry `meta.hidden`, which the picker
filters out).

All four share the whole knowledge store — every knowledge base (`.md` files)
is attached to each model — plus the unified Skill *Find ERP Report* and the
global filter that injects ERP vector
candidates. OpenCode Go additionally wants a stable `x-opencode-session` per
conversation (connection header `maya-{{CHAT_ID}}`).

Re-sync after RAG or model changes:

```powershell
.\.armin\rag\sync-maya.ps1                  # idempotent
.\.armin\rag\sync-maya.ps1 -RefreshKnowledge # re-embed the .md files (purges their vectors first)
```

Performance defaults (low-resource server; tuned 2026-09-23):

| Setting | Value | Why |
|---------|-------|-----|
| Default model | **OpenRouter-Auto** (`DEFAULT_MODELS=openrouter-auto`) | First model in the picker for every user |
| Task model (`task.model.default`) | **OpenCode-Mimo-v2.6-Flash** | Titles/tags/follow-ups/search-query gen run on the cheap, fast Mimo model (Ollama is disabled) |
| Retrieval | vector search in Qdrant first → hybrid + CrossEncoder rerank (`mmarco-mMiniLMv2-L12-H384-v1`), `TOP_K=5`, `TOP_K_RERANKER=5`, `RELEVANCE_THRESHOLD=0.4` | Hybrid on; CrossEncoder reorders candidates before the LLM sees them |
| Retrieval order (enforced) | Global filter `erp_reports_inject` rewrites the user text and searches the `erp_reports` **tenant** of the single `maya` collection, then injects candidates into every chat turn (all four models). Model selects relevant rows and answers as a NameSystem / ParentSystemtxt table. Tool `search_erp_report_access` stays optional. Seeded by `.armin/rag/sync-maya.ps1` + `scripts/sync_maya_reports_access.py` | Works without function calling |

## Vector database (Qdrant) — exactly one collection

Maya's retrieval does not run on the in-container Chroma DB any more: `VECTOR_DB=qdrant` points it at the Qdrant container, and **everything lives in one collection** (`maya`).

| Piece | Detail |
|-------|--------|
| Vector DB | `qdrant/qdrant` container, host publish `:6333`, storage on `C:\Users\armin\qdrant_storage` |
| Single collection | `maya` (`QDRANT_COLLECTION_PREFIX=maya`), 384-d cosine. Knowledge `.md` chunks, file chunks and the ERP access rows share it, separated by the payload field `tenant_id` |
| How | `.armin/patch/qdrant_multitenancy.py` overrides Open WebUI's Qdrant client (bind-mounted in `docker-compose.yml`): every logical collection maps onto `maya`, every read/write/delete stays tenant-scoped |
| Tenants | knowledge id (`a77534f4-…` = **ERP Reports**, …) · `file-<id>` per uploaded file · `erp_reports` = 3732 ERP access rows |
| Merge strays back in | `docker cp scripts/qdrant_merge_collections.py maya-openwebui:/tmp/merge.py` then `docker exec maya-openwebui python3 /tmp/merge.py --tenant-override erp_reports=erp_reports --delete-sources` (idempotent) |
| Embedding model | `sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2` — the previous default `all-MiniLM-L6-v2` is English-only and ranks Persian queries badly |
| Reranker | `cross-encoder/mmarco-mMiniLMv2-L12-H384-v1` (multilingual CrossEncoder; hybrid search on) |
| Global filter | **ERP Reports Vector Inject** (`.armin/rag/filters/erp_reports_inject.py`) — active + global; rewrites query → searches the `erp_reports` tenant of `maya` → injects candidates into every model turn |
| Chat tool | **Qdrant ERP Report Access Search** (`.armin/rag/tools/qdrant_erp_search.py`) — optional semantic search over the same tenant (person filter); not required when the global filter is on |
| RAG markdown | `C:\Users\armin\TFS\rag-for-ai\reports\` (`reports-index.md`, `reports.md`) → knowledge **ERP Reports**; `.armin/rag/generated/reports-access/*.md` → knowledge **ERP Reports Access** |
| Chat answer shape | Persian Markdown grid: **نام گزارش** \| **آدرس صفحه**; address links use `http://erp.dpdc.co:8880/` plus the encoded `ParentSystemtxt` path |

Rebuild all three pieces:

```powershell
# 1) vectors for the access dataset (runs inside maya-openwebui: reuses the cached embedding model;
#    writes into the shared `maya` collection under tenant erp_reports, --recreate clears only
#    that tenant - the knowledge .md vectors stay untouched)
docker cp "C:/Users/armin/Desktop/rep_converted.deduped.json" maya-openwebui:/tmp/rep.json
docker cp scripts/qdrant_ingest_erp_reports.py maya-openwebui:/tmp/qdrant_ingest.py
docker exec maya-openwebui python /tmp/qdrant_ingest.py --json /tmp/rep.json --recreate

# 2) RAG-ready markdown from the same dataset
python scripts/generate_reports_access_md.py --json "C:/Users/armin/Desktop/rep_converted.deduped.json" --out ".armin/rag/generated/reports-access"

# 3) knowledge collection + tool + global filter + model wiring
python scripts\sync_maya_reports_access.py
```

Checks:

```powershell
curl.exe http://localhost:6333/collections        # {"result":{"collections":[{"name":"maya"}]}}
curl.exe http://localhost:6333/collections/maya   # points_count = knowledge + file + 3732 ERP rows
```

In chat (any of the four models), ask e.g. «لیست دریافت و پرداخت» — the global filter injects ERP candidates from the `maya` collection; the model answers with a **NameSystem** / **ParentSystemtxt** table. No tool call required.

## Providers (OpenRouter + OpenCode Go)

Three OpenAI-compatible connections, applied by `.armin/rag/sync-maya.ps1` (keys come from the host environment and are never written to the repo):

```text
0  https://openrouter.ai/api/v1   ${OPENROUTER_API_KEY}   models: openrouter/auto
1  https://opencode.ai/zen/go/v1  ${OPENCODE_API_KEY}     models: mimo-v2.6-flash, deepseek-v4.1-flash
                                                          headers: x-opencode-session=maya-{{CHAT_ID}}, User-Agent=maya-openwebui/1.0
2  https://opencode.ai/zen/go/v1  ${OPENCODE_API_KEY}     api_type: responses, models: gpt-6-luna (same headers)
```

`gpt-6-luna` only speaks the Responses API (`ModelProtocolUnsupported` on `/chat/completions`), hence connection 2. OpenCode Go rejects requests that do not carry a stable `x-opencode-session`, and asks clients to send a non-SDK `User-Agent`.

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
- Ollama is configured (`host.docker.internal:11434`, server `10.10.16.118:11434`) but **disabled** (`ENABLE_OLLAMA_API=false`) so it adds no models to the picker; re-enable it in Admin → Connections if local models are wanted again.
- The four public models are hosted only: OpenRouter meters `openrouter/auto` by credits (`max_tokens` is capped at 8192 on that model) and OpenCode Go is a $10/month subscription with per-model monthly limits.
- Qdrant runs outside this compose project (container `pensive_wright`, `qdrant/qdrant`, storage `C:\Users\armin\qdrant_storage`); Maya only needs `host.docker.internal:6333`.
- Embedding models live in the `maya-openwebui-data` volume and the container runs with `HF_HUB_OFFLINE=1`; after adding a new model to the config, set `HF_HUB_OFFLINE=0`, restart, then set it back.
- Every model gets the ERP candidates through the global filter **ERP Reports Vector Inject** (no function calling needed) and answers with a NameSystem / ParentSystemtxt table; the optional tool `search_erp_report_access` (attached to all four) is only needed for who-can-access questions.
