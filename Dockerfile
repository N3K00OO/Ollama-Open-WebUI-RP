# syntax=docker/dockerfile:1
# check=skip=SecretsUsedInArgOrEnv

# WEBUI_AUTH and OPENAI_API_KEY are non-secret runtime defaults required by Open WebUI.
ARG BASE_IMAGE=nvidia/cuda:12.6.3-devel-ubuntu22.04
FROM ${BASE_IMAGE} AS llama-builder

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ARG LLAMA_CPP_VERSION

RUN apt-get update -y && \
    apt-get install -y --no-install-recommends \
        build-essential ca-certificates ccache cmake git libssl-dev ninja-build && \
    apt-get clean && rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*

RUN --mount=type=cache,target=/root/.cache/ccache \
    git clone --branch "${LLAMA_CPP_VERSION}" --depth 1 https://github.com/ggml-org/llama.cpp.git /tmp/llama.cpp && \
    cmake -S /tmp/llama.cpp -B /tmp/llama.cpp/build -G Ninja \
        -DBUILD_SHARED_LIBS=OFF \
        -DGGML_CUDA=ON \
        -DGGML_NATIVE=OFF \
        -DCMAKE_C_COMPILER_LAUNCHER=ccache \
        -DCMAKE_CXX_COMPILER_LAUNCHER=ccache \
        -DLLAMA_BUILD_EXAMPLES=OFF \
        -DLLAMA_BUILD_TESTS=OFF \
        -DCMAKE_BUILD_TYPE=Release && \
    cmake --build /tmp/llama.cpp/build --target llama-server --config Release -j"$(nproc)" && \
    install -Dm755 /tmp/llama.cpp/build/bin/llama-server /artifacts/llama-server

FROM ${BASE_IMAGE}

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ARG PYTHON_VERSION
ARG TORCH_VERSION
ARG CUDA_VERSION
ARG OPEN_WEBUI_VERSION
ARG SEARXNG_VERSION=master
ARG QDRANT_VERSION=1.17.1
ARG DOCLING_SERVE_VERSION=1.18.0

ENV SHELL=/bin/bash \
    PYTHONUNBUFFERED=True \
    DEBIAN_FRONTEND=noninteractive \
    TZ=Etc/UTC \
    CUDA_VERSION=${CUDA_VERSION} \
    DATA_DIR=/workspace/data \
    WEBUI_AUTH=False \
    SYNC_VENV_TO_WORKSPACE=False \
    START_LLAMA_SERVER=True \
    START_SEARXNG=True \
    LLAMA_CTX_SIZE=4096 \
    LLAMA_GPU_LAYERS=999 \
    LLAMA_PARALLEL=1 \
    RESET_CONFIG_ON_START=True \
    ENABLE_OPENAI_API=True \
    OPENAI_API_BASE_URL=http://127.0.0.1:11434/v1 \
    OPENAI_API_KEY=sk-no-key-required \
    SEARXNG_PORT=18080 \
    ENABLE_RAG_STACK=True \
    DISABLE_RAG_STACK=False \
    REQUIRE_RAG_SERVICES=False \
    ENABLE_QDRANT=True \
    VECTOR_DB=qdrant \
    QDRANT_URI=http://127.0.0.1:6333 \
    QDRANT_API_KEY= \
    QDRANT_ON_DISK=True \
    QDRANT_TIMEOUT=10 \
    QDRANT_STORAGE_PATH=/workspace/qdrant/storage \
    ENABLE_DOCLING=True \
    CONTENT_EXTRACTION_ENGINE=docling \
    DOCLING_SERVER_URL=http://127.0.0.1:5001 \
    DOCLING_PARAMS='{"do_ocr":true,"ocr_engine":"tesseract","table_mode":"accurate"}' \
    DOCLING_SERVE_HOST=127.0.0.1 \
    DOCLING_SERVE_PORT=5001 \
    DOCLING_SERVE_MAX_SYNC_WAIT=600 \
    DOCLING_READY_TIMEOUT=600 \
    UVICORN_WORKERS=1 \
    RAG_EMBEDDING_MODEL=intfloat/multilingual-e5-large-instruct \
    RAG_TOP_K=20 \
    ENABLE_RAG_HYBRID_SEARCH=True \
    ENABLE_RERANKER=True \
    RAG_RERANKING_MODEL=BAAI/bge-reranker-v2-m3 \
    RAG_TOP_K_RERANKER=5 \
    RAG_RERANKING_BATCH_SIZE=8 \
    HF_HOME=/runpod-volume/.cache/huggingface/ \
    HF_XET_HIGH_PERFORMANCE=1 \
    PIP_CACHE_DIR=/runpod-volume/.cache/pip/ \
    UV_CACHE_DIR=/runpod-volume/.cache/uv/

WORKDIR /

RUN apt-get update -y && apt-get upgrade -y && \
    apt-get install -y --no-install-recommends \
        git wget curl bash nginx-light rsync sudo binutils ffmpeg lshw nano tzdata file build-essential nvtop \
        tesseract-ocr tesseract-ocr-eng poppler-utils \
        libgl1 libglib2.0-0 libssl3 openssh-server ca-certificates zstd \
        python3-dev libxml2-dev libxslt1-dev zlib1g-dev libffi-dev libssl-dev && \
    apt-get autoremove -y && apt-get clean && rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*

ADD https://astral.sh/uv/install.sh /uv-installer.sh
RUN sh /uv-installer.sh && rm /uv-installer.sh
ENV PATH="/root/.local/bin/:$PATH"

RUN uv python install ${PYTHON_VERSION} --default --preview && \
    uv venv --seed /venv
ENV PATH="/venv/bin:/workspace/venv/bin:$PATH"

RUN pip install --no-cache-dir -U \
    pip setuptools wheel \
    jupyterlab jupyterlab_widgets ipykernel ipywidgets \
    numpy scipy matplotlib pandas scikit-learn seaborn requests tqdm pillow pyyaml \
    qdrant-client sentence-transformers \
    "huggingface_hub[hf_xet]" \
    open-webui==${OPEN_WEBUI_VERSION} \
    torch==${TORCH_VERSION} torchvision torchaudio --extra-index-url https://download.pytorch.org/whl/${CUDA_VERSION}

RUN uv venv --seed /opt/docling-serve-venv && \
    /opt/docling-serve-venv/bin/pip install --no-cache-dir -U pip setuptools wheel && \
    /opt/docling-serve-venv/bin/pip install --no-cache-dir "docling-serve==${DOCLING_SERVE_VERSION}"

RUN wget -O /tmp/qdrant.tar.gz "https://github.com/qdrant/qdrant/releases/download/v${QDRANT_VERSION}/qdrant-x86_64-unknown-linux-musl.tar.gz" && \
    tar -xzf /tmp/qdrant.tar.gz -C /usr/local/bin qdrant && \
    chmod +x /usr/local/bin/qdrant && \
    rm -f /tmp/qdrant.tar.gz

RUN uv venv --seed /opt/searxng-venv && \
    git init --initial-branch=main /tmp/searxng && \
    git -C /tmp/searxng remote add origin https://github.com/searxng/searxng.git && \
    git -C /tmp/searxng fetch --depth 1 origin "${SEARXNG_VERSION}" && \
    git -C /tmp/searxng checkout --detach FETCH_HEAD && \
    /opt/searxng-venv/bin/pip install --no-cache-dir -U \
        pip setuptools wheel pyyaml msgspec typing-extensions pybind11 && \
    /opt/searxng-venv/bin/pip install --no-cache-dir --use-pep517 --no-build-isolation /tmp/searxng && \
    /opt/searxng-venv/bin/pip install --no-cache-dir -r /tmp/searxng/requirements-server.txt && \
    rm -rf /tmp/searxng

COPY --from=llama-builder /artifacts/llama-server /llama-server

RUN mkdir -p /workspace/{logs,models,data,venv,searxng-cache,qdrant/storage,docling/artifacts} /etc/searxng

COPY proxy/nginx.conf /etc/nginx/nginx.conf
COPY proxy/readme.html /usr/share/nginx/html/readme.html
COPY README.md /usr/share/nginx/html/README.md
COPY searxng/settings.yml /etc/searxng/settings.yml

COPY scripts /opt/llama-open-webui/scripts
COPY scripts/start.sh /
COPY scripts/pre_start.sh /
COPY scripts/post_start.sh /
RUN chmod +x /start.sh /pre_start.sh /post_start.sh /opt/llama-open-webui/scripts/*.sh

COPY logo/runpod.txt /etc/runpod.txt
RUN echo 'cat /etc/runpod.txt' >> /root/.bashrc
RUN echo 'echo -e "\nFor detailed documentation and guides, please visit:\n\033[1;34mhttps://docs.runpod.io/\033[0m and \033[1;34mhttps://blog.runpod.io/\033[0m\n\n"' >> /root/.bashrc

CMD ["/start.sh"]
