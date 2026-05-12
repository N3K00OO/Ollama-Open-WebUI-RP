# RAG Integration Plan

## Existing Startup Flow

This repository uses a single-container RunPod image. It does not use Docker Compose or Docker-in-Docker.

The container starts with `/start.sh`, which:

- starts nginx from `/etc/nginx/nginx.conf`
- starts SSH when `PUBLIC_KEY` is present
- exports RunPod shell environment helpers
- runs `/pre_start.sh`
- starts JupyterLab
- runs `/post_start.sh`
- sleeps forever to keep the pod alive

`/pre_start.sh` handles timezone setup and optional Python venv sync. The default uses the image-bundled `/venv`.

`/post_start.sh` is the main application launcher. It:

- creates runtime directories under `/workspace`
- configures Open WebUI environment variables
- downloads configured GGUF and mmproj files
- validates GPU compatibility
- starts `llama-server` on `127.0.0.1:11434`
- starts local SearXNG on `127.0.0.1:18080`
- starts Open WebUI on its default local port

## Open WebUI Environment Configuration

Open WebUI runtime environment is configured in `configure_openwebui_runtime_env` inside `scripts/post_start.sh`. Existing values include:

- local OpenAI-compatible API wiring to `http://127.0.0.1:11434/v1`
- Open WebUI reset/auth defaults
- bundled SearXNG web search settings
- optional CORS origin derived from `WEBUI_URL`

That function is the safest place to add RAG defaults because Open WebUI reads many RAG settings from environment variables at process start.

Some Open WebUI settings use PersistentConfig. After the first boot, values stored in Open WebUI's database may override later environment changes. The launcher should not delete user data automatically.

## Service Wiring

### SearXNG

SearXNG is installed into `/opt/searxng-venv`, starts from `scripts/post_start.sh`, binds to `127.0.0.1:${SEARXNG_PORT:-18080}`, and is consumed by Open WebUI through `SEARXNG_QUERY_URL`.

### llama.cpp

`llama-server` is built in the Dockerfile and copied to `/llama-server`. It starts from `scripts/post_start.sh`, binds to `127.0.0.1:11434`, and is exposed externally only through nginx on RunPod port `11435`.

### Nginx Proxy

Nginx exposes only:

- `8081` for Open WebUI
- `11435` for the proxied llama.cpp API
- `8889` for JupyterLab

Qdrant and Docling should not be added to nginx.

## RAG Integration Approach

The safest approach is to preserve the single-image RunPod flow and add local services to `scripts/post_start.sh`:

- `start_qdrant` binds Qdrant to `127.0.0.1:6333` and persists data under `/workspace/qdrant/storage`
- `start_docling` binds Docling Serve to `127.0.0.1:5001`
- `configure_openwebui_rag_env` exports Qdrant, Docling, embedding, hybrid search, and reranker defaults before Open WebUI starts
- `DISABLE_RAG_STACK=True` skips service startup and avoids forcing RAG environment variables

This keeps existing RunPod ports, public proxy behavior, llama.cpp startup, SearXNG startup, JupyterLab startup, and GHCR build flow intact.
