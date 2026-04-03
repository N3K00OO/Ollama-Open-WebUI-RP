[![Build and Publish GHCR Images](https://github.com/N3K00OO/Ollama-Open-WebUI-RP/actions/workflows/build.yml/badge.svg)](https://github.com/N3K00OO/Ollama-Open-WebUI-RP/actions/workflows/build.yml)

> Updated by GitHub Actions every 5 days and built against the latest official `llama.cpp` and Open WebUI releases at build time.
>
> This image runs `./llama-server` locally and points Open WebUI at its OpenAI-compatible `/v1` API.
> Put your GGUF model in `/workspace/models` and either set `LLAMA_MODEL` or keep a single `*.gguf` file there for auto-detection.

### Exposed Ports

| Port | Type | Purpose    |
| ---- | ---- | ---------- |
| 22   | TCP  | SSH        |
| 8081 | HTTP | Open WebUI |
| 11435 | HTTP | llama.cpp API proxy |
| 8889 | HTTP | JupyterLab |

### Tag Structure

* `cu126`, `cu128`, `cu130`: CUDA version (12.6 / 12.8 / 13.0)

---

### Image Matrix

| Image Name | CUDA |
| ---------- | ---- |
| `ghcr.io/n3k00oo/ollama-open-webui-rp:base-torch2.11.0-cu126` | 12.6 |
| `ghcr.io/n3k00oo/ollama-open-webui-rp:base-torch2.11.0-cu128` | 12.8 |
| `ghcr.io/n3k00oo/ollama-open-webui-rp:base-torch2.11.0-cu130` | 13.0 |

Images are published to GitHub Container Registry by GitHub Actions. No Docker Hub secrets are required.
The package path stays the same because the GitHub repository name is unchanged.

To change images: go to **Edit Pod/Template** -> set `Container Image`.

---

### Environment Variables

| Variable              | Description                                                                                                                          | Default             |
| --------------------- | ------------------------------------------------------------------------------------------------------------------------------------ | ------------------- |
| `JUPYTERLAB_PASSWORD` | Password for JupyterLab                                                                                                              | (unset)             |
| `TIME_ZONE`           | [Timezone](https://en.wikipedia.org/wiki/List_of_tz_database_time_zones) (for example, `Asia/Seoul`)                               | `Etc/UTC`           |
| `START_LLAMA_SERVER`  | Starts `./llama-server` during container boot. (`True` / `False`)                                                                    | `True`              |
| `LLAMA_MODEL`         | Absolute path to a GGUF file. If unset, the startup script auto-detects a single `*.gguf` file in `/workspace/models`.             | (auto-detect)       |
| `LLAMA_ALIAS`         | Optional model name shown by the OpenAI-compatible `/v1/models` endpoint and Open WebUI.                                            | GGUF filename       |
| `LLAMA_CTX_SIZE`      | Context window passed to `./llama-server --ctx-size`.                                                                                | `4096`              |
| `LLAMA_GPU_LAYERS`    | GPU offload setting passed to `./llama-server --n-gpu-layers`.                                                                       | `999`               |
| `LLAMA_PARALLEL`      | Parallel request slots passed to `./llama-server --parallel`.                                                                        | `1`                 |
| `LLAMA_SERVER_API_KEY`| Optional API key enforced by `./llama-server --api-key`. Open WebUI reuses the same value automatically.                            | (unset)             |
| `LLAMA_SERVER_EXTRA_ARGS` | Extra flags appended to `./llama-server` for advanced setups.                                                                    | (unset)             |
| `DATA_DIR`            | (Open WebUI) Base directory for data storage.                                                                                        | `/workspace/data`   |
| `WEBUI_AUTH`          | (Open WebUI) Enables or disables authentication. Set to `False` to run in single-user mode (no login required). (`True` / `False`) | `False`             |
| `RESET_CONFIG_ON_START` | Forces Open WebUI to re-apply environment-provided provider settings on every start, which avoids stale saved connection settings. | `True`              |

To set: **Edit Pod/Template** -> **Add Environment Variable** (key/value).

> For additional environment variables, refer to the official [Open WebUI environment documentation](https://docs.openwebui.com/reference/env-configuration/) and the official [llama.cpp server documentation](https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md).
>
> For `WEBUI_AUTH`, setting it to `False` disables authentication.
> This only works on fresh installations with no registered users.
> If users already exist, clear the database before disabling authentication.

### Logs

| App        | Location                       |
| ---------- | ------------------------------ |
| JupyterLab | `/workspace/logs/jupyterlab.log` |
| llama.cpp  | `/workspace/logs/llama-server.log` |
| Open WebUI | `/workspace/logs/open-webui.log`   |

---

### Pre-Installed Components

#### System

* **OS**: Ubuntu 22.04
* **Python**: 3.11
* **Framework**: llama.cpp + Open WebUI + JupyterLab
* **Libraries**: PyTorch 2.11.0, CUDA (12.6-13.0), Triton, [hf_hub](https://huggingface.co/docs/huggingface_hub), [nvtop](https://github.com/Syllo/nvtop)

---

Feedback & Issues -> [GitHub Issues](https://github.com/N3K00OO/Ollama-Open-WebUI-RP/issues)

---
