# Maya

Local **Open WebUI** chatbot at [http://pc-armin:3080/](http://pc-armin:3080/), backed by [cursor-sdk-to-openai](https://github.com/ArminDashti/cursor-sdk-to-openai).

| Piece | Source |
|-------|--------|
| UI | Official image `ghcr.io/open-webui/open-webui` ([docs](https://docs.openwebui.com/getting-started/quick-start/), [repo](https://github.com/open-webui/open-webui)) |
| LLM provider | Open WebUI OpenAI-compatible connection → `cursor-sdk-to-openai` (`OPENAI_API_BASE_URL` + `OPENAI_API_KEY`) |
| Entry | Published port `3080` (Open WebUI must run at URL root — no subdirectory base path) |
| Gateway bookmark | [nginx-local](https://github.com/ArminDashti/nginx-local) `/maya/` → 302 to `:3080/` |

## Prerequisites

1. Docker Desktop running
2. External network `pc-armin-local` (created by nginx-local / other pc-armin stacks)
3. `cursor-sdk-to-openai` stack up on network `pc-armin-local` (container `cursor-sdk-to-openai-api-1`, port `8140` inside Docker)
4. Optional: `nginx-gateway` up so `http://pc-armin/maya/` redirects to the UI

## Quick start

```powershell
cd C:\Users\armin\GitHub\maya
copy .env.example .env
# Set OPENAI_API_KEY from cursor-sdk-to-openai-api AUTH_KEY if set; else leave "local"
# Default base URL uses Docker DNS: http://cursor-sdk-to-openai-api-1:8140/v1

.\.armin\deploy\local-docker\install.ps1
```

UI: http://pc-armin:3080/ (or http://127.0.0.1:3080/)  
Bookmark helper: http://pc-armin/maya/ → redirects to the UI

Admin (first boot seed): `armin` / `dopadopa123` (email `armin@local`).

## OpenAI-compatible provider (`cursor-sdk-to-openai`)

Maya connects the same way Open WebUI documents under **Connect a Provider** → OpenAI-compatible: URL + API key in **Settings → Admin → Connections**. There is no custom Cursor client in this app.

```text
baseURL = http://cursor-sdk-to-openai-api-1:8140/v1   # Maya container → API container on pc-armin-local
apiKey  = local                                       # or AUTH_KEY from cursor-sdk-to-openai-api/.env
tag     = cursor-sdk-to-openai                        # OPENAI_API_CONFIGS connection label
```

Env mapping: `ENABLE_OPENAI_API=true`, `OPENAI_API_BASE_URL`, `OPENAI_API_KEY`, `OPENAI_API_CONFIGS`. Routes used: `GET /v1/models`, `POST /v1/chat/completions`. Keep the `/v1` suffix.

Chat needs a Cursor API key with agent access (Pro or higher). Free-tier keys return `plan_required` from `@cursor/sdk`. Set `RAMIN_2_CURSOR_API` (or `CURSOR_API_KEY`) in `cursor-sdk-to-openai-api/.env`, then recreate the API container.

Host-only clients (outside Docker) use `http://127.0.0.1:8140/v1` or published `http://127.0.0.1:8173/v1` depending on how the API is started.

### Load / switch models in the UI

1. Open http://pc-armin:3080/ and sign in (`armin` / `dopadopa123`)
2. Open the model picker (top of chat) — models come from `GET /v1/models` on `cursor-sdk-to-openai`
3. Pick `composer-2.5`, `composer-2`, or `auto-smart` (or live ids when the Cursor account can list them)
4. Admin → Settings → Connections: connection URL must stay `http://cursor-sdk-to-openai-api-1:8140/v1` with key matching API `AUTH_KEY` (or `local` when auth is open)

## RAG (ERP reports for user 65778)

Open WebUI Knowledge collection **ERP Reports User 65778** is loaded from:

- `C:\Users\armin\TFS\Source\.armin\rag\user-65778-reports-index.md` (compact index)
- `C:\Users\armin\TFS\Source\.armin\rag\user-65778-reports.md` (full catalog)

Custom model **ERP Reports 65778** (`erp-reports-65778`) wraps `composer-2.5` with that knowledge attached.

**How to ask in the UI**

1. Open http://pc-armin:3080/
2. Select model **ERP Reports 65778** (RAG is attached to this model only). Plain `composer-2.5` / `composer-2` / `auto` do **not** see the report catalog unless you attach knowledge `#ERP Reports User 65778` in the chat.
3. Ask for a report by Persian title or English page name (e.g. `CustomerCreditIncreaseReport`)

Re-import / refresh after the source RAG files change:

```powershell
.\.armin\rag\sync-user-65778-reports.ps1
```

Hybrid search is enabled in Admin → Documents (BM25 + embeddings) so Persian titles match more reliably.

## Remove

```powershell
.\.armin\deploy\local-docker\remove.ps1
```

## Notes

- Open WebUI has no official subdirectory base path. Serving it under `/maya/` returns HTML 200 then a client **404: Not Found** (SvelteKit `base` is empty). Use port `3080` at the URL root.
- Image is pulled only from official GHCR (`ghcr.io/open-webui/open-webui`).
- Windows local compose uses `restart: "no"`.
- Chat answers still need a working `cursor-sdk-to-openai` provider (Pro / Cloud Agent plan). Knowledge search works even when the LLM call is blocked.
