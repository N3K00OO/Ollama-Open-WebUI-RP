#!/bin/bash
set -euo pipefail

# ---------------------------------------------------------------------------- #
#                          Function Definitions                                #
# ---------------------------------------------------------------------------- #

# Start nginx service
start_nginx() {
    echo "Starting Nginx service..."
    mkdir -p /workspace/logs /run/nginx /var/log/nginx

    if ! nginx -t; then
        echo "Nginx configuration test failed." >&2
        return 1
    fi

    if ! nginx; then
        echo "Nginx failed to start. Recent nginx error log:" >&2
        tail -200 /workspace/logs/nginx-error.log 2>/dev/null || true
        return 1
    fi
}

# Execute script if exists
execute_script() {
    local script_path=$1
    local script_msg=$2
    if [[ -f ${script_path} ]]; then
        echo "${script_msg}"
        bash "${script_path}"
    fi
}

# Setup ssh
setup_ssh() {
    if [[ -n "${PUBLIC_KEY:-}" ]]; then
        echo "Setting up SSH..."
        mkdir -p ~/.ssh
        printf '%s\n' "${PUBLIC_KEY}" >> ~/.ssh/authorized_keys
        chmod 700 ~/.ssh
        chmod 600 ~/.ssh/authorized_keys

        if [ ! -f /etc/ssh/ssh_host_rsa_key ]; then
            ssh-keygen -t rsa -f /etc/ssh/ssh_host_rsa_key -q -N ''
            echo "RSA key fingerprint:"
            ssh-keygen -lf /etc/ssh/ssh_host_rsa_key.pub
        fi

        if [ ! -f /etc/ssh/ssh_host_dsa_key ]; then
            ssh-keygen -t dsa -f /etc/ssh/ssh_host_dsa_key -q -N ''
            echo "DSA key fingerprint:"
            ssh-keygen -lf /etc/ssh/ssh_host_dsa_key.pub
        fi

        if [ ! -f /etc/ssh/ssh_host_ecdsa_key ]; then
            ssh-keygen -t ecdsa -f /etc/ssh/ssh_host_ecdsa_key -q -N ''
            echo "ECDSA key fingerprint:"
            ssh-keygen -lf /etc/ssh/ssh_host_ecdsa_key.pub
        fi

        if [ ! -f /etc/ssh/ssh_host_ed25519_key ]; then
            ssh-keygen -t ed25519 -f /etc/ssh/ssh_host_ed25519_key -q -N ''
            echo "ED25519 key fingerprint:"
            ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
        fi

        service ssh start

        echo "SSH host keys:"
        for key in /etc/ssh/*.pub; do
            [ -e "${key}" ] || continue
            echo "Key: $key"
            ssh-keygen -lf "${key}"
        done
    fi
}

# Export env vars
export_env_vars() {
    local env_file="/etc/rp_environment"
    local name=""
    local value=""
    local quoted_value=""

    echo "Exporting environment variables..."
    : > "${env_file}"

    while IFS='=' read -r name value; do
        case "${name}" in
            RUNPOD_*|PATH|_)
                printf -v quoted_value '%q' "${value}"
                printf 'export %s=%s\n' "${name}" "${quoted_value}" >> "${env_file}"
                ;;
        esac
    done < <(printenv)

    if ! grep -qxF 'source /etc/rp_environment' ~/.bashrc; then
        echo 'source /etc/rp_environment' >> ~/.bashrc
    fi
}

# Start jupyter
start_jupyter() {
    local jupyter_password=""

    if [[ -n "${JUPYTERLAB_PASSWORD:-}" ]]; then
        echo "Starting JupyterLab with the provided password..."
        jupyter_password="${JUPYTERLAB_PASSWORD}"
    else
        echo "Starting JupyterLab without a password... (JUPYTERLAB_PASSWORD environment variable is not set.)"
    fi

    mkdir -p /workspace/logs
    cd / && \
    nohup jupyter lab --allow-root \
        --no-browser \
        --port=8888 \
        "--ip=*" \
        --FileContentsManager.delete_to_trash=False \
        --ContentsManager.allow_hidden=True \
        --ServerApp.terminado_settings='{"shell_command":["/bin/bash"]}' \
        --ServerApp.token="${jupyter_password}" \
        "--ServerApp.allow_origin=*" \
        --ServerApp.preferred_dir=/workspace &> /workspace/logs/jupyterlab.log &
    echo "JupyterLab started"
}

main() {
    start_nginx

    setup_ssh
    export_env_vars

    echo "Pod Started"

    execute_script "/pre_start.sh" "Running pre-start script..."

    start_jupyter

    execute_script "/post_start.sh" "Running post-start script..."

    echo "Start script(s) finished, pod is ready to use."

    sleep infinity
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
