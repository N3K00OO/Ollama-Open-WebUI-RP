[![Build and Publish GHCR Images](https://github.com/N3K00OO/LLAMA-Open-WebUi/actions/workflows/build.yml/badge.svg)](https://github.com/N3K00OO/LLAMA-Open-WebUi/actions/workflows/build.yml)

# LLAMA Open WebUI

This image is a llama-only RunPod base image:

- `llama.cpp` is built in CI and started as `./llama-server`
- Open WebUI is wired to the local OpenAI-compatible `/v1` endpoint
- JupyterLab is included for notebook and terminal access

GitHub Actions refreshes upstream `llama.cpp` and Open WebUI versions at build time, runs a container smoke test for the launcher and proxy, pushes the images to GHCR, and verifies each published tag before the workflow passes.

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

Place GGUF models in:

```text
/workspace/models
```

Startup behavior:

- configured Hugging Face and `wget` downloads run before `llama-server` starts, so the pod does not need a second boot
- V100 / compute capability `7.0` is allowed on the `cu124`, `cu125`, `cu126`, and `cu128` images, but blocked by default on `cu130` unless `LLAMA_ALLOW_UNSUPPORTED_GPU=True`
- `llama-server` is always launched on `127.0.0.1:11434`, never on `8080`
- if there is exactly one non-mmproj `*.gguf` file anywhere under `/workspace/models`, it is used as the explicit `--model`
- if there is exactly one `*mmproj*.gguf` file anywhere under `/workspace/models`, it is used as the explicit `--mmproj`
- `LLAMA_ALIAS` is always passed explicitly; if unset, it is derived from the resolved GGUF filename
- if `LLAMA_MULTIMODAL_REQUIRED=True`, startup fails unless `LLAMA_MMPROJ` resolves to a real file
- the launcher waits for `/v1/models` to become ready and treats HTTP `503 Loading model` as startup-in-progress
- if `llama-server` exits unexpectedly, the supervisor restarts it and keeps appending to `/workspace/logs/llama-server.log`
- Open WebUI uses the local llama.cpp endpoint
- the public Open WebUI proxy on `8081` is WebSocket-safe and preserves real upstream API failure codes

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
| `START_LLAMA_SERVER` | Starts `./llama-server` on boot | `True` |
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
| `RESET_CONFIG_ON_START` | Re-applies provider config on startup | `True` |

Set variables in RunPod under `Edit Pod/Template` > `Add Environment Variable`.

If `WEBUI_AUTH=False` does not take effect, clear the existing Open WebUI data volume first. Open WebUI keeps auth state in its database after first boot.

If you use a RunPod public URL, set `WEBUI_URL` to that exact URL. If users access the pod by multiple public addresses, set `CORS_ALLOW_ORIGIN` to a semicolon-separated allowlist that includes every valid origin.

### Boot-Time Download Examples

Whole Hugging Face repo:

```text
HF_REPO_DOWNLOAD=unsloth/Qwen2.5-VL-7B-Instruct-GGUF
HF_TOKEN=hf_xxx
```

One GGUF plus one mmproj from Hugging Face:

```text
HF_MODEL_REPO=unsloth/Qwen2.5-VL-7B-Instruct-GGUF
HF_MODEL_FILE=Qwen2.5-VL-7B-Instruct-Q4_K_M.gguf
HF_MMPROJ_FILE=mmproj-Qwen2.5-VL-7B-Instruct-f16.gguf
HF_TOKEN=hf_xxx
```

Direct URLs with files kept under `/workspace/models`:

```text
WGET_MODEL_URL=https://huggingface.co/owner/repo/resolve/main/model.gguf?download=true
WGET_MODEL_FILENAME=qwen/model.gguf
WGET_MMPROJ_URL=https://huggingface.co/owner/repo/resolve/main/mmproj-model-f16.gguf?download=true
WGET_MMPROJ_FILENAME=qwen/mmproj-model-f16.gguf
HF_TOKEN=hf_xxx
```

If a repo contains multiple quants or shards, set `LLAMA_MODEL` to the exact file path after download. If the mmproj filename does not contain `mmproj`, set `LLAMA_MMPROJ` explicitly.

## Logs

| Component | Log Path |
| --- | --- |
| JupyterLab | `/workspace/logs/jupyterlab.log` |
| llama.cpp | `/workspace/logs/llama-server.log` |
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
| UI | Open WebUI |
| Extras | JupyterLab, `hf`, `wget`, `nvtop` |

## References

- [Open WebUI llama.cpp quick start](https://docs.openwebui.com/getting-started/quick-start/starting-with-llama-cpp/)
- [Open WebUI environment configuration](https://docs.openwebui.com/reference/env-configuration/)
- [llama.cpp server documentation](https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md)

Feedback & issues: [GitHub Issues](https://github.com/N3K00OO/LLAMA-Open-WebUi/issues)
