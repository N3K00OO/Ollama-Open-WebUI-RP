[![Build and Publish GHCR Images](https://github.com/N3K00OO/LLAMA-Open-WebUi/actions/workflows/build.yml/badge.svg)](https://github.com/N3K00OO/LLAMA-Open-WebUi/actions/workflows/build.yml)
[![Runpod](https://api.runpod.io/badge/N3K00OO/LLAMA-Open-WebUi)](https://console.runpod.io/hub/N3K00OO/LLAMA-Open-WebUi)

# LLAMA Open WebUI

This image is a llama-only RunPod base image:

- `llama.cpp` is built in CI and started as `./llama-server`
- Open WebUI is wired to the local OpenAI-compatible `/v1` endpoint
- SearXNG is started locally for Open WebUI web search
- JupyterLab is included for notebook and terminal access

GitHub Actions refreshes upstream `llama.cpp`, Open WebUI, and SearXNG versions at build time, runs a container smoke test for the launcher, proxy, and search path, pushes the images to GHCR, and verifies each published tag before the workflow passes.

## Images

Published package:

```text
ghcr.io/n3k00oo/llama-open-webui
```

Available tags:

| Tag | CUDA |
| --- | --- |
| `base-torch2.11.0-cu124` | 12.4 |
| `base-torch2.11.0-cu125` | 12.5 |
| `base-torch2.11.0-cu126` | 12.6 |
| `base-torch2.11.0-cu128` | 12.8 |
| `base-torch2.11.0-cu130` | 13.0 |

Use the full image name in RunPod:

```text
ghcr.io/n3k00oo/llama-open-webui:base-torch2.11.0-cu128
```

## Runtime

`llama-server` binds to `127.0.0.1:11434` and Open WebUI connects to:

```text
http://127.0.0.1:11434/v1
```

SearXNG binds to `127.0.0.1:18080` and Open WebUI connects to:

```text
http://127.0.0.1:18080/search?q=<query>
```

The public RunPod ports only expose the user-facing services. Open WebUI talks to both `llama-server` and SearXNG over localhost inside the same pod, so model generation and search handoff do not route out through the public proxy.

Place GGUF models in:

```text
/workspace/models
```

Startup behavior:

- configured Hugging Face and `wget` downloads run before `llama-server` starts, so the pod does not need a second boot
- SSH setup runs before optional workspace venv sync, so a slow network-volume copy does not block basic pod access
- the image uses the bundled `/venv` by default; set `SYNC_VENV_TO_WORKSPACE=True` only if you explicitly want to copy it into `/workspace/venv`
- V100 / compute capability `7.0` is allowed on the `cu124`, `cu125`, `cu126`, and `cu128` images, but blocked by default on `cu130` unless `LLAMA_ALLOW_UNSUPPORTED_GPU=True`
- `llama-server` is always launched on `127.0.0.1:11434`, never on `8080`
- if there is exactly one non-mmproj `*.gguf` file anywhere under `/workspace/models`, it is used as the explicit `--model`
- if there is exactly one `*mmproj*.gguf` file anywhere under `/workspace/models`, it is used as the explicit `--mmproj`
- `LLAMA_ALIAS` is always passed explicitly; if unset, it is derived from the resolved GGUF filename
- if `LLAMA_MULTIMODAL_REQUIRED=True`, startup fails unless `LLAMA_MMPROJ` resolves to a real file
- the launcher waits for `/v1/models` to become ready and treats HTTP `503 Loading model` as startup-in-progress
- if `llama-server` exits unexpectedly, the supervisor restarts it and keeps appending to `/workspace/logs/llama-server.log`
- Open WebUI uses the local llama.cpp endpoint
- Open WebUI web search uses the local SearXNG endpoint by default
- the public Open WebUI proxy on `8081` is WebSocket-safe and preserves real upstream API failure codes

## Web Search

Web search is enabled by default through the bundled SearXNG service. No second RunPod pod, Docker Compose stack, or Docker-in-Docker setup is required.

Default local search flow:

```text
Open WebUI -> http://127.0.0.1:18080/search?q=<query> -> SearXNG
```

The included SearXNG config enables JSON responses, which Open WebUI requires. Its settings file is baked into the image at:

```text
/etc/searxng/settings.yml
```

For a normal RunPod template, keep these defaults:

```text
START_SEARXNG=True
ENABLE_WEB_SEARCH=True
WEB_SEARCH_ENGINE=searxng
SEARXNG_QUERY_URL=http://127.0.0.1:18080/search?q=<query>
```

To use an external SearXNG instance instead:

```text
START_SEARXNG=False
ENABLE_WEB_SEARCH=True
WEB_SEARCH_ENGINE=searxng
SEARXNG_QUERY_URL=https://your-searxng.example/search?q=<query>
```

The external URL must allow `format=json` requests. If search fails, check `/workspace/logs/open-webui.log` and `/workspace/logs/searxng.log`.

## Exposed Ports

| Port | Purpose |
| --- | --- |
| `22` | SSH |
| `8081` | Open WebUI |
| `11435` | proxied llama.cpp API |
| `8889` | JupyterLab |

## Environment Variables

| Variable | Description | Default |
| --- | --- | --- |
| `JUPYTERLAB_PASSWORD` | Password for JupyterLab | unset |
| `TIME_ZONE` | Time zone, for example `Asia/Bangkok` | `Etc/UTC` |
| `SYNC_VENV_TO_WORKSPACE` | Copies the bundled Python venv into `/workspace/venv` before app startup. Leave disabled for faster boot. | `False` |
| `START_LLAMA_SERVER` | Starts `./llama-server` on boot | `True` |
| `START_SEARXNG` | Starts the bundled local SearXNG service on boot | `True` |
| `ENABLE_RAG_STACK` | Enables local RAG/document-processing defaults for Open WebUI | `True` |
| `DISABLE_RAG_STACK` | Emergency kill switch. Skips Qdrant/Docling startup and does not force RAG env defaults. | `False` |
| `REQUIRE_RAG_SERVICES` | Fail container startup if Qdrant or Docling readiness times out. Leave disabled on RunPod so Open WebUI can still boot while optional RAG services are investigated. | `False` |
| `ENABLE_QDRANT` | Starts local Qdrant and configures Open WebUI to use it | `True` |
| `VECTOR_DB` | Open WebUI vector database provider | `qdrant` |
| `QDRANT_URI` | Local or remote Qdrant HTTP URL for Open WebUI | `http://127.0.0.1:6333` |
| `QDRANT_API_KEY` | Optional Qdrant API key. Leave empty for localhost-only unauthenticated Qdrant. | unset |
| `QDRANT_ON_DISK` | Enables Qdrant on-disk vector storage behavior in Open WebUI | `True` |
| `QDRANT_TIMEOUT` | Qdrant request timeout in seconds | `10` |
| `QDRANT_STORAGE_PATH` | Local Qdrant persistence path | `/workspace/qdrant/storage` |
| `ENABLE_DOCLING` | Starts local Docling Serve and configures Open WebUI document extraction | `True` |
| `CONTENT_EXTRACTION_ENGINE` | Open WebUI document extraction engine | `docling` |
| `DOCLING_SERVER_URL` | Local or remote Docling Serve URL for Open WebUI | `http://127.0.0.1:5001` |
| `DOCLING_PARAMS` | JSON parameters passed to Docling by Open WebUI | `{"do_ocr":true,"ocr_engine":"tesseract","table_mode":"accurate"}` |
| `DOCLING_SERVE_MAX_SYNC_WAIT` | Max seconds Docling Serve waits for synchronous document conversion | `600` |
| `DOCLING_READY_TIMEOUT` | Seconds to wait for Docling Serve health during startup | `600` |
| `UVICORN_WORKERS` | Docling Serve worker count. Keep at `1` unless using shared task state. | `1` |
| `RAG_EMBEDDING_MODEL` | Default Open WebUI embedding model | `intfloat/multilingual-e5-large-instruct` |
| `RAG_TOP_K` | Documents retrieved before reranking | `20` |
| `ENABLE_RAG_HYBRID_SEARCH` | Enables Open WebUI hybrid RAG search | `True` |
| `ENABLE_RERANKER` | Enables local Open WebUI reranking env defaults | `True` |
| `RAG_RERANKING_MODEL` | Default local reranker | `BAAI/bge-reranker-v2-m3` |
| `RAG_TOP_K_RERANKER` | Documents kept after reranking | `5` |
| `RAG_RERANKING_BATCH_SIZE` | Reranker batch size. Lower this to reduce memory spikes. | `8` |
| `LLAMA_MODEL` | Absolute path to the GGUF file to load | auto-detect |
| `LLAMA_MMPROJ` | Absolute path to the mmproj GGUF file | auto-detect |
| `LLAMA_MULTIMODAL_REQUIRED` | Treat missing mmproj as a startup error | `False` |
| `LLAMA_ALIAS` | Model name exposed by `/v1/models` | GGUF filename |
| `LLAMA_CTX_SIZE` | Value passed to `--ctx-size` | `4096` |
| `LLAMA_GPU_LAYERS` | Value passed to `--n-gpu-layers` | `999` |
| `LLAMA_PARALLEL` | Value passed to `--parallel` | `1` |
| `LLAMA_ALLOW_UNSUPPORTED_GPU` | Overrides the default CUDA 13.x V100 / compute capability `7.0` block | `False` |
| `LLAMA_SERVER_API_KEY` | Optional API key for `llama-server` | unset |
| `LLAMA_SERVER_EXTRA_ARGS` | Extra flags appended to `llama-server`. Do not use this for host, port, model, alias, or mmproj. | unset |
| `LLAMA_READY_TIMEOUT` | Seconds to wait for `/v1/models` readiness per launch attempt | `600` |
| `LLAMA_READY_POLL_INTERVAL` | Seconds between readiness probes | `2` |
| `LLAMA_MAX_RESTARTS` | Restart attempts after an unexpected `llama-server` exit | `3` |
| `LLAMA_RESTART_DELAY` | Seconds to wait before restarting `llama-server` | `5` |
| `HF_TOKEN` | Hugging Face token for gated or private downloads | unset |
| `HF_REPO_DOWNLOAD` | Full Hugging Face repo to sync into `/workspace/models/<owner>/<repo>` | unset |
| `HF_REPO_REVISION` | Optional branch, tag, or commit for `HF_REPO_DOWNLOAD` | latest |
| `HF_REPO_TYPE` | Repo type for whole-repo downloads: `model`, `dataset`, or `space` | `model` |
| `HF_REPO_INCLUDE` | Optional include glob for whole-repo downloads | unset |
| `HF_REPO_EXCLUDE` | Optional exclude glob for whole-repo downloads | unset |
| `HF_MODEL_REPO` | Hugging Face repo that contains the main GGUF file | unset |
| `HF_MODEL_FILE` | File path inside `HF_MODEL_REPO` for the main GGUF | unset |
| `HF_MODEL_REVISION` | Optional branch, tag, or commit for `HF_MODEL_FILE` | latest |
| `HF_MODEL_TYPE` | Repo type for `HF_MODEL_FILE`: `model`, `dataset`, or `space` | `model` |
| `HF_MMPROJ_REPO` | Hugging Face repo that contains the mmproj file. Falls back to `HF_MODEL_REPO`. | unset |
| `HF_MMPROJ_FILE` | File path inside the repo for the mmproj GGUF | unset |
| `HF_MMPROJ_REVISION` | Optional branch, tag, or commit for `HF_MMPROJ_FILE` | latest |
| `HF_MMPROJ_TYPE` | Repo type for `HF_MMPROJ_FILE`: `model`, `dataset`, or `space` | `model` |
| `WGET_MODEL_URL` | Direct URL for the main GGUF file | unset |
| `WGET_MODEL_FILENAME` | Path under `/workspace/models` for the downloaded GGUF | URL basename |
| `WGET_MMPROJ_URL` | Direct URL for the mmproj GGUF file | unset |
| `WGET_MMPROJ_FILENAME` | Path under `/workspace/models` for the downloaded mmproj file | URL basename |
| `MODEL_DOWNLOAD_FORCE` | Re-download Hugging Face files and overwrite existing `wget` targets | `False` |
| `DATA_DIR` | Open WebUI data directory | `/workspace/data` |
| `WEBUI_AUTH` | Enables Open WebUI auth | `False` |
| `WEBUI_URL` | Public Open WebUI URL used for RunPod access | unset |
| `CORS_ALLOW_ORIGIN` | Semicolon-separated CORS allowlist. If unset and `WEBUI_URL` is set, it defaults to `WEBUI_URL`. | unset |
| `ENABLE_WEB_SEARCH` | Enables Open WebUI web search | `True` |
| `WEB_SEARCH_ENGINE` | Open WebUI search provider | `searxng` |
| `WEB_SEARCH_RESULT_COUNT` | Results Open WebUI asks the search provider to crawl | `3` |
| `WEB_SEARCH_CONCURRENT_REQUESTS` | Concurrent Open WebUI web fetch requests | `10` |
| `SEARXNG_PORT` | Local SearXNG bind port | `18080` |
| `SEARXNG_QUERY_URL` | SearXNG URL used by Open WebUI. Override this for an external SearXNG instance. | `http://127.0.0.1:18080/search?q=<query>` |
| `SEARXNG_LANGUAGE` | SearXNG language sent by Open WebUI | `all` |
| `SEARXNG_READY_TIMEOUT` | Seconds to wait for bundled SearXNG startup | `60` |
| `RESET_CONFIG_ON_START` | Re-applies provider config on startup | `True` |

Set variables in RunPod under `Edit Pod/Template` > `Add Environment Variable`.

If `WEBUI_AUTH=False` does not take effect, clear the existing Open WebUI data volume first. Open WebUI keeps auth state in its database after first boot.

If you use a RunPod public URL, set `WEBUI_URL` to that exact URL. If users access the pod by multiple public addresses, set `CORS_ALLOW_ORIGIN` to a semicolon-separated allowlist that includes every valid origin.

For the bundled search path, leave `START_SEARXNG=True` and keep the default `SEARXNG_QUERY_URL`. To use a separate SearXNG instance instead, set `START_SEARXNG=False` and point `SEARXNG_QUERY_URL` at the external endpoint. The URL must include `/search?q=<query>`.

## RAG / Document Processing Stack

The image can start a local Open WebUI RAG stack:

- Qdrant for persistent vector storage under `/workspace/qdrant/storage`
- Docling Serve for document extraction and OCR
- `intfloat/multilingual-e5-large-instruct` as the default embedding model
- Open WebUI hybrid search enabled by default
- `BAAI/bge-reranker-v2-m3` as the default local reranker

Internal local URLs:

```text
Qdrant: http://127.0.0.1:6333
Docling: http://127.0.0.1:5001
```

These services bind to localhost and are not exposed through the nginx RunPod proxy. Do not add public RunPod ports for Qdrant or Docling unless you are intentionally managing access controls yourself.

RunPod env example:

```text
ENABLE_RAG_STACK=True
ENABLE_QDRANT=True
VECTOR_DB=qdrant
QDRANT_URI=http://127.0.0.1:6333
QDRANT_ON_DISK=True
QDRANT_TIMEOUT=10
ENABLE_DOCLING=True
CONTENT_EXTRACTION_ENGINE=docling
DOCLING_SERVER_URL=http://127.0.0.1:5001
DOCLING_PARAMS={"do_ocr":true,"ocr_engine":"tesseract","table_mode":"accurate"}
RAG_EMBEDDING_MODEL=intfloat/multilingual-e5-large-instruct
ENABLE_RAG_HYBRID_SEARCH=True
RAG_TOP_K=20
ENABLE_RERANKER=True
RAG_RERANKING_MODEL=BAAI/bge-reranker-v2-m3
RAG_TOP_K_RERANKER=5
RAG_RERANKING_BATCH_SIZE=8
```

Emergency disable:

```text
DISABLE_RAG_STACK=True
```

Low-memory config:

```text
ENABLE_DOCLING=False
ENABLE_RERANKER=False
RAG_TOP_K=8
RAG_RERANKING_BATCH_SIZE=2
```

Troubleshooting:

- Open WebUI uses PersistentConfig for some settings. After first boot, values saved in the Open WebUI database may override later environment changes. The launcher does not delete user data automatically.
- Only clear or edit the Open WebUI database if you understand the data-loss risk.
- `DOCLING_PARAMS` must be valid JSON. Invalid JSON fails startup before Open WebUI starts.
- Docling can use CPU heavily during OCR and table extraction, and first startup can be slow while models initialize. Keep `UVICORN_WORKERS=1`; multiple workers can cause Docling task routing errors without shared state.
- If Qdrant or Docling health does not become ready before the timeout, startup logs the failure and continues by default. Set `REQUIRE_RAG_SERVICES=True` only when you want the pod to fail fast during debugging.
- The local BGE reranker can use RAM/VRAM when Open WebUI loads it. Set `ENABLE_RERANKER=False` or reduce `RAG_RERANKING_BATCH_SIZE` if memory is tight.
- Qdrant data persists under `/workspace/qdrant/storage`. Back up that directory before changing vector database settings or rebuilding knowledge bases.

### Chat Template Overrides

Most GGUF instruction models already include a `tokenizer.chat_template`, and `llama-server` uses that metadata by default. Override the template only when the model card says to, when a converted GGUF is missing the template, or when chat completions produce malformed role formatting.

Use `LLAMA_SERVER_EXTRA_ARGS` for chat-template flags:

```text
# Llama 3 / 3.1 / 3.2 Instruct style
LLAMA_SERVER_EXTRA_ARGS=--chat-template llama3

# Llama 2 Chat style
LLAMA_SERVER_EXTRA_ARGS=--chat-template llama2
```

For a custom Jinja template, place the file somewhere persistent, for example `/workspace/templates/llama-custom.jinja`, then enable Jinja before the template file flag:

```text
LLAMA_SERVER_EXTRA_ARGS=--jinja --chat-template-file /workspace/templates/llama-custom.jinja
```

Do not put `--model`, `--alias`, `--mmproj`, `--host`, or `--port` in `LLAMA_SERVER_EXTRA_ARGS`; use `LLAMA_MODEL`, `LLAMA_ALIAS`, and `LLAMA_MMPROJ` for those values. To confirm the active template after boot, open the proxied API and check `/props`:

```text
https://<runpod-api-url>/props
```

### Boot-Time Download Examples

Recommended Qwen3-VL template model:

```text
HF_MODEL_REPO=unsloth/Qwen3-VL-4B-Instruct-GGUF
HF_MODEL_FILE=Qwen3-VL-4B-Instruct-Q4_K_M.gguf
HF_MMPROJ_FILE=mmproj-F16.gguf
LLAMA_MULTIMODAL_REQUIRED=True
LLAMA_ALIAS=qwen3-vl-4b-instruct-q4
HF_TOKEN=hf_xxx
```

This downloads only the Q4_K_M model file and the F16 projector instead of syncing every quant in the repo. The source repo is [unsloth/Qwen3-VL-4B-Instruct-GGUF](https://hf.co/unsloth/Qwen3-VL-4B-Instruct-GGUF).

Alternative official Qwen filenames:

```text
HF_MODEL_REPO=Qwen/Qwen3-VL-4B-Instruct-GGUF
HF_MODEL_FILE=Qwen3VL-4B-Instruct-Q4_K_M.gguf
HF_MMPROJ_FILE=mmproj-Qwen3VL-4B-Instruct-F16.gguf
LLAMA_MULTIMODAL_REQUIRED=True
LLAMA_ALIAS=qwen3-vl-4b-instruct-q4
HF_TOKEN=hf_xxx
```

Direct URLs with files kept under `/workspace/models`:

```text
WGET_MODEL_URL=https://huggingface.co/unsloth/Qwen3-VL-4B-Instruct-GGUF/resolve/main/Qwen3-VL-4B-Instruct-Q4_K_M.gguf?download=true
WGET_MODEL_FILENAME=qwen3-vl-4b/Qwen3-VL-4B-Instruct-Q4_K_M.gguf
WGET_MMPROJ_URL=https://huggingface.co/unsloth/Qwen3-VL-4B-Instruct-GGUF/resolve/main/mmproj-F16.gguf?download=true
WGET_MMPROJ_FILENAME=qwen3-vl-4b/mmproj-F16.gguf
LLAMA_MULTIMODAL_REQUIRED=True
LLAMA_ALIAS=qwen3-vl-4b-instruct-q4
HF_TOKEN=hf_xxx
```

If a repo contains multiple quants or shards, set `LLAMA_MODEL` to the exact file path after download. If the mmproj filename does not contain `mmproj`, set `LLAMA_MMPROJ` explicitly.

## Logs

| Component | Log Path |
| --- | --- |
| JupyterLab | `/workspace/logs/jupyterlab.log` |
| llama.cpp | `/workspace/logs/llama-server.log` |
| SearXNG | `/workspace/logs/searxng.log` |
| Qdrant | `/workspace/logs/qdrant.log` |
| Docling Serve | `/workspace/logs/docling.log` |
| Open WebUI | `/workspace/logs/open-webui.log` |
| Nginx access | `/workspace/logs/nginx-access.log` |
| Nginx error | `/workspace/logs/nginx-error.log` |

## Included Software

| Component | Version / Notes |
| --- | --- |
| Ubuntu | 22.04 |
| Python | 3.11 |
| PyTorch | 2.11.0 |
| CUDA images | 12.4 through 13.0 |
| Inference backend | `llama.cpp` |
| Search backend | SearXNG |
| Vector database | Qdrant |
| Document extraction | Docling Serve |
| UI | Open WebUI |
| Extras | JupyterLab, `hf`, `wget`, `nvtop` |

## References

- [Open WebUI llama.cpp quick start](https://docs.openwebui.com/getting-started/quick-start/starting-with-llama-cpp/)
- [Open WebUI environment configuration](https://docs.openwebui.com/reference/env-configuration/)
- [Open WebUI Docling extraction](https://docs.openwebui.com/features/rag/document-extraction/docling/)
- [Open WebUI SearXNG provider](https://docs.openwebui.com/features/chat-conversations/web-search/providers/searxng/)
- [Docling Serve](https://github.com/docling-project/docling-serve)
- [Qdrant installation](https://qdrant.tech/documentation/installation/)
- [SearXNG container installation](https://docs.searxng.org/admin/installation-docker.html)
- [SearXNG search API](https://docs.searxng.org/dev/search_api.html)
- [llama.cpp server documentation](https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md)
- [llama.cpp chat templates wiki](https://github.com/ggml-org/llama.cpp/wiki/Templates-supported-by-llama_chat_apply_template)
- [Qwen3-VL-4B-Instruct GGUF on Hugging Face](https://hf.co/unsloth/Qwen3-VL-4B-Instruct-GGUF)

Feedback & issues: [GitHub Issues](https://github.com/N3K00OO/LLAMA-Open-WebUi/issues)
