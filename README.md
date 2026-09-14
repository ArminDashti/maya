# Maya

Local **Open WebUI** chatbot at [http://pc-armin:3080/](http://pc-armin:3080/), backed by [cursor-sdk-to-openai](https://github.com/ArminDashti/cursor-sdk-to-openai).

| Piece | Source |
|-------|--------|
| UI | Official image `ghcr.io/open-webui/open-webui` ([docs](https://docs.openwebui.com/getting-started/quick-start/), [repo](https://github.com/open-webui/open-webui)) |
| LLM providers | Host **Ollama** (`OLLAMA_BASE_URL` → `host.docker.internal:11434`) + OpenAI-compatible `cursor-sdk-to-openai` |
| Entry | Published port `3080` (Open WebUI must run at URL root — no subdirectory base path) |
| Gateway bookmark | [nginx-local](https://github.com/ArminDashti/nginx-local) `/maya/` → 302 to `:3080/` |

## Prerequisites

1. Docker Desktop running
2. Host **Ollama** listening on `11434` with model `pc-armin/maya` (`ollama create pc-armin/maya -f Modelfile` FROM `gemma4:e4b`)
3. External network `pc-armin-local` (created by nginx-local / other pc-armin stacks)
4. Optional: `cursor-sdk-to-openai` stack up on network `pc-armin-local` for Cursor models
5. Optional: `nginx-gateway` up so `http://pc-armin/maya/` redirects to the UI

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
2. Open the model picker (top of chat)
3. Pick **pc-armin/maya** (default: host Ollama `pc-armin/maya:latest` / Gemma + ERP RAG) or **pc-armin/qwen** (Ollama `qwen2.5:3b` + same ERP RAG). Also available: raw `gemma4:e4b` / `pc-armin/maya:latest` / `qwen2.5:3b`, and Cursor models via `cursor-sdk-to-openai` when that stack is up
4. Admin → Settings → Connections: Ollama URL must stay `http://host.docker.internal:11434`; OpenAI connection URL stays `http://cursor-sdk-to-openai-api-1:8140/v1` when used

## RAG (ERP reports for user 65778)

Open WebUI Knowledge collection **ERP Reports User 65778** is loaded from:

- `C:\Users\armin\TFS\Source\.armin\rag\user-65778-reports-index.md` (compact index)
- `C:\Users\armin\TFS\Source\.armin\rag\user-65778-reports.md` (full catalog)

Custom models **pc-armin/maya** (Ollama `pc-armin/maya:latest` / Gemma) and **pc-armin/qwen** (Ollama `qwen2.5:3b`) both have Knowledge attached in Open WebUI. RAG retrieval uses Open WebUI embeddings; chat completions go to Ollama.

**How to ask in the UI**

1. Open http://pc-armin:3080/
2. Select **pc-armin/maya** or **pc-armin/qwen** (RAG attached). Plain `gemma4:e4b` / `qwen2.5:3b` / `composer-2.5` do **not** see the report catalog unless you attach `#ERP Reports User 65778` in the chat.
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
- Chat answers on **pc-armin/maya** use host Ollama. Cursor models still need a working `cursor-sdk-to-openai` provider (Pro / Cloud Agent plan). Knowledge search works even when an LLM call is blocked.
