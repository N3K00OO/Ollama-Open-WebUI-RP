variable "IMAGE_REPO_NAME" {
    default = "ghcr.io/n3k00oo/ollama-open-webui-rp"
}

variable "PYTHON_VERSION" {
    default = "3.11"
}
variable "TORCH_VERSION" {
    default = "2.11.0"
}

variable "OPEN_WEBUI_VERSION" {
    default = "0.8.12"
}

variable "LLAMA_CPP_VERSION" {
    default = "b8660"
}

variable "EXTRA_TAG" {
    default = ""
}

function "tag" {
    params = [tag, cuda]
    result = ["${IMAGE_REPO_NAME}:${tag}-torch${TORCH_VERSION}-${cuda}${EXTRA_TAG}"]
}

target "_common" {
    dockerfile = "Dockerfile"
    context = "."
    args = {
        PYTHON_VERSION     = PYTHON_VERSION
        TORCH_VERSION      = TORCH_VERSION
        OPEN_WEBUI_VERSION = OPEN_WEBUI_VERSION
        LLAMA_CPP_VERSION  = LLAMA_CPP_VERSION
    }
}

target "_cu126" {
    inherits = ["_common"]
    args = {
        BASE_IMAGE         = "nvidia/cuda:12.6.3-devel-ubuntu22.04"
        CUDA_VERSION       = "cu126"
    }
}

target "_cu128" {
    inherits = ["_common"]
    args = {
        BASE_IMAGE         = "nvidia/cuda:12.8.1-devel-ubuntu22.04"
        CUDA_VERSION       = "cu128"
    }
}

target "_cu130" {
    inherits = ["_common"]
    args = {
        BASE_IMAGE         = "nvidia/cuda:13.0.2-devel-ubuntu22.04"
        CUDA_VERSION       = "cu130"
    }
}

target "_cu124" {
    inherits = ["_common"]
    args = {
        BASE_IMAGE         = "nvidia/cuda:12.4.1-devel-ubuntu22.04"
        CUDA_VERSION       = "cu124"
    }
}

target "_cu125" {
    inherits = ["_common"]
    args = {
        BASE_IMAGE         = "nvidia/cuda:12.5.1-devel-ubuntu22.04"
        CUDA_VERSION       = "cu125"
    }
}

target "base-12-4" {
    inherits = ["_cu124"]
    tags = tag("base", "cu124")
}

target "base-12-5" {
    inherits = ["_cu125"]
    tags = tag("base", "cu125")
}

target "base-12-6" {
    inherits = ["_cu126"]
    tags = tag("base", "cu126")
}

target "base-12-8" {
    inherits = ["_cu128"]
    tags = tag("base", "cu128")
}

target "base-13-0" {
    inherits = ["_cu130"]
    tags = tag("base", "cu130")
}
