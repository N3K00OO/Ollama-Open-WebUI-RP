#!/bin/bash
set -euo pipefail

export PYTHONUNBUFFERED=1

echo "**** Setting the timezone based on the TIME_ZONE environment variable. If not set, it defaults to Etc/UTC. ****"
requested_tz="${TIME_ZONE:-Etc/UTC}"
if [ -f "/usr/share/zoneinfo/${requested_tz}" ]; then
    export TZ="${requested_tz}"
else
    echo "**** Invalid TIME_ZONE '${requested_tz}'. Falling back to Etc/UTC. Use a full tz database name like Asia/Bangkok or Asia/Jakarta. ****"
    export TZ="Etc/UTC"
fi
echo "**** Timezone set to $TZ ****"
echo "$TZ" | sudo tee /etc/timezone > /dev/null
sudo ln -sf "/usr/share/zoneinfo/$TZ" /etc/localtime
sudo dpkg-reconfigure -f noninteractive tzdata

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

if is_true "${SYNC_VENV_TO_WORKSPACE:-False}" && [ -d /venv ]; then
    echo "**** syncing venv to workspace, please wait. This could take a while on first startup! ****"
    mkdir -p /workspace/venv
    rsync -au --remove-source-files /venv/ /workspace/venv/
    rm -rf /venv
elif [ -d /venv ]; then
    echo "**** using image venv at /venv. Set SYNC_VENV_TO_WORKSPACE=True to copy it into /workspace/venv. ****"
else
    echo "**** /venv has already been moved or is not present. Reusing /workspace/venv. ****"
fi

if [ ! -d /workspace/venv/bin ] && [ ! -d /venv/bin ]; then
    echo "**** No Python venv found at /workspace/venv/bin or /venv/bin. ****" >&2
    exit 1
fi

if [ ! -d /workspace/venv/bin ]; then
    exit 0
fi

# Update venv launchers and activation scripts after moving /venv to /workspace/venv.
find "/workspace/venv/bin" -type f -print0 | while IFS= read -r -d '' file; do
    if file "$file" | grep -q "text"; then
        # VIRTUAL_ENV='/venv' -> VIRTUAL_ENV='/workspace/venv'
        sed -i "s|VIRTUAL_ENV='/venv'|VIRTUAL_ENV='/workspace/venv'|g" "$file"

        # VIRTUAL_ENV '/venv' -> VIRTUAL_ENV '/workspace/venv'
        sed -i "s|VIRTUAL_ENV '/venv'|VIRTUAL_ENV '/workspace/venv'|g" "$file"

        # #!/venv/bin/python -> #!/workspace/venv/bin/python
        sed -i "s|#!/venv/bin/python|#!/workspace/venv/bin/python|g" "$file"
    fi
done
