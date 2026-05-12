#!/bin/bash

set -uo pipefail

LLAMA_LOG_PATH="/workspace/logs/llama-server.log"
OPENWEBUI_LOG_PATH="/workspace/logs/open-webui.log"
SEARXNG_LOG_PATH="/workspace/logs/searxng.log"
QDRANT_LOG_PATH="/workspace/logs/qdrant.log"
DOCLING_LOG_PATH="/workspace/logs/docling.log"
LLAMA_READY_MARKER="/workspace/logs/llama-server.ready"
LLAMA_FAILED_MARKER="/workspace/logs/llama-server.failed"
LLAMA_SUPERVISOR_PID_FILE="/workspace/logs/llama-supervisor.pid"
DOWNLOADED_MODEL_PATH=""
DOWNLOADED_MMPROJ_PATH=""
RESOLVED_MODEL_PATH=""
RESOLVED_MODEL_ALIAS=""
RESOLVED_MMPROJ_PATH=""
LLAMA_SERVER_PID=""
LLAMA_SUPERVISOR_PID=""
READY_HTTP_CODE=""
READY_BODY=""
GPU_NAME=""
GPU_COMPUTE_CAPABILITY=""
SEARXNG_PID=""
SEARXNG_READY_HTTP_CODE=""
SEARXNG_READY_BODY=""
QDRANT_PID=""
DOCLING_PID=""
declare -a LLAMA_CMD=()

timestamp() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

log() {
  printf '%s ***** %s *****\n' "$(timestamp)" "$*" >&2
}

log_llama() {
  log "$*"
  printf '%s %s\n' "$(timestamp)" "$*" >> "${LLAMA_LOG_PATH}"
}

trim() {
  local value="$*"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "${value}"
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

redact_secret() {
  local value="${1:-}"

  if [ -z "${value}" ]; then
    printf '<empty>'
    return 0
  fi

  printf '<redacted>'
}

wait_for_http() {
  local name="$1"
  local url="$2"
  local timeout="${3:-60}"
  local interval="${4:-2}"
  local log_path="${5:-/dev/null}"
  local elapsed=0
  local status_code="000"

  while [ "${elapsed}" -lt "${timeout}" ]; do
    status_code="$(curl -sS --max-time 5 -o /dev/null -w '%{http_code}' "${url}" 2>>"${log_path}" || true)"
    case "${status_code}" in
      200|204)
        log "${name} is ready at ${url}."
        return 0
        ;;
    esac

    if [ "${elapsed}" -eq 0 ]; then
      log "Waiting for ${name} at ${url}."
    fi

    sleep "${interval}"
    elapsed=$((elapsed + interval))
  done

  log "Timed out after ${timeout}s waiting for ${name} at ${url}."
  return 1
}

rag_stack_enabled() {
  if is_true "${DISABLE_RAG_STACK:-False}"; then
    return 1
  fi

  is_true "${ENABLE_RAG_STACK:-True}"
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

reset_launcher_state() {
  DOWNLOADED_MODEL_PATH=""
  DOWNLOADED_MMPROJ_PATH=""
  RESOLVED_MODEL_PATH=""
  RESOLVED_MODEL_ALIAS=""
  RESOLVED_MMPROJ_PATH=""
  READY_HTTP_CODE=""
  READY_BODY=""
  GPU_NAME=""
  GPU_COMPUTE_CAPABILITY=""
  LLAMA_CMD=()
}

ensure_runtime_paths() {
  mkdir -p /workspace/logs /workspace/models /workspace/data /workspace/searxng-cache /workspace/qdrant/storage /workspace/docling/artifacts
  : > "${LLAMA_LOG_PATH}"
  : > "${SEARXNG_LOG_PATH}"
  : > "${QDRANT_LOG_PATH}"
  : > "${DOCLING_LOG_PATH}"
  rm -f "${LLAMA_READY_MARKER}" "${LLAMA_FAILED_MARKER}" "${LLAMA_SUPERVISOR_PID_FILE}"
}

validate_json_env() {
  local name="$1"
  local value="$2"

  python - "${name}" "${value}" <<'PY'
import json
import sys

name, value = sys.argv[1], sys.argv[2]
try:
    json.loads(value)
except json.JSONDecodeError as exc:
    print(f"{name} is not valid JSON: {exc}", file=sys.stderr)
    raise SystemExit(1)
PY
}

normalize_json_env() {
  local name="$1"
  local value="$2"
  local normalized=""

  normalized="$(python - "${name}" "${value}" <<'PY'
import json
import sys

name, value = sys.argv[1], sys.argv[2]
for candidate in (value, value.strip("'\"")):
    try:
        json.loads(candidate)
    except json.JSONDecodeError:
        continue
    print(candidate)
    raise SystemExit(0)

try:
    json.loads(value)
except json.JSONDecodeError as exc:
    print(f"{name} is not valid JSON: {exc}", file=sys.stderr)
raise SystemExit(1)
PY
  )" || return 1

  printf -v "${name}" '%s' "${normalized}"
  export "${name}"
}

unset_openwebui_rag_env() {
  unset VECTOR_DB
  unset QDRANT_URI QDRANT_API_KEY QDRANT_ON_DISK QDRANT_TIMEOUT
  unset CONTENT_EXTRACTION_ENGINE DOCLING_SERVER_URL DOCLING_PARAMS
  unset RAG_EMBEDDING_MODEL RAG_TOP_K ENABLE_RAG_HYBRID_SEARCH
  unset RAG_RERANKING_MODEL RAG_TOP_K_RERANKER RAG_RERANKING_BATCH_SIZE
}

configure_openwebui_rag_env() {
  if ! rag_stack_enabled; then
    log "RAG stack is disabled. Qdrant, Docling, hybrid search, and reranking env defaults will not be forced."
    unset_openwebui_rag_env
    return 0
  fi

  if is_true "${ENABLE_QDRANT:-True}"; then
    export VECTOR_DB="${VECTOR_DB:-qdrant}"
    export QDRANT_URI="${QDRANT_URI:-http://127.0.0.1:6333}"
    export QDRANT_ON_DISK="${QDRANT_ON_DISK:-True}"
    export QDRANT_TIMEOUT="${QDRANT_TIMEOUT:-10}"
    if [ -n "${QDRANT_API_KEY:-}" ]; then
      export QDRANT_API_KEY
    fi
  else
    unset VECTOR_DB QDRANT_URI QDRANT_API_KEY QDRANT_ON_DISK QDRANT_TIMEOUT
  fi

  export RAG_EMBEDDING_MODEL="${RAG_EMBEDDING_MODEL:-intfloat/multilingual-e5-large-instruct}"
  export RAG_TOP_K="${RAG_TOP_K:-20}"
  export ENABLE_RAG_HYBRID_SEARCH="${ENABLE_RAG_HYBRID_SEARCH:-True}"

  if is_true "${ENABLE_DOCLING:-True}"; then
    export CONTENT_EXTRACTION_ENGINE="${CONTENT_EXTRACTION_ENGINE:-docling}"
    export DOCLING_SERVER_URL="${DOCLING_SERVER_URL:-http://127.0.0.1:5001}"
    export DOCLING_PARAMS="${DOCLING_PARAMS:-{\"do_ocr\":true,\"ocr_engine\":\"tesseract\",\"table_mode\":\"accurate\"}}"
    if ! normalize_json_env "DOCLING_PARAMS" "${DOCLING_PARAMS}"; then
      return 1
    fi
  else
    unset CONTENT_EXTRACTION_ENGINE DOCLING_SERVER_URL DOCLING_PARAMS
  fi

  if is_true "${ENABLE_RERANKER:-True}"; then
    export RAG_RERANKING_MODEL="${RAG_RERANKING_MODEL:-BAAI/bge-reranker-v2-m3}"
    export RAG_TOP_K_RERANKER="${RAG_TOP_K_RERANKER:-5}"
    export RAG_RERANKING_BATCH_SIZE="${RAG_RERANKING_BATCH_SIZE:-8}"
  else
    unset RAG_RERANKING_MODEL RAG_TOP_K_RERANKER RAG_RERANKING_BATCH_SIZE
  fi

  log "Configured Open WebUI RAG defaults: stack=enabled, qdrant=${ENABLE_QDRANT:-True}, docling=${ENABLE_DOCLING:-True}, hybrid=${ENABLE_RAG_HYBRID_SEARCH}, reranker=${ENABLE_RERANKER:-True}."
}

configure_openwebui_runtime_env() {
  export ENABLE_OPENAI_API=True
  export ENABLE_OLLAMA_API=False
  export OPENAI_API_BASE_URL="http://127.0.0.1:11434/v1"
  export OPENAI_API_KEY="${LLAMA_SERVER_API_KEY:-sk-no-key-required}"
  export RESET_CONFIG_ON_START="${RESET_CONFIG_ON_START:-True}"

  if [ -n "${WEBUI_URL:-}" ] && [ -z "${CORS_ALLOW_ORIGIN:-}" ]; then
    export CORS_ALLOW_ORIGIN="${WEBUI_URL}"
  fi

  if is_true "${START_SEARXNG:-True}" || [ -n "${SEARXNG_QUERY_URL:-}" ]; then
    export ENABLE_WEB_SEARCH="${ENABLE_WEB_SEARCH:-True}"
    export WEB_SEARCH_ENGINE="${WEB_SEARCH_ENGINE:-searxng}"
    export WEB_SEARCH_RESULT_COUNT="${WEB_SEARCH_RESULT_COUNT:-3}"
    export WEB_SEARCH_CONCURRENT_REQUESTS="${WEB_SEARCH_CONCURRENT_REQUESTS:-10}"

    if [ "${WEB_SEARCH_ENGINE}" = "searxng" ]; then
      export SEARXNG_QUERY_URL="${SEARXNG_QUERY_URL:-http://127.0.0.1:${SEARXNG_PORT:-18080}/search?q=<query>}"
      export SEARXNG_LANGUAGE="${SEARXNG_LANGUAGE:-all}"
    fi
  fi

  configure_openwebui_rag_env
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

validate_extra_args() {
  case " ${LLAMA_SERVER_EXTRA_ARGS:-} " in
    *" --host "*|*" --port "*|*" -m "*|*" --model "*|*" --alias "*|*" --mmproj "*)
      log "LLAMA_SERVER_EXTRA_ARGS cannot override --host, --port, --model, --alias, or --mmproj. Use LLAMA_MODEL, LLAMA_ALIAS, and LLAMA_MMPROJ instead."
      return 1
      ;;
    *)
      return 0
      ;;
  esac
}

detect_gpu_info() {
  local output=""

  if ! command -v nvidia-smi >/dev/null 2>&1; then
    log "nvidia-smi is not available. This image expects a CUDA-capable RunPod GPU."
    return 1
  fi

  output="$(nvidia-smi --query-gpu=name,compute_cap --format=csv,noheader 2>/dev/null | head -n 1 || true)"
  if [ -z "${output}" ]; then
    log "Unable to determine GPU name and compute capability from nvidia-smi."
    return 1
  fi

  GPU_NAME="$(trim "${output%%,*}")"
  GPU_COMPUTE_CAPABILITY="$(trim "${output#*,}")"

  if [ -z "${GPU_NAME}" ] || [ -z "${GPU_COMPUTE_CAPABILITY}" ]; then
    log "Incomplete GPU details from nvidia-smi: ${output}"
    return 1
  fi

  return 0
}

cuda_runtime_family() {
  local cuda_tag="${CUDA_VERSION:-}"

  cuda_tag="${cuda_tag,,}"
  cuda_tag="${cuda_tag//./}"
  cuda_tag="${cuda_tag//-/}"

  case "${cuda_tag}" in
    cu12*)
      printf 'cu12\n'
      ;;
    cu13*)
      printf 'cu13\n'
      ;;
    "")
      printf 'unknown\n'
      ;;
    *)
      printf 'unknown\n'
      ;;
  esac
}

validate_gpu_compatibility() {
  local runtime_family=""

  if ! detect_gpu_info; then
    return 1
  fi

  log "Detected GPU ${GPU_NAME} with compute capability ${GPU_COMPUTE_CAPABILITY}."

  if is_true "${LLAMA_ALLOW_UNSUPPORTED_GPU:-}"; then
    log "LLAMA_ALLOW_UNSUPPORTED_GPU is enabled. Skipping incompatible GPU block."
    return 0
  fi

  if [[ "${GPU_COMPUTE_CAPABILITY}" == "7.0" ]] || [[ "${GPU_NAME,,}" == *"v100"* ]]; then
    runtime_family="$(cuda_runtime_family)"

    case "${runtime_family}" in
      cu12)
        log "Volta/V100 GPU detected on CUDA 12.x (${CUDA_VERSION:-unset}). Allowing startup. If warmup is unstable, set LLAMA_SERVER_EXTRA_ARGS=--no-warmup."
        return 0
        ;;
      cu13)
        log "V100 / compute capability 7.0 is blocked on CUDA 13.x images (${CUDA_VERSION:-unset}) because CUDA 13 drops Volta-targeted offline compilation and library support. Use a cu12x image tag, or set LLAMA_ALLOW_UNSUPPORTED_GPU=True to override."
        return 1
        ;;
      *)
        log "V100 / compute capability 7.0 detected, but CUDA_VERSION is unknown. Refusing startup by default. Use a cu12x image tag, or set LLAMA_ALLOW_UNSUPPORTED_GPU=True to override."
        return 1
        ;;
    esac
  fi

  return 0
}

resolve_model_path() {
  local model_path="${LLAMA_MODEL:-${DOWNLOADED_MODEL_PATH:-}}"

  if [ -z "${model_path}" ]; then
    model_path="$(auto_detect_llama_model || true)"
  fi

  if [ -z "${model_path}" ]; then
    log "No GGUF model configured. Set LLAMA_MODEL to an exact file path or provide exactly one model under /workspace/models."
    return 1
  fi

  if [ ! -f "${model_path}" ]; then
    log "LLAMA_MODEL points to a missing file: ${model_path}"
    return 1
  fi

  RESOLVED_MODEL_PATH="${model_path}"
  return 0
}

resolve_model_alias() {
  local model_alias="${LLAMA_ALIAS:-}"

  if [ -z "${model_alias}" ]; then
    model_alias="$(basename "${RESOLVED_MODEL_PATH}")"
    model_alias="${model_alias%.gguf}"
  fi

  if [ -z "${model_alias}" ]; then
    log "Unable to derive a model alias from ${RESOLVED_MODEL_PATH}."
    return 1
  fi

  RESOLVED_MODEL_ALIAS="${model_alias}"
  return 0
}

resolve_mmproj_path() {
  local mmproj_path="${LLAMA_MMPROJ:-${DOWNLOADED_MMPROJ_PATH:-}}"

  if [ -z "${mmproj_path}" ]; then
    mmproj_path="$(auto_detect_mmproj || true)"
  fi

  if [ -n "${mmproj_path}" ] && [ ! -f "${mmproj_path}" ]; then
    log "LLAMA_MMPROJ points to a missing file: ${mmproj_path}"
    return 1
  fi

  if is_true "${LLAMA_MULTIMODAL_REQUIRED:-False}" && [ -z "${mmproj_path}" ]; then
    log "LLAMA_MULTIMODAL_REQUIRED is enabled but no mmproj file was resolved. Set LLAMA_MMPROJ to a valid projector GGUF."
    return 1
  fi

  RESOLVED_MMPROJ_PATH="${mmproj_path}"
  return 0
}

build_llama_command() {
  local -a extra_args=()

  LLAMA_CMD=(
    /llama-server
    --host 127.0.0.1
    --port 11434
    --ctx-size "${LLAMA_CTX_SIZE:-4096}"
    --parallel "${LLAMA_PARALLEL:-1}"
    --model "${RESOLVED_MODEL_PATH}"
    --alias "${RESOLVED_MODEL_ALIAS}"
  )

  if [ -n "${RESOLVED_MMPROJ_PATH}" ]; then
    LLAMA_CMD+=(--mmproj "${RESOLVED_MMPROJ_PATH}")
  fi

  if [ -n "${LLAMA_GPU_LAYERS:-}" ]; then
    LLAMA_CMD+=(--n-gpu-layers "${LLAMA_GPU_LAYERS}")
  fi

  if [ -n "${LLAMA_SERVER_API_KEY:-}" ]; then
    LLAMA_CMD+=(--api-key "${LLAMA_SERVER_API_KEY}")
  fi

  if [ -n "${LLAMA_SERVER_EXTRA_ARGS:-}" ]; then
    read -r -a extra_args <<< "${LLAMA_SERVER_EXTRA_ARGS}"
    LLAMA_CMD+=("${extra_args[@]}")
  fi

  return 0
}

resolve_llama_configuration() {
  reset_launcher_state

  if ! download_requested_assets; then
    log "Model download step failed."
    return 1
  fi

  if ! validate_extra_args; then
    return 1
  fi

  if ! validate_gpu_compatibility; then
    return 1
  fi

  if ! resolve_model_path; then
    return 1
  fi

  if ! resolve_model_alias; then
    return 1
  fi

  if ! resolve_mmproj_path; then
    return 1
  fi

  if ! build_llama_command; then
    return 1
  fi

  log "Resolved llama.cpp launch tuple: model=${RESOLVED_MODEL_PATH}, alias=${RESOLVED_MODEL_ALIAS}, mmproj=${RESOLVED_MMPROJ_PATH:-disabled}"
  return 0
}

query_llama_models_endpoint() {
  local response_file=""
  local curl_status=0

  response_file="$(mktemp)"
  READY_BODY=""
  READY_HTTP_CODE="000"

  if READY_HTTP_CODE="$(curl -sS --max-time "${LLAMA_READY_CURL_TIMEOUT:-5}" -o "${response_file}" -w '%{http_code}' "${LLAMA_READY_URL:-http://127.0.0.1:11434/v1/models}" 2>>"${LLAMA_LOG_PATH}")"; then
    READY_BODY="$(cat "${response_file}")"
    rm -f "${response_file}"
    return 0
  fi

  curl_status=$?
  READY_BODY="$(cat "${response_file}" 2>/dev/null || true)"
  rm -f "${response_file}"
  READY_HTTP_CODE="000"
  return "${curl_status}"
}

tail_recent_llama_log() {
  if [ -f "${LLAMA_LOG_PATH}" ]; then
    log "Recent llama.cpp log lines:"
    tail -n "${LLAMA_FAILURE_TAIL_LINES:-40}" "${LLAMA_LOG_PATH}" || true
  fi
}

stop_llama_server_process() {
  local server_pid="$1"
  local grace_period="${LLAMA_STOP_GRACE_PERIOD:-5}"

  if ! kill -0 "${server_pid}" 2>/dev/null; then
    return 0
  fi

  kill "${server_pid}" 2>/dev/null || true
  sleep "${grace_period}"

  if kill -0 "${server_pid}" 2>/dev/null; then
    kill -9 "${server_pid}" 2>/dev/null || true
  fi
}

wait_for_llama_ready() {
  local server_pid="$1"
  local timeout="${LLAMA_READY_TIMEOUT:-600}"
  local interval="${LLAMA_READY_POLL_INTERVAL:-2}"
  local elapsed=0
  local loading_logged=0
  local waiting_logged=0

  while [ "${elapsed}" -lt "${timeout}" ]; do
    if ! kill -0 "${server_pid}" 2>/dev/null; then
      log "llama-server exited before becoming ready."
      return 1
    fi

    if query_llama_models_endpoint; then
      case "${READY_HTTP_CODE}" in
        200)
          log "llama-server is ready at ${LLAMA_READY_URL:-http://127.0.0.1:11434/v1/models}."
          return 0
          ;;
        503)
          if [[ "${READY_BODY}" == *"Loading model"* ]]; then
            if [ "${loading_logged}" -eq 0 ]; then
              log "llama-server is still loading the model."
              loading_logged=1
            fi
          else
            log "llama-server returned HTTP 503 before readiness: ${READY_BODY}"
          fi
          ;;
        *)
          log "Waiting for llama-server readiness. Received HTTP ${READY_HTTP_CODE}: ${READY_BODY}"
          ;;
      esac
    else
      if [ "${waiting_logged}" -eq 0 ]; then
        log "Waiting for llama-server to bind to 127.0.0.1:11434."
        waiting_logged=1
      fi
    fi

    sleep "${interval}"
    elapsed=$((elapsed + interval))
  done

  log "Timed out after ${timeout}s waiting for llama-server readiness."
  return 1
}

start_llama_server_once() {
  local attempt="$1"

  log_llama "Starting llama.cpp server attempt ${attempt} on 127.0.0.1:11434."
  (
    cd / || exit 1
    "${LLAMA_CMD[@]}"
  ) >> "${LLAMA_LOG_PATH}" 2>&1 &

  LLAMA_SERVER_PID="$!"
}

write_llama_failure_marker() {
  printf '%s\n' "$1" > "${LLAMA_FAILED_MARKER}"
}

run_llama_supervisor() {
  local max_restarts="${LLAMA_MAX_RESTARTS:-3}"
  local restart_delay="${LLAMA_RESTART_DELAY:-5}"
  local max_attempts=$((max_restarts + 1))
  local attempt=1
  local server_pid=""
  local wait_status=0

  rm -f "${LLAMA_READY_MARKER}" "${LLAMA_FAILED_MARKER}"

  while [ "${attempt}" -le "${max_attempts}" ]; do
    start_llama_server_once "${attempt}"
    server_pid="${LLAMA_SERVER_PID}"
    log_llama "llama-server pid=${server_pid}"

    if wait_for_llama_ready "${server_pid}"; then
      if [ ! -f "${LLAMA_READY_MARKER}" ]; then
        printf 'ready\n' > "${LLAMA_READY_MARKER}"
      fi

      wait "${server_pid}"
      wait_status=$?
      log_llama "llama-server exited with status ${wait_status} after readiness."
    else
      stop_llama_server_process "${server_pid}"
      wait "${server_pid}" 2>/dev/null
      wait_status=$?
      log_llama "llama-server failed during startup with status ${wait_status}."
    fi

    tail_recent_llama_log

    if [ "${attempt}" -ge "${max_attempts}" ]; then
      write_llama_failure_marker "llama-server exited ${attempt} time(s). See ${LLAMA_LOG_PATH} for details."
      log_llama "Reached the restart limit (${max_restarts})."
      return 1
    fi

    log_llama "Restarting llama-server in ${restart_delay}s."
    attempt=$((attempt + 1))
    sleep "${restart_delay}"
  done

  write_llama_failure_marker "llama-server supervisor terminated unexpectedly."
  return 1
}

start_llama_supervisor() {
  rm -f "${LLAMA_READY_MARKER}" "${LLAMA_FAILED_MARKER}"
  run_llama_supervisor &
  LLAMA_SUPERVISOR_PID="$!"
  printf '%s\n' "${LLAMA_SUPERVISOR_PID}" > "${LLAMA_SUPERVISOR_PID_FILE}"
  log "llama.cpp supervisor started with pid ${LLAMA_SUPERVISOR_PID}."
}

wait_for_initial_llama_readiness() {
  local ready_timeout="${LLAMA_BOOTSTRAP_TIMEOUT:-$(( (${LLAMA_READY_TIMEOUT:-600}) * (${LLAMA_MAX_RESTARTS:-3} + 1) ))}"
  local elapsed=0

  while [ "${elapsed}" -lt "${ready_timeout}" ]; do
    if [ -f "${LLAMA_READY_MARKER}" ]; then
      log "Initial llama.cpp readiness confirmed."
      return 0
    fi

    if [ -f "${LLAMA_FAILED_MARKER}" ]; then
      log "llama.cpp bootstrap failed: $(cat "${LLAMA_FAILED_MARKER}")"
      return 1
    fi

    if ! kill -0 "${LLAMA_SUPERVISOR_PID}" 2>/dev/null; then
      log "llama.cpp supervisor exited before readiness."
      return 1
    fi

    sleep 1
    elapsed=$((elapsed + 1))
  done

  log "Timed out after ${ready_timeout}s waiting for the llama.cpp supervisor to report readiness."
  return 1
}

query_searxng_endpoint() {
  local response_file=""
  local curl_status=0

  response_file="$(mktemp)"
  SEARXNG_READY_BODY=""
  SEARXNG_READY_HTTP_CODE="000"

  if SEARXNG_READY_HTTP_CODE="$(curl -sS --max-time "${SEARXNG_READY_CURL_TIMEOUT:-5}" -o "${response_file}" -w '%{http_code}' "${SEARXNG_READY_URL:-http://127.0.0.1:${SEARXNG_PORT:-18080}/}" 2>>"${SEARXNG_LOG_PATH}")"; then
    SEARXNG_READY_BODY="$(cat "${response_file}")"
    rm -f "${response_file}"
    return 0
  fi

  curl_status=$?
  SEARXNG_READY_BODY="$(cat "${response_file}" 2>/dev/null || true)"
  rm -f "${response_file}"
  SEARXNG_READY_HTTP_CODE="000"
  return "${curl_status}"
}

wait_for_searxng_ready() {
  local server_pid="$1"
  local timeout="${SEARXNG_READY_TIMEOUT:-60}"
  local interval="${SEARXNG_READY_POLL_INTERVAL:-2}"
  local elapsed=0
  local waiting_logged=0

  while [ "${elapsed}" -lt "${timeout}" ]; do
    if ! kill -0 "${server_pid}" 2>/dev/null; then
      log "SearXNG exited before becoming ready."
      return 1
    fi

    if query_searxng_endpoint; then
      case "${SEARXNG_READY_HTTP_CODE}" in
        200)
          log "SearXNG is ready at ${SEARXNG_READY_URL:-http://127.0.0.1:${SEARXNG_PORT:-18080}/}."
          return 0
          ;;
        *)
          log "Waiting for SearXNG readiness. Received HTTP ${SEARXNG_READY_HTTP_CODE}."
          ;;
      esac
    else
      if [ "${waiting_logged}" -eq 0 ]; then
        log "Waiting for SearXNG to bind to 127.0.0.1:${SEARXNG_PORT:-18080}."
        waiting_logged=1
      fi
    fi

    sleep "${interval}"
    elapsed=$((elapsed + interval))
  done

  log "Timed out after ${timeout}s waiting for SearXNG readiness."
  return 1
}

start_qdrant() {
  local host="${QDRANT_HOST:-127.0.0.1}"
  local port="${QDRANT_PORT:-6333}"
  local grpc_port="${QDRANT_GRPC_PORT:-6334}"
  local storage_path="${QDRANT_STORAGE_PATH:-/workspace/qdrant/storage}"

  if ! rag_stack_enabled || ! is_true "${ENABLE_QDRANT:-True}"; then
    log "Qdrant startup skipped."
    return 0
  fi

  if ! command -v qdrant >/dev/null 2>&1; then
    log "Qdrant binary is missing. Disable the RAG stack with DISABLE_RAG_STACK=True or rebuild the image with Qdrant installed."
    return 1
  fi

  mkdir -p "${storage_path}"
  export QDRANT__SERVICE__HOST="${host}"
  export QDRANT__SERVICE__HTTP_PORT="${port}"
  export QDRANT__SERVICE__GRPC_PORT="${grpc_port}"
  export QDRANT__STORAGE__STORAGE_PATH="${storage_path}"
  export QDRANT__STORAGE__ON_DISK_PAYLOAD="${QDRANT_ON_DISK:-True}"

  if [ -n "${QDRANT_API_KEY:-}" ]; then
    export QDRANT__SERVICE__API_KEY="${QDRANT_API_KEY}"
    log "Starting Qdrant on ${host}:${port} with API key $(redact_secret "${QDRANT_API_KEY}")."
  else
    unset QDRANT__SERVICE__API_KEY
    log "Starting local Qdrant on ${host}:${port} without an API key. It is bound to localhost only."
  fi

  (
    cd / || exit 1
    qdrant
  ) >> "${QDRANT_LOG_PATH}" 2>&1 &

  QDRANT_PID="$!"
  log "Qdrant pid=${QDRANT_PID}; logging to ${QDRANT_LOG_PATH}"

  if wait_for_http "Qdrant" "http://${host}:${port}/readyz" "${QDRANT_READY_TIMEOUT:-60}" "${QDRANT_READY_POLL_INTERVAL:-2}" "${QDRANT_LOG_PATH}"; then
    return 0
  fi

  if is_true "${REQUIRE_RAG_SERVICES:-False}"; then
    return 1
  fi

  log "Qdrant did not pass readiness before timeout; continuing because REQUIRE_RAG_SERVICES is not enabled."
  return 0
}

start_docling() {
  local host="${DOCLING_SERVE_HOST:-127.0.0.1}"
  local port="${DOCLING_SERVE_PORT:-5001}"
  local artifacts_path="${DOCLING_SERVE_ARTIFACTS_PATH:-/workspace/docling/artifacts}"
  local docling_bin="${DOCLING_SERVE_BIN:-}"

  if ! rag_stack_enabled || ! is_true "${ENABLE_DOCLING:-True}"; then
    log "Docling startup skipped."
    return 0
  fi

  if [ -z "${docling_bin}" ]; then
    docling_bin="$(command -v docling-serve || true)"
  fi

  if [ -z "${docling_bin}" ] && [ -x /opt/docling-serve-venv/bin/docling-serve ]; then
    docling_bin="/opt/docling-serve-venv/bin/docling-serve"
  fi

  if [ -z "${docling_bin}" ] || [ ! -x "${docling_bin}" ]; then
    log "docling-serve is missing. Disable Docling with ENABLE_DOCLING=False or rebuild the image with Docling installed."
    return 1
  fi

  mkdir -p "${artifacts_path}"
  export DOCLING_SERVE_ARTIFACTS_PATH="${artifacts_path}"
  export DOCLING_SERVE_MAX_SYNC_WAIT="${DOCLING_SERVE_MAX_SYNC_WAIT:-600}"
  export UVICORN_WORKERS=1
  export OMP_NUM_THREADS="${DOCLING_OMP_NUM_THREADS:-4}"
  export MKL_NUM_THREADS="${DOCLING_MKL_NUM_THREADS:-4}"

  log "Starting Docling Serve on ${host}:${port} with UVICORN_WORKERS=1."
  (
    cd / || exit 1
    "${docling_bin}" run --host "${host}" --port "${port}"
  ) >> "${DOCLING_LOG_PATH}" 2>&1 &

  DOCLING_PID="$!"
  log "Docling Serve pid=${DOCLING_PID}; logging to ${DOCLING_LOG_PATH}"

  if wait_for_http "Docling Serve" "http://${host}:${port}/health" "${DOCLING_READY_TIMEOUT:-600}" "${DOCLING_READY_POLL_INTERVAL:-3}" "${DOCLING_LOG_PATH}"; then
    return 0
  fi

  if is_true "${REQUIRE_RAG_SERVICES:-False}"; then
    return 1
  fi

  log "Docling Serve did not pass readiness before timeout; continuing because REQUIRE_RAG_SERVICES is not enabled."
  return 0
}

start_searxng() {
  local port="${SEARXNG_PORT:-18080}"
  local workers="${SEARXNG_WORKERS:-1}"
  local settings_path="${SEARXNG_SETTINGS_PATH:-/etc/searxng/settings.yml}"

  if ! is_true "${START_SEARXNG:-True}"; then
    log "START_SEARXNG is not set to TRUE. Skipping local SearXNG startup."
    return 0
  fi

  if [ ! -x /opt/searxng-venv/bin/granian ]; then
    log "SearXNG runtime is missing: /opt/searxng-venv/bin/granian"
    return 1
  fi

  if [ ! -f "${settings_path}" ]; then
    log "SearXNG settings file is missing: ${settings_path}"
    return 1
  fi

  mkdir -p /workspace/searxng-cache
  export SEARXNG_SETTINGS_PATH="${settings_path}"
  export __SEARXNG_SETTINGS_PATH="${settings_path}"
  export SEARXNG_SECRET="${SEARXNG_SECRET:-$(head -c 24 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 32)}"
  export SEARXNG_PORT="${port}"
  export SEARXNG_BASE_URL="${SEARXNG_BASE_URL:-http://127.0.0.1:${port}/}"

  log "Starting SearXNG on 127.0.0.1:${port}."
  (
    cd / || exit 1
    /opt/searxng-venv/bin/granian \
      --interface wsgi \
      --host 127.0.0.1 \
      --port "${port}" \
      --workers "${workers}" \
      searx.webapp:app
  ) >> "${SEARXNG_LOG_PATH}" 2>&1 &

  SEARXNG_PID="$!"
  log "SearXNG pid=${SEARXNG_PID}; logging to ${SEARXNG_LOG_PATH}"

  wait_for_searxng_ready "${SEARXNG_PID}"
}

check_openwebui_socketio_failures() {
  local excerpt_file="$1"
  local threshold="${OPENWEBUI_WS_400_THRESHOLD:-3}"
  local matches=0

  if [ ! -f "${excerpt_file}" ]; then
    return 1
  fi

  matches="$(grep -cE '/ws/socket\.io/.* (400|403)|socket\.io.* (400|403)|not an accepted origin' "${excerpt_file}" || true)"
  if [ "${matches}" -ge "${threshold}" ]; then
    log "Detected repeated Open WebUI socket failures. Check WEBUI_URL, CORS_ALLOW_ORIGIN, and the bundled proxy Host/X-Forwarded-* WebSocket headers."
    return 0
  fi

  return 1
}

start_openwebui_socketio_monitor() {
  (
    local last_line=0
    local total_lines=0
    local interval="${OPENWEBUI_WS_DIAG_INTERVAL:-60}"
    local excerpt_file=""

    while sleep "${interval}"; do
      if [ ! -f "${OPENWEBUI_LOG_PATH}" ]; then
        continue
      fi

      total_lines="$(wc -l < "${OPENWEBUI_LOG_PATH}")"
      if [ "${total_lines}" -le "${last_line}" ]; then
        continue
      fi

      excerpt_file="$(mktemp)"
      sed -n "$((last_line + 1)),${total_lines}p" "${OPENWEBUI_LOG_PATH}" > "${excerpt_file}"
      last_line="${total_lines}"
      check_openwebui_socketio_failures "${excerpt_file}" || true
      rm -f "${excerpt_file}"
    done
  ) &
}

start_openwebui() {
  log "Starting Open WebUI server..."
  open-webui serve > "${OPENWEBUI_LOG_PATH}" 2>&1 &
  log "Open WebUI server started and logging to ${OPENWEBUI_LOG_PATH}"
  start_openwebui_socketio_monitor
}

main() {
  ensure_runtime_paths
  if ! configure_openwebui_runtime_env; then
    return 1
  fi

  if [ "${START_LLAMA_SERVER,,}" = "true" ]; then
    if ! resolve_llama_configuration; then
      return 1
    fi

    start_llama_supervisor
    if ! wait_for_initial_llama_readiness; then
      return 1
    fi
  else
    log "START_LLAMA_SERVER is not set to TRUE. Skipping llama.cpp server start."
  fi

  if ! start_searxng; then
    return 1
  fi

  if ! start_qdrant; then
    return 1
  fi

  if ! start_docling; then
    return 1
  fi

  start_openwebui
  return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
