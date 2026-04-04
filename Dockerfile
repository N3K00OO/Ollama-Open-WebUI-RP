ARG BASE_IMAGE
FROM ${BASE_IMAGE} AS llama-builder

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ARG LLAMA_CPP_VERSION

RUN apt-get update -y && \
    apt-get install -y --no-install-recommends \
        build-essential ca-certificates cmake git libssl-dev ninja-build && \
    apt-get clean && rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*

RUN git clone --branch "${LLAMA_CPP_VERSION}" --depth 1 https://github.com/ggml-org/llama.cpp.git /tmp/llama.cpp && \
    cmake -S /tmp/llama.cpp -B /tmp/llama.cpp/build -G Ninja \
        -DBUILD_SHARED_LIBS=OFF \
        -DGGML_CUDA=ON \
        -DGGML_NATIVE=OFF \
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

ENV SHELL=/bin/bash \
    PYTHONUNBUFFERED=True \
    DEBIAN_FRONTEND=noninteractive \
    TZ=Etc/UTC \
    CUDA_VERSION=${CUDA_VERSION} \
    DATA_DIR=/workspace/data \
    WEBUI_AUTH=False \
    START_LLAMA_SERVER=True \
    LLAMA_CTX_SIZE=4096 \
    LLAMA_GPU_LAYERS=999 \
    LLAMA_PARALLEL=1 \
    RESET_CONFIG_ON_START=True \
    ENABLE_OPENAI_API=True \
    OPENAI_API_BASE_URL=http://127.0.0.1:11434/v1 \
    OPENAI_API_KEY=sk-no-key-required \
    HF_HOME=/runpod-volume/.cache/huggingface/ \
    HF_XET_HIGH_PERFORMANCE=1 \
    PIP_CACHE_DIR=/runpod-volume/.cache/pip/ \
    UV_CACHE_DIR=/runpod-volume/.cache/uv/

WORKDIR /

RUN apt-get update -y && apt-get upgrade -y && \
    apt-get install -y --no-install-recommends \
        git wget curl bash nginx-light rsync sudo binutils ffmpeg lshw nano tzdata file build-essential nvtop \
        libgl1 libglib2.0-0 libssl3 openssh-server ca-certificates zstd && \
    apt-get autoremove -y && apt-get clean && rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*

ADD https://astral.sh/uv/install.sh /uv-installer.sh
RUN sh /uv-installer.sh && rm /uv-installer.sh
ENV PATH="/root/.local/bin/:$PATH"

RUN uv python install ${PYTHON_VERSION} --default --preview && \
    uv venv --seed /venv
ENV PATH="/workspace/venv/bin:/venv/bin:$PATH"

RUN pip install --no-cache-dir -U \
    pip setuptools wheel \
    jupyterlab jupyterlab_widgets ipykernel ipywidgets \
    numpy scipy matplotlib pandas scikit-learn seaborn requests tqdm pillow pyyaml \
    "huggingface_hub[hf_xet]" \
    open-webui==${OPEN_WEBUI_VERSION} \
    torch==${TORCH_VERSION} torchvision torchaudio --extra-index-url https://download.pytorch.org/whl/${CUDA_VERSION}

COPY --from=llama-builder /artifacts/llama-server /llama-server

RUN mkdir -p /workspace/{logs,models,data,venv}

COPY proxy/nginx.conf /etc/nginx/nginx.conf
COPY proxy/readme.html /usr/share/nginx/html/readme.html
COPY README.md /usr/share/nginx/html/README.md

COPY scripts /opt/llama-open-webui/scripts
COPY scripts/start.sh /
COPY scripts/pre_start.sh /
COPY scripts/post_start.sh /
RUN chmod +x /start.sh /pre_start.sh /post_start.sh /opt/llama-open-webui/scripts/*.sh

COPY logo/runpod.txt /etc/runpod.txt
RUN echo 'cat /etc/runpod.txt' >> /root/.bashrc
RUN echo 'echo -e "\nFor detailed documentation and guides, please visit:\n\033[1;34mhttps://docs.runpod.io/\033[0m and \033[1;34mhttps://blog.runpod.io/\033[0m\n\n"' >> /root/.bashrc

CMD ["/start.sh"]
