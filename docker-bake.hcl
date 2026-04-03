variable "IMAGE_REPO_NAME" {
    default = "ghcr.io/somb1/ollama-open-webui-rp"
}

variable "PYTHON_VERSION" {
    default = "3.11"
}
variable "TORCH_VERSION" {
    default = "2.7.0"
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
    }
}

target "_cu124" {
    inherits = ["_common"]
    args = {
        BASE_IMAGE         = "nvidia/cuda:12.4.1-devel-ubuntu22.04"
        CUDA_VERSION       = "cu124"
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

target "base-12-4" {
    inherits = ["_cu124"]
    tags = tag("base", "cu124")
}

target "base-12-6" {
    inherits = ["_cu126"]
    tags = tag("base", "cu126")
}

target "base-12-8" {
    inherits = ["_cu128"]
    tags = tag("base", "cu128")
}
