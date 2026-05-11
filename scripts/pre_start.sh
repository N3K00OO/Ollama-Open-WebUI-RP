#!/bin/bash

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

echo "**** syncing venv to workspace, please wait. This could take a while on first startup! ****"
rsync -au --remove-source-files /venv/ /workspace/venv/ && rm -rf /venv
# Updating '/venv' to '/workspace/venv' in all text files under '/workspace/venv/bin'
find "/workspace/venv/bin" -type f | while read -r file; do
    if file "$file" | grep -q "text"; then
        # VIRTUAL_ENV='/venv' → VIRTUAL_ENV='/workspace/venv'
        sed -i "s|VIRTUAL_ENV='/venv'|VIRTUAL_ENV='/workspace/venv'|g" "$file"
        
        # VIRTUAL_ENV '/venv' → VIRTUAL_ENV '/workspace/venv'
        sed -i "s|VIRTUAL_ENV '/venv'|VIRTUAL_ENV '/workspace/venv'|g" "$file"
        
        # #!/venv/bin/python → #!/workspace/venv/bin/python
        sed -i "s|#!/venv/bin/python|#!/workspace/venv/bin/python|g" "$file"

        # Uncomment to see which files are updated
        #echo "Updated: $file"
    fi
done
