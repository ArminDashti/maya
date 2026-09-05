# Maya

Local **Open WebUI** chatbot front door at [http://pc-armin/maya/](http://pc-armin/maya/), backed by [cursor-sdk-to-openai](https://github.com/ArminDashti/cursor-sdk-to-openai).

| Piece | Source |
|-------|--------|
| UI | Official image `ghcr.io/open-webui/open-webui` ([docs](https://docs.openwebui.com/getting-started/quick-start/), [repo](https://github.com/open-webui/open-webui)) |
| LLM API | `cursor-sdk-to-openai-api` on the host (`OPENAI_API_BASE_URL`) |
| Gateway | [nginx-local](https://github.com/ArminDashti/nginx-local) path `/maya/` |

## Prerequisites

1. Docker Desktop running
2. External network `pc-armin-local` (created by nginx-local / other pc-armin stacks)
3. `cursor-sdk-to-openai-api` listening on the host port in `OPENAI_API_BASE_URL` (default `http://host.docker.internal:8140/v1`)
4. `nginx-gateway` up so `http://pc-armin/maya/` routes correctly

## Quick start

```powershell
cd C:\Users\armin\GitHub\maya
copy .env.example .env
# Set OPENAI_API_KEY from cursor-sdk-to-openai-api AUTH_KEY if set; else leave "local"
# Align OPENAI_API_BASE_URL with the live cursor-sdk-to-openai-api listen port (often 8140)

.\.armin\deploy\local-docker\install.ps1
```

Direct UI (bypass nginx): http://127.0.0.1:3080  
Gateway: http://pc-armin/maya/

Admin (first boot seed): `armin` / `dopadopa123` (email `armin@local`).

## Remove

```powershell
.\.armin\deploy\local-docker\remove.ps1
```

## Notes

- Open WebUI has no official subdirectory base path. nginx-local strips `/maya` and uses referer-aware proxies for absolute asset paths (`/_app`, `/api`, …).
- Image is pulled only from official GHCR (`ghcr.io/open-webui/open-webui`).
- Windows local compose uses `restart: "no"`.
