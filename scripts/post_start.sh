#!/bin/bash

set -uo pipefail

DOWNLOADED_MODEL_PATH=""
DOWNLOADED_MMPROJ_PATH=""

log() {
  echo "***** $* *****"
}

is_true() {
  case "${1:-}" in
    1|on|ON|On|true|TRUE|True|yes|YES|Yes)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

models_path() {
  local relative_path="${1:-}"
  relative_path="${relative_path#/}"

  if [ -z "${relative_path}" ] || [ "${relative_path}" = "." ]; then
    printf '/workspace/models\n'
    return 0
  fi

  printf '/workspace/models/%s\n' "${relative_path}"
}

basename_from_url() {
  local url="${1%%\?*}"
  url="${url%%#*}"
  basename "${url}"
}

download_hf_repo() {
  local repo_id="${HF_REPO_DOWNLOAD:-}"
  local repo_type="${HF_REPO_TYPE:-}"
  local revision="${HF_REPO_REVISION:-}"
  local local_dir=""
  local output=""
  local -a cmd=()

  if [ -z "${repo_id}" ]; then
    return 0
  fi

  local_dir="$(models_path "${repo_id}")"
  mkdir -p "${local_dir}"

  cmd=(hf download "${repo_id}" --local-dir "${local_dir}" --quiet)

  if [ -n "${repo_type}" ]; then
    cmd+=(--repo-type "${repo_type}")
  fi

  if [ -n "${revision}" ]; then
    cmd+=(--revision "${revision}")
  fi

  if [ -n "${HF_TOKEN:-}" ]; then
    cmd+=(--token "${HF_TOKEN}")
  fi

  if [ -n "${HF_REPO_INCLUDE:-}" ]; then
    cmd+=(--include "${HF_REPO_INCLUDE}")
  fi

  if [ -n "${HF_REPO_EXCLUDE:-}" ]; then
    cmd+=(--exclude "${HF_REPO_EXCLUDE}")
  fi

  if is_true "${MODEL_DOWNLOAD_FORCE:-}"; then
    cmd+=(--force-download)
  fi

  log "Downloading Hugging Face repo ${repo_id} into ${local_dir}"
  if ! output="$("${cmd[@]}")"; then
    log "Failed to download Hugging Face repo ${repo_id}"
    return 1
  fi

  log "Hugging Face repo ready at ${output}"
}

download_hf_file() {
  local asset_kind="$1"
  local repo_id="$2"
  local filename="$3"
  local repo_type="${4:-}"
  local revision="${5:-}"
  local local_dir=""
  local output=""
  local -a cmd=()

  local_dir="$(models_path "${repo_id}")"
  mkdir -p "${local_dir}"

  cmd=(hf download "${repo_id}" "${filename}" --local-dir "${local_dir}" --quiet)

  if [ -n "${repo_type}" ]; then
    cmd+=(--repo-type "${repo_type}")
  fi

  if [ -n "${revision}" ]; then
    cmd+=(--revision "${revision}")
  fi

  if [ -n "${HF_TOKEN:-}" ]; then
    cmd+=(--token "${HF_TOKEN}")
  fi

  if is_true "${MODEL_DOWNLOAD_FORCE:-}"; then
    cmd+=(--force-download)
  fi

  log "Downloading ${asset_kind} from Hugging Face repo ${repo_id}"
  if ! output="$("${cmd[@]}")"; then
    log "Failed to download ${asset_kind} from Hugging Face repo ${repo_id}"
    return 1
  fi

  log "Downloaded ${asset_kind} to ${output}"

  case "${asset_kind}" in
    model)
      DOWNLOADED_MODEL_PATH="${output}"
      ;;
    mmproj)
      DOWNLOADED_MMPROJ_PATH="${output}"
      ;;
  esac
}

download_requested_hf_files() {
  local mmproj_repo=""
  local mmproj_type=""
  local mmproj_revision=""

  if [ -n "${HF_MODEL_FILE:-}" ]; then
    if [ -z "${HF_MODEL_REPO:-}" ]; then
      log "HF_MODEL_FILE requires HF_MODEL_REPO."
      return 1
    fi

    if ! download_hf_file "model" "${HF_MODEL_REPO}" "${HF_MODEL_FILE}" "${HF_MODEL_TYPE:-}" "${HF_MODEL_REVISION:-${HF_REPO_REVISION:-}}"; then
      return 1
    fi
  fi

  if [ -z "${HF_MMPROJ_FILE:-}" ]; then
    return 0
  fi

  mmproj_repo="${HF_MMPROJ_REPO:-${HF_MODEL_REPO:-}}"
  mmproj_type="${HF_MMPROJ_TYPE:-${HF_MODEL_TYPE:-}}"
  mmproj_revision="${HF_MMPROJ_REVISION:-${HF_MODEL_REVISION:-${HF_REPO_REVISION:-}}}"

  if [ -z "${mmproj_repo}" ]; then
    log "HF_MMPROJ_FILE requires HF_MMPROJ_REPO or HF_MODEL_REPO."
    return 1
  fi

  download_hf_file "mmproj" "${mmproj_repo}" "${HF_MMPROJ_FILE}" "${mmproj_type}" "${mmproj_revision}"
}

download_wget_asset() {
  local asset_kind="$1"
  local asset_url="$2"
  local asset_filename="${3:-}"
  local resolved_filename="${asset_filename}"
  local target_path=""
  local partial_path=""
  local -a cmd=()

  if [ -z "${asset_url}" ]; then
    return 0
  fi

  if [ -z "${resolved_filename}" ]; then
    resolved_filename="$(basename_from_url "${asset_url}")"
  fi

  if [ -z "${resolved_filename}" ]; then
    log "Unable to determine a filename for ${asset_kind} download URL: ${asset_url}"
    return 1
  fi

  target_path="$(models_path "${resolved_filename}")"
  partial_path="${target_path}.part"

  mkdir -p "$(dirname "${target_path}")"

  if [ -f "${target_path}" ] && ! is_true "${MODEL_DOWNLOAD_FORCE:-}"; then
    log "${asset_kind} already exists at ${target_path}. Set MODEL_DOWNLOAD_FORCE=True to refresh it."
  else
    cmd=(wget -O "${partial_path}")

    if [ -n "${HF_TOKEN:-}" ] && [[ "${asset_url}" == https://huggingface.co/* || "${asset_url}" == http://huggingface.co/* ]]; then
      cmd+=(--header "Authorization: Bearer ${HF_TOKEN}")
    fi

    cmd+=("${asset_url}")

    log "Downloading ${asset_kind} from ${asset_url} to ${target_path}"
    if ! "${cmd[@]}"; then
      rm -f "${partial_path}"
      log "Failed to download ${asset_kind} from ${asset_url}"
      return 1
    fi

    mv "${partial_path}" "${target_path}"
  fi

  case "${asset_kind}" in
    model)
      DOWNLOADED_MODEL_PATH="${target_path}"
      ;;
    mmproj)
      DOWNLOADED_MMPROJ_PATH="${target_path}"
      ;;
  esac
}

download_requested_assets() {
  if ! download_hf_repo; then
    return 1
  fi

  if ! download_requested_hf_files; then
    return 1
  fi

  if ! download_wget_asset "model" "${WGET_MODEL_URL:-}" "${WGET_MODEL_FILENAME:-}"; then
    return 1
  fi

  download_wget_asset "mmproj" "${WGET_MMPROJ_URL:-}" "${WGET_MMPROJ_FILENAME:-}"
}

auto_detect_llama_model() {
  local -a gguf_models=()
  mapfile -t gguf_models < <(find /workspace/models -type f -iname '*.gguf' ! -iname '*mmproj*.gguf' | sort)

  if [ "${#gguf_models[@]}" -eq 1 ]; then
    printf '%s\n' "${gguf_models[0]}"
    return 0
  fi

  if [ "${#gguf_models[@]}" -gt 1 ]; then
    log "Found multiple GGUF files under /workspace/models. Set LLAMA_MODEL to the exact file you want."
  fi

  return 1
}

auto_detect_mmproj() {
  local -a mmproj_models=()
  mapfile -t mmproj_models < <(find /workspace/models -type f -iname '*mmproj*.gguf' | sort)

  if [ "${#mmproj_models[@]}" -eq 1 ]; then
    printf '%s\n' "${mmproj_models[0]}"
    return 0
  fi

  if [ "${#mmproj_models[@]}" -gt 1 ]; then
    log "Found multiple mmproj files under /workspace/models. Set LLAMA_MMPROJ to the exact file you want."
  fi

  return 1
}

model_source_in_extra_args() {
  case " ${LLAMA_SERVER_EXTRA_ARGS:-} " in
    *" -m "*|*" --model "*|*" -hf "*|*" --hf-repo "*|*" --hf-file "*|*" --model-url "*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

mmproj_source_in_extra_args() {
  case " ${LLAMA_SERVER_EXTRA_ARGS:-} " in
    *" --mmproj "*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

start_llama_server() {
  local model_path=""
  local model_alias="${LLAMA_ALIAS:-}"
  local mmproj_path=""
  local -a cmd=(./llama-server --host 0.0.0.0 --port 11434 --ctx-size "${LLAMA_CTX_SIZE:-4096}" --parallel "${LLAMA_PARALLEL:-1}")
  local -a extra_args=()

  if ! download_requested_assets; then
    log "Model download step failed. Skipping llama.cpp startup."
    return
  fi

  model_path="${LLAMA_MODEL:-${DOWNLOADED_MODEL_PATH:-}}"
  mmproj_path="${LLAMA_MMPROJ:-${DOWNLOADED_MMPROJ_PATH:-}}"

  if [ -z "${model_path}" ]; then
    model_path="$(auto_detect_llama_model || true)"
  fi

  if [ -z "${mmproj_path}" ] && ! mmproj_source_in_extra_args; then
    mmproj_path="$(auto_detect_mmproj || true)"
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

  if [ -n "${mmproj_path}" ] && ! mmproj_source_in_extra_args; then
    if [ ! -f "${mmproj_path}" ]; then
      log "LLAMA_MMPROJ points to a missing file: ${mmproj_path}"
      return
    fi

    cmd+=(--mmproj "${mmproj_path}")
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
