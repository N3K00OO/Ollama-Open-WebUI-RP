# LLAMA Open WebUI

`LLAMA Open WebUI` is a fork of [somb1/Ollama-Open-WebUI-RP](https://github.com/somb1/Ollama-Open-WebUI-RP), reworked into a `llama.cpp`-focused project with Open WebUI, JupyterLab, and GHCR-based image publishing.

## Important

This RunPod Hub package is a lightweight compatibility worker for Hub indexing and validation.

It is **not** the full Pod runtime. The main product is the GHCR Pod image:

```text
ghcr.io/n3k00oo/llama-open-webui
```

Recommended default tag:

```text
ghcr.io/n3k00oo/llama-open-webui:base-torch2.11.0-cu128
```

## Main Project Links

- GitHub: <https://github.com/N3K00OO/LLAMA-Open-WebUi>
- Issues: <https://github.com/N3K00OO/LLAMA-Open-WebUi/issues>
- GHCR package: <https://github.com/N3K00OO/LLAMA-Open-WebUi/pkgs/container/llama-open-webui>
- Original upstream: <https://github.com/somb1/Ollama-Open-WebUI-RP>

## Full Pod Runtime

The full image provides:

- `llama.cpp` started as `./llama-server`
- Open WebUI wired to the local OpenAI-compatible `/v1` endpoint
- JupyterLab for notebooks and terminal access
- boot-time Hugging Face and `wget` model downloads
- fast startup by default using the bundled `/venv`; set `SYNC_VENV_TO_WORKSPACE=True` only when you need a workspace venv copy
- optional local RAG stack with Qdrant, Docling Serve, hybrid search, multilingual embeddings, and BGE reranking

Recommended ports for the Pod image:

- `8081` for Open WebUI
- `11435` for the proxied llama.cpp API
- `8889` for JupyterLab

Recommended Qwen3-VL template model:

```text
HF_MODEL_REPO=unsloth/Qwen3-VL-4B-Instruct-GGUF
HF_MODEL_FILE=Qwen3-VL-4B-Instruct-Q4_K_M.gguf
HF_MMPROJ_FILE=mmproj-F16.gguf
LLAMA_MULTIMODAL_REQUIRED=True
LLAMA_ALIAS=qwen3-vl-4b-instruct-q4
```

Source model: <https://hf.co/unsloth/Qwen3-VL-4B-Instruct-GGUF>

If a Llama-family GGUF needs a chat-template override, set it through `LLAMA_SERVER_EXTRA_ARGS`:

```text
LLAMA_SERVER_EXTRA_ARGS=--chat-template llama3
LLAMA_SERVER_EXTRA_ARGS=--chat-template llama2
LLAMA_SERVER_EXTRA_ARGS=--jinja --chat-template-file /workspace/templates/llama-custom.jinja
```

Most GGUFs already include `tokenizer.chat_template`, so override this only when the model card or generated chat formatting requires it.

RAG services bind locally by default:

```text
QDRANT_URI=http://127.0.0.1:6333
DOCLING_SERVER_URL=http://127.0.0.1:5001
RAG_EMBEDDING_MODEL=intfloat/multilingual-e5-large-instruct
RAG_RERANKING_MODEL=BAAI/bge-reranker-v2-m3
DISABLE_RAG_STACK=True
```

Do not expose Qdrant or Docling as public RunPod ports unless you are intentionally managing access controls yourself.

## Hub Worker API

This Hub worker supports two simple actions:

- `health`
- `repo_info`

Example:

```json
{
  "action": "repo_info"
}
```

Use this Hub entry for repository discovery and compatibility. Use the GHCR Pod image for the real WebUI deployment path.
