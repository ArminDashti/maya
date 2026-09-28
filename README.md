# Maya

Local **Open WebUI** chatbot branded **Maya**, at [http://maya.local/](http://maya.local/), with exactly **four** hosted models (OpenRouter + OpenCode Go) and shared ERP report retrieval: BM25 ranks a generated catalog, the model picks the candidates (no vector database).

| Piece | Source |
|-------|--------|
| UI | Official image `ghcr.io/open-webui/open-webui` ([docs](https://docs.openwebui.com/getting-started/quick-start/), [repo](https://github.com/open-webui/open-webui)) |
| LLM providers | OpenRouter (`openrouter/auto`) + OpenCode Go chat (`mimo-v2.6-flash`, `deepseek-v4.1-flash`) + OpenCode Go Responses API (`gpt-6-luna`); keys come from the host env `OPENROUTER_API_KEY` / `OPENCODE_API_KEY` |
| Entry | [nginx-local](https://github.com/ArminDashti/nginx-local) serves `http://maya.local/` on port 80; `/maya` bookmarks 302 → `maya.local` (never `:3080`) |

## Prerequisites

1. Docker Desktop running
2. Environment variables `OPENROUTER_API_KEY` and `OPENCODE_API_KEY` (Windows user env; compose passes them to the container)
3. External network `pc-armin-local`
4. `nginx-gateway` (restart unless-stopped) for `http://maya.local/` and `/maya` → `maya.local`

No Qdrant and no embedding model are needed for report retrieval any more.

## Quick start

```powershell
cd C:\Users\armin\GitHub\maya
copy .env.example .env
# .env has no secrets: the two API keys are read from the environment

.\scripts\install-local-docker.ps1
python scripts\generate_reports_access_md.py --json "C:/Users/armin/Desktop/rep_converted.deduped.json" --out ".armin/rag/generated/reports-access"
python scripts\sync_maya_reports_access.py   # global BM25 filter
.\.armin\rag\sync-maya.ps1                   # connections, the four models, prompt, skill, visibility
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

All four share the same retrieval: BM25 candidates injected by the global filter
plus the unified Skill *Find ERP Report* and the prompt in `sync-maya.ps1`. No
knowledge base is attached — knowledge search would need the retired vector DB.
OpenCode Go additionally wants a stable `x-opencode-session` per conversation
(connection header `maya-{{CHAT_ID}}`).

Re-sync after prompt, skill or model changes:

```powershell
.\.armin\rag\sync-maya.ps1                  # idempotent
```

The model list in `sync-maya.ps1` must match the live picker: it rewrites the four
models and deactivates everything else, so add any newly added model to `$models`
before running it.

Performance defaults (low-resource server; tuned 2026-09-23):

| Setting | Value | Why |
|---------|-------|-----|
| Default model | **OpenRouter-Auto** (`DEFAULT_MODELS=openrouter-auto`) | First model in the picker for every user |
| Task model (`task.model.default`) | **OpenCode-Mimo-v2.6-Flash** | Titles/tags/follow-ups/search-query gen run on the cheap, fast Mimo model (Ollama is disabled) |
| Retrieval | BM25 over the mounted catalog (see below), `top_k=10` candidates per turn | Lexical ranking is enough for report titles and needs no embedding model, no Qdrant and no reranker |
| Retrieval order (enforced) | Global filter `erp_reports_inject` rewrites the user text, ranks the catalog with BM25 and injects candidates into every chat turn (all four models). The model selects the relevant rows and answers with the نام گزارش / آدرس در صفحه / پیوند table | Works without function calling; the model never rebuilds a URL |

## Retrieval (BM25) — no vector database

Report lookup is lexical: the global filter ranks a generated catalog with Okapi BM25 and injects the top rows as candidates; the model picks the rows that answer the question and renders the table. Nothing is embedded, so there is no separate query/document vector space that can drift apart, and no vector DB has to be up for chat to work.

| Piece | Detail |
|-------|--------|
| Corpus | `.armin/rag/generated/reports-access/reports-access.bm25.json` — 569 distinct report locations (`ن`, `m`, `u`: name, webpage address, URL), generated from `rep_converted.deduped.json` |
| Mount | compose mounts `.armin/rag/generated/reports-access` read-only at `/app/backend/data/maya-catalog`, so a regenerated catalog is live on the next turn (the filter caches on mtime) |
| Ranking | Okapi BM25 (`k1=1.2`, `b=0.75`) over normalized Persian tokens: kashida/ZWNJ/digit normalization, letter folding (`ي→ی`, `ك→ک`), small stopword list, plural folding (`فاکتورهای`→`فاکتور`), report-name terms weighted 3x over menu-path terms 2x, plus a phrase bonus when the whole query appears inside a report name |
| Candidate gate | top 10 rows with a positive score (~2.8k tokens per turn — the percent-encoded ERP URLs dominate; raise/lower with the filter's `top_k` valve); unrelated questions (greetings, other topics) score nothing and the injected block says so |
| Table | name / address / link, e.g. «لیست دریافت و پرداخت» → `گزارشات › خزانه › لیست دریافت و پرداخت` → `http://erp.dpdc.co:8880/…` |
| Global filter | **ERP Reports BM25 Inject** (`.armin/rag/filters/erp_reports_inject.py`) — active + global; rewrites the user text, ranks the catalog, injects the candidates into every model turn before the LLM sees it |
| Model wiring | system prompt + skill *Find ERP Report* (`.armin/rag/sync-maya.ps1`), evaluated with `function_calling="legacy"` — that is what inlines the skill text into the system message instead of gating it behind a `view_skill` tool call |
| Chat answer shape | Persian Markdown grid: **نام گزارش** \| **آدرس در صفحه** \| **پیوند**; links are copied from the candidate rows (`http://erp.dpdc.co:8880/` plus the encoded report path), never rebuilt by the model |

`VECTOR_DB=qdrant` stays in `docker-compose.yml` only because Open WebUI requires a
valid vector DB at startup: no model has a knowledge base attached, so no chat turn
reaches it. `scripts/qdrant_ingest_erp_reports.py` and `scripts/qdrant_merge_collections.py`
are retired (kept for reference).

Rebuild the catalog and push the filter:

```powershell
# 1) catalog (JSON corpus for BM25 + the readable .md table) from the ERP dataset
python scripts/generate_reports_access_md.py --json "C:/Users/armin/Desktop/rep_converted.deduped.json" --out ".armin/rag/generated/reports-access"

# 2) global filter (active + global) and retire the old Qdrant tool
python scripts\sync_maya_reports_access.py

# 3) system prompt + skill on the four models
.\.armin\rag\sync-maya.ps1
```

Checks:

```powershell
# rank the catalog offline (no container needed): prints the top rows per probe query
python .armin/rag/filters/erp_reports_inject.py
python -c "import json;print(json.load(open('.armin/rag/generated/reports-access/reports-access.bm25.json',encoding='utf-8'))['count'])"
```

In chat (any of the four models), ask e.g. «لیست دریافت و پرداخت» — the filter injects the BM25 candidates and the model answers with a **نام گزارش / آدرس در صفحه / پیوند** table. No tool call required.

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
- Qdrant (`pensive_wright`, `qdrant/qdrant`, storage `C:\Users\armin\qdrant_storage`) is no longer needed for report retrieval; `VECTOR_DB=qdrant` only satisfies Open WebUI's startup requirement. `.armin/patch/qdrant_multitenancy.py` is still mounted for that leftover config.
- Every model gets the report candidates through the global filter **ERP Reports BM25 Inject** (no function calling needed) and answers with a **نام گزارش / آدرس در صفحه / پیوند** table; there is no chat tool any more.
- Persian queries: BM25 folds `ي/ك`, kashida and ZWNJ, digits and plural endings, so «فاکتورهای فروش» and «فاکتور فروش» rank the same rows. It is lexical by design — a question that shares no word with a report name returns no candidate, and the model then says so instead of guessing.
