#!/bin/bash

set -euo pipefail

fail() {
  echo "SMOKE FAILED: $*" >&2
  exit 1
}

assert_eq() {
  local expected="$1"
  local actual="$2"
  local message="$3"

  if [ "${expected}" != "${actual}" ]; then
    fail "${message}: expected '${expected}', got '${actual}'"
  fi
}

assert_text_contains() {
  local haystack="$1"
  local needle="$2"
  local message="$3"

  if [[ "${haystack}" != *"${needle}"* ]]; then
    fail "${message}: missing '${needle}'"
  fi
}

assert_file_not_contains() {
  local file_path="$1"
  local needle="$2"
  local message="$3"

  if grep -qF "${needle}" "${file_path}"; then
    fail "${message}: found unexpected '${needle}' in ${file_path}"
  fi
}

TEST_TMP="$(mktemp -d)"
FAKE_SERVER_PID=""
HEADER_ECHO_PID=""
ORIGINAL_PATH="${PATH}"

cleanup() {
  if [ -n "${FAKE_SERVER_PID}" ] && kill -0 "${FAKE_SERVER_PID}" 2>/dev/null; then
    kill "${FAKE_SERVER_PID}" 2>/dev/null || true
    wait "${FAKE_SERVER_PID}" 2>/dev/null || true
  fi

  if [ -n "${HEADER_ECHO_PID}" ] && kill -0 "${HEADER_ECHO_PID}" 2>/dev/null; then
    kill "${HEADER_ECHO_PID}" 2>/dev/null || true
    wait "${HEADER_ECHO_PID}" 2>/dev/null || true
  fi

  nginx -s stop >/dev/null 2>&1 || true
  rm -rf "${TEST_TMP}"
}

trap cleanup EXIT

make_stub_nvidia() {
  local gpu_name="$1"
  local compute_capability="$2"

  mkdir -p "${TEST_TMP}/bin"
  cat > "${TEST_TMP}/bin/nvidia-smi" <<EOF
#!/bin/bash
if [[ "\$*" == *"--query-gpu=name,compute_cap"* ]]; then
  echo "${gpu_name}, ${compute_capability}"
  exit 0
fi
echo "unsupported stub invocation: \$*" >&2
exit 1
EOF
  chmod +x "${TEST_TMP}/bin/nvidia-smi"
  export PATH="${TEST_TMP}/bin:${ORIGINAL_PATH}"
}

start_fake_models_server() {
  local port="$1"

  cat > "${TEST_TMP}/fake_models_server.py" <<'PY'
import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

counter = {"count": 0}


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        counter["count"] += 1
        if self.path != "/v1/models":
            self.send_response(404)
            self.end_headers()
            return
        if counter["count"] < 3:
            self.send_response(503)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps({"error": {"message": "Loading model"}}).encode("utf-8"))
            return
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps({"data": [{"id": "smoke-model"}]}).encode("utf-8"))

    def log_message(self, format, *args):
        return


HTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
PY

  python "${TEST_TMP}/fake_models_server.py" "${port}" &
  FAKE_SERVER_PID="$!"
}

start_header_echo_server() {
  local port="$1"

  cat > "${TEST_TMP}/header_echo_server.py" <<'PY'
import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        body = json.dumps(
            {
                "path": self.path,
                "headers": {k.lower(): v for k, v in self.headers.items()},
            }
        ).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format, *args):
        return


HTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
PY

  python "${TEST_TMP}/header_echo_server.py" "${port}" &
  HEADER_ECHO_PID="$!"
}

json_header_value() {
  local json_file="$1"
  local header_name="$2"

  python - "${json_file}" "${header_name}" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    payload = json.load(handle)

print(payload["headers"].get(sys.argv[2].lower(), ""))
PY
}

check_proxy_status() {
  local url="$1"
  local expected_status="$2"
  local headers_file=""
  local body_file=""
  local status_code=""

  headers_file="$(mktemp)"
  body_file="$(mktemp)"
  status_code="$(curl -sS -D "${headers_file}" -o "${body_file}" -w '%{http_code}' "${url}")"

  assert_eq "${expected_status}" "${status_code}" "Unexpected status for ${url}"
  grep -qi '^Content-Type: application/json' "${headers_file}" || fail "Proxy error response for ${url} should stay JSON"
  assert_text_contains "$(cat "${body_file}")" '"type":"upstream_error"' "Proxy error body should expose an upstream_error payload for ${url}"
  assert_file_not_contains "${body_file}" "<!DOCTYPE" "Proxy path should preserve upstream API semantics for ${url}"

  rm -f "${headers_file}" "${body_file}"
}

assert_proxy_header_forwarding() {
  local url="$1"
  local expected_host="$2"
  local expected_proto="$3"
  local response_file=""
  local status_code=""

  response_file="$(mktemp)"
  status_code="$(
    curl -sS \
      -o "${response_file}" \
      -w '%{http_code}' \
      -H 'Host: 100.65.23.73:60311' \
      -H "Origin: ${expected_proto}://${expected_host}" \
      -H 'Connection: Upgrade' \
      -H 'Upgrade: websocket' \
      "${url}"
  )"

  assert_eq "200" "${status_code}" "Expected proxy header echo to succeed for ${url}"
  assert_eq "${expected_host}" "$(json_header_value "${response_file}" host)" "Proxy should preserve the public host for ${url}"
  assert_eq "${expected_host}" "$(json_header_value "${response_file}" x-forwarded-host)" "Proxy should set X-Forwarded-Host for ${url}"
  assert_eq "${expected_proto}" "$(json_header_value "${response_file}" x-forwarded-proto)" "Proxy should set X-Forwarded-Proto for ${url}"

  rm -f "${response_file}"
}

mkdir -p /workspace/logs /workspace/models /workspace/data
source /post_start.sh

make_stub_nvidia "Tesla V100-SXM2-32GB" "7.0"
CUDA_VERSION="cu130"
unset LLAMA_ALLOW_UNSUPPORTED_GPU
if validate_gpu_compatibility; then
  fail "V100 guard should block CUDA 13.x images by default"
fi

CUDA_VERSION="cu126"
validate_gpu_compatibility

CUDA_VERSION="cu130"
LLAMA_ALLOW_UNSUPPORTED_GPU=True
validate_gpu_compatibility
unset LLAMA_ALLOW_UNSUPPORTED_GPU

make_stub_nvidia "NVIDIA RTX A6000" "8.6"
validate_gpu_compatibility

make_stub_nvidia "NVIDIA A10" "8.6"
MODEL_PATH="${TEST_TMP}/model.gguf"
: > "${MODEL_PATH}"

LLAMA_SERVER_EXTRA_ARGS="--port 8080"
if validate_extra_args; then
  fail "Launcher should reject port overrides in LLAMA_SERVER_EXTRA_ARGS"
fi
unset LLAMA_SERVER_EXTRA_ARGS

LLAMA_MODEL="${MODEL_PATH}"
LLAMA_ALIAS="qwen3vl-heretic"
LLAMA_MULTIMODAL_REQUIRED=True
unset LLAMA_MMPROJ
if resolve_llama_configuration; then
  fail "Multimodal mode should fail when mmproj is missing"
fi
unset LLAMA_MULTIMODAL_REQUIRED

LLAMA_SERVER_EXTRA_ARGS="--threads 2"
resolve_llama_configuration
COMMAND_TEXT="$(printf '%s ' "${LLAMA_CMD[@]}")"
assert_text_contains "${COMMAND_TEXT}" "--host 127.0.0.1 --port 11434" "Launcher must pin llama-server to 127.0.0.1:11434"
assert_text_contains "${COMMAND_TEXT}" "--model ${MODEL_PATH} --alias qwen3vl-heretic" "Launcher must pass explicit model and alias"
unset LLAMA_MODEL LLAMA_ALIAS LLAMA_SERVER_EXTRA_ARGS

unset CORS_ALLOW_ORIGIN
WEBUI_URL="https://example.runpod.dev"
configure_openwebui_runtime_env
assert_eq "${WEBUI_URL}" "${CORS_ALLOW_ORIGIN}" "WEBUI_URL should seed CORS_ALLOW_ORIGIN when unset"
unset WEBUI_URL CORS_ALLOW_ORIGIN

cat > "${TEST_TMP}/openwebui.log" <<'EOF'
GET /ws/socket.io/?EIO=4&transport=websocket 400
GET /ws/socket.io/?EIO=4&transport=websocket 400
GET /ws/socket.io/?EIO=4&transport=websocket 400
EOF
check_openwebui_socketio_failures "${TEST_TMP}/openwebui.log"

LLAMA_READY_URL="http://127.0.0.1:18080/v1/models"
LLAMA_READY_TIMEOUT=10
LLAMA_READY_POLL_INTERVAL=1
start_fake_models_server 18080
wait_for_llama_ready "${FAKE_SERVER_PID}"
kill "${FAKE_SERVER_PID}" 2>/dev/null || true
wait "${FAKE_SERVER_PID}" 2>/dev/null || true
FAKE_SERVER_PID=""
unset LLAMA_READY_URL LLAMA_READY_TIMEOUT LLAMA_READY_POLL_INTERVAL

nginx -t >/dev/null
nginx -T > "${TEST_TMP}/nginx.txt" 2>&1
grep -q 'proxy_http_version 1.1;' "${TEST_TMP}/nginx.txt" || fail "nginx config should enable HTTP/1.1 proxying"
grep -q 'proxy_set_header Upgrade $http_upgrade;' "${TEST_TMP}/nginx.txt" || fail "nginx config should forward Upgrade headers"
grep -q 'proxy_set_header Host $proxy_host_header;' "${TEST_TMP}/nginx.txt" || fail "nginx config should preserve the public host for upstream services"
grep -q 'proxy_set_header X-Forwarded-Host $proxy_forwarded_host;' "${TEST_TMP}/nginx.txt" || fail "nginx config should forward X-Forwarded-Host"
grep -q 'proxy_set_header X-Forwarded-Proto $proxy_forwarded_proto;' "${TEST_TMP}/nginx.txt" || fail "nginx config should forward the public X-Forwarded-Proto"

nginx
sleep 1
check_proxy_status "http://127.0.0.1:8081/api/models" "502"
check_proxy_status "http://127.0.0.1:11435/v1/models" "502"

start_header_echo_server 8080
sleep 1
assert_proxy_header_forwarding "http://127.0.0.1:8081/ws/socket.io/?EIO=4&transport=websocket" "w5k9x3yhywnmen-8081.proxy.runpod.net" "https"

echo "Smoke checks passed."
