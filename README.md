[![Build and Push Docker Images](https://github.com/somb1/Ollama-Open-WebUI-RP/actions/workflows/build.yml/badge.svg)](https://github.com/somb1/Ollama-Open-WebUI-RP/actions/workflows/build.yml)

> 🔄 Updated every 8 hours to always stay on the latest version.

> In Open WebUI, Use the "Select a model" menu (top-left) to search and pull models from ollama.com. \
> You can find a list of available models at <https://ollama.com/models> \
> If a model is not available there, you can manually download it from Hugging Face and import it.

### 🔌 Exposed Ports

| Port | Type | Purpose    |
| ---- | ---- | ---------- |
| 22   | TCP  | SSH        |
| 8080 | HTTP | Open WebUI |
| 8888 | HTTP | JupyterLab |

### 🏷️ Tag Structure

* `cu124`, `cu126`, `cu128`: CUDA version (12.4 / 12.6 / 12.8)

---

### 🧱 Image Matrix

| Image Name                                      | CUDA |
| ----------------------------------------------- | ---- |
| `ghcr.io/somb1/ollama-open-webui-rp:base-torch2.7.0-cu124` | 12.4 |
| `ghcr.io/somb1/ollama-open-webui-rp:base-torch2.7.0-cu126` | 12.6 |
| `ghcr.io/somb1/ollama-open-webui-rp:base-torch2.7.0-cu128` | 12.8 |

To change images: Go to **Edit Pod/Template** → Set `Container Image`.

---

### ⚙️ Environment Variables

| Variable              | Description                                                                                                                        | Default             |
| --------------------- | ---------------------------------------------------------------------------------------------------------------------------------- | ------------------- |
| `JUPYTERLAB_PASSWORD` | Password for JupyterLab                                                                                                            | (unset)             |
| `TIME_ZONE`           | [Timezone](https://en.wikipedia.org/wiki/List_of_tz_database_time_zones) (e.g., `Asia/Seoul`)                                      | `Etc/UTC`           |
| `START_OLLAMA`        | Starts the Ollama server at start. (`True` / `False`)                                                                              | `True`              |
| `OLLAMA_HOST`         | (Ollama) Configures the host and scheme for the Ollama server.                                                                     | `0.0.0.0`           |
| `OLLAMA_MODELS`       | (Ollama) Path to the models directory.                                                                                             | `/workspace/models` |
| `DATA_DIR`            | (Open WebUI) Base directory for data storage.                                                                                      | `/workspace/data`   |
| `WEBUI_AUTH`          | (Open WebUI) Enables or disables authentication. Set to `False` to run in Single-User Mode (no login required). (`True` / `False`) | `False`             |

To set: **Edit Pod/Template** → **Add Environment Variable** (Key/Value)

> For additional environment variables, refer to the documentation for [**Ollama**](https://github.com/ollama/ollama/issues/2941#issuecomment-2322778733) and [**Open WebUI**](https://docs.openwebui.com/getting-started/env-configuration).

> For `WEBUI_AUTH`, setting it to `False` disables authentication. \
> This only works on **fresh installations with no registered users**. \
> If users already exist, you must **clear the database** before disabling authentication.

### 📁 Logs

| App        | Location                       |
|------------|--------------------------------|
| JupyterLab | /workspace/logs/jupyterlab.log |
| Ollama     | /workspace/logs/ollama.log     |

---

### 🧩 Pre-Installed Components

#### **System**

* **OS**: Ubuntu 22.04
* **Python**: 3.11
* **Framework**: Ollama + Open WebUI + JupyterLab
* **Libraries**: PyTorch 2.7.0, CUDA (12.4–12.8), Triton, [hf\_hub](https://huggingface.co/docs/huggingface_hub), [nvtop](https://github.com/Syllo/nvtop)

---

💬 Feedback & Issues → [GitHub Issues](https://github.com/somb1/Ollama-Open-WebUI-RP/issues)

---
