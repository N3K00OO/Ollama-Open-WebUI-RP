#!/bin/bash

set -uo pipefail

log() {
  echo "***** $* *****"
}

auto_detect_llama_model() {
  local -a gguf_models=()
  mapfile -t gguf_models < <(find /workspace/models -maxdepth 1 -type f -iname '*.gguf' | sort)

  if [ "${#gguf_models[@]}" -eq 1 ]; then
    printf '%s\n' "${gguf_models[0]}"
    return 0
  fi

  if [ "${#gguf_models[@]}" -gt 1 ]; then
    log "Found multiple GGUF files in /workspace/models. Set LLAMA_MODEL to the one you want."
  fi

  return 1
}

model_source_in_extra_args() {
  case " ${LLAMA_SERVER_EXTRA_ARGS:-} " in
    *" -m "*|*" --model "*|*" --hf-repo "*|*" --model-url "*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

start_llama_server() {
  local model_path="${LLAMA_MODEL:-}"
  local model_alias="${LLAMA_ALIAS:-}"
  local -a cmd=(./llama-server --host 0.0.0.0 --port 11434 --ctx-size "${LLAMA_CTX_SIZE:-4096}" --parallel "${LLAMA_PARALLEL:-1}")
  local -a extra_args=()

  if [ -z "${model_path}" ]; then
    model_path="$(auto_detect_llama_model || true)"
  fi

  if [ -n "${LLAMA_GPU_LAYERS:-}" ]; then
    cmd+=(--n-gpu-layers "${LLAMA_GPU_LAYERS}")
  fi

  if [ -n "${LLAMA_SERVER_API_KEY:-}" ]; then
    cmd+=(--api-key "${LLAMA_SERVER_API_KEY}")
  fi

  if [ -n "${model_path}" ]; then
    if [ ! -f "${model_path}" ]; then
      log "LLAMA_MODEL points to a missing file: ${model_path}"
      return
    fi

    if [ -z "${model_alias}" ]; then
      model_alias="$(basename "${model_path}")"
      model_alias="${model_alias%.gguf}"
    fi

    cmd+=(--model "${model_path}" --alias "${model_alias}")
  elif ! model_source_in_extra_args; then
    log "No GGUF model configured. Set LLAMA_MODEL or pass model flags in LLAMA_SERVER_EXTRA_ARGS."
    return
  fi

  if [ -n "${LLAMA_SERVER_EXTRA_ARGS:-}" ]; then
    read -r -a extra_args <<< "${LLAMA_SERVER_EXTRA_ARGS}"
    cmd+=("${extra_args[@]}")
  fi

  log "Starting llama.cpp server..."
  (
    cd / || exit 1
    "${cmd[@]}"
  ) > /workspace/logs/llama-server.log 2>&1 &
  log "llama.cpp server started and logging to /workspace/logs/llama-server.log"
}

mkdir -p /workspace/logs /workspace/models /workspace/data

export ENABLE_OPENAI_API=True
export ENABLE_OLLAMA_API=False
export OPENAI_API_BASE_URL="http://127.0.0.1:11434/v1"
export OPENAI_API_KEY="${LLAMA_SERVER_API_KEY:-sk-no-key-required}"
export RESET_CONFIG_ON_START="${RESET_CONFIG_ON_START:-True}"

if [ "${START_LLAMA_SERVER,,}" = "true" ]; then
  start_llama_server
else
  log "START_LLAMA_SERVER is not set to TRUE. Skipping llama.cpp server start."
fi

log "Starting Open WebUI server..."
open-webui serve > /workspace/logs/open-webui.log 2>&1 &
log "Open WebUI server started and logging to /workspace/logs/open-webui.log"
