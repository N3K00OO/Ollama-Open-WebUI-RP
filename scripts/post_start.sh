#!/bin/bash

set -uo pipefail

LLAMA_LOG_PATH="/workspace/logs/llama-server.log"
OPENWEBUI_LOG_PATH="/workspace/logs/open-webui.log"
LLAMA_READY_MARKER="/workspace/logs/llama-server.ready"
LLAMA_FAILED_MARKER="/workspace/logs/llama-server.failed"
LLAMA_SUPERVISOR_PID_FILE="/workspace/logs/llama-supervisor.pid"
DOWNLOADED_MODEL_PATH=""
DOWNLOADED_MMPROJ_PATH=""
RESOLVED_MODEL_PATH=""
RESOLVED_MODEL_ALIAS=""
RESOLVED_MMPROJ_PATH=""
LLAMA_SUPERVISOR_PID=""
READY_HTTP_CODE=""
READY_BODY=""
GPU_NAME=""
GPU_COMPUTE_CAPABILITY=""
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
  mkdir -p /workspace/logs /workspace/models /workspace/data
  : > "${LLAMA_LOG_PATH}"
  rm -f "${LLAMA_READY_MARKER}" "${LLAMA_FAILED_MARKER}" "${LLAMA_SUPERVISOR_PID_FILE}"
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

  printf '%s' "$!"
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
    server_pid="$(start_llama_server_once "${attempt}")"
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

check_openwebui_socketio_failures() {
  local excerpt_file="$1"
  local threshold="${OPENWEBUI_WS_400_THRESHOLD:-3}"
  local matches=0

  if [ ! -f "${excerpt_file}" ]; then
    return 1
  fi

  matches="$(grep -cE '/ws/socket\.io/.* 400|socket\.io.* 400' "${excerpt_file}" || true)"
  if [ "${matches}" -ge "${threshold}" ]; then
    log "Detected repeated /ws/socket.io 400 failures. Check WEBUI_URL, CORS_ALLOW_ORIGIN, and the bundled proxy WebSocket headers."
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
  configure_openwebui_runtime_env

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

  start_openwebui
  return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
