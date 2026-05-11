#!/bin/bash
set -euo pipefail

fail() {
  echo "RAG CHECK FAILED: $*" >&2
  exit 1
}

check_http() {
  local name="$1"
  local url="$2"
  local expected="${3:-200}"
  local status=""

  status="$(curl -sS --max-time "${RAG_CHECK_TIMEOUT:-10}" -o /dev/null -w '%{http_code}' "${url}" || true)"
  if [ "${status}" != "${expected}" ]; then
    fail "${name} at ${url} returned HTTP ${status}, expected ${expected}"
  fi

  echo "${name}: ok (${url})"
}

check_env_for_pid() {
  local pid="$1"
  local name="$2"
  local expected="$3"
  local value=""

  value="$(tr '\0' '\n' < "/proc/${pid}/environ" | awk -F= -v key="${name}" '$1 == key {print substr($0, length(key) + 2); exit}')"
  if [ "${value}" != "${expected}" ]; then
    fail "Open WebUI env ${name} expected '${expected}', got '${value}'"
  fi

  echo "Open WebUI env ${name}: ok"
}

check_absent_public_route() {
  local port="$1"
  local label="$2"

  if nginx -T 2>/dev/null | grep -Eq "listen[[:space:]]+${port}([[:space:];]|$)"; then
    fail "${label} must not be exposed by nginx on port ${port}"
  fi

  echo "${label}: not exposed by nginx"
}

check_http "llama.cpp" "${LLAMA_READY_URL:-http://127.0.0.1:11434/v1/models}"
check_http "Open WebUI" "${OPENWEBUI_HEALTH_URL:-http://127.0.0.1:8080/health}"
check_http "SearXNG" "${SEARXNG_CHECK_URL:-http://127.0.0.1:${SEARXNG_PORT:-18080}/search?q=health&format=json}"

if [ "${DISABLE_RAG_STACK:-False}" = "True" ] || [ "${DISABLE_RAG_STACK:-False}" = "true" ]; then
  echo "RAG stack disabled; skipping Qdrant and Docling checks."
else
  if [ "${ENABLE_QDRANT:-True}" = "True" ] || [ "${ENABLE_QDRANT:-True}" = "true" ]; then
    check_http "Qdrant" "${QDRANT_HEALTH_URL:-http://127.0.0.1:6333/readyz}"
  fi

  if [ "${ENABLE_DOCLING:-True}" = "True" ] || [ "${ENABLE_DOCLING:-True}" = "true" ]; then
    check_http "Docling" "${DOCLING_HEALTH_URL:-http://127.0.0.1:5001/health}"
  fi

  openwebui_pid="$(pgrep -f 'open-webui serve' | head -n 1 || true)"
  if [ -n "${openwebui_pid}" ]; then
    check_env_for_pid "${openwebui_pid}" VECTOR_DB qdrant
    check_env_for_pid "${openwebui_pid}" CONTENT_EXTRACTION_ENGINE docling
    check_env_for_pid "${openwebui_pid}" ENABLE_RAG_HYBRID_SEARCH True
    check_env_for_pid "${openwebui_pid}" RAG_RERANKING_MODEL BAAI/bge-reranker-v2-m3
  else
    echo "Open WebUI process not found; skipped process env checks."
  fi
fi

check_absent_public_route 6333 "Qdrant"
check_absent_public_route 5001 "Docling"

echo "RAG stack checks passed."
