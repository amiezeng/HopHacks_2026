#!/bin/bash
# Download EgoHOS from the authors' Google Drive link (same file as EgoHOS/download_datasets.sh).
# The public link often hits Google's "Quota exceeded" limit; when that happens,
# wait and try again (the quota typically resets within 24h).
set -euo pipefail
source "$(dirname "$0")/../trainig_scripts/config.sh"
MAX_TRIES=${MAX_TRIES:-40}
WAIT=${WAIT:-3600}
URL="https://drive.usercontent.google.com/download?id=1sk0TVEhZESNF67OW3fz9D5coqpIWkwuK&export=download&confirm=t"

if [ -d "$RAW/data/train/label" ]; then
    echo "EgoHOS already at $RAW"; exit 0
fi
mkdir -p "$RAW"
zip=$RAW/egohos_dataset.zip
for ((i = 1; i <= MAX_TRIES; i++)); do
    echo "[$(date)] download attempt $i/$MAX_TRIES"
    rm -f "$zip"
    if curl -fsSL --retry 3 -o "$zip" "$URL" && [ "$(head -c 2 "$zip")" = "PK" ] \
        && unzip -q -o "$zip" -d "$RAW"; then
        rm -f "$zip"
        for d in "$RAW"/data/*/*; do echo "$d: $(ls "$d" | wc -l) files"; done
        exit 0
    fi
    echo "[$(date)] failed ($(head -c 200 "$zip" 2>/dev/null | grep -o '<title>[^<]*' || echo 'no zip')); retrying in ${WAIT}s"
    sleep "$WAIT"
done
echo "giving up after $MAX_TRIES attempts" >&2
exit 1
