#!/bin/bash
# One-time environment setup (run on the submit node).
set -euo pipefail
source "$(dirname "$0")/config.sh"
export PIP_CACHE_DIR=$SCRATCH/.pip-cache

[ -d "$VENV" ] || /opt/local/stow/Python3-3.10.14/bin/python3 -m venv "$VENV"
"$VENV/bin/pip" install --upgrade pip

[ -d "$YOLOV10" ] || git clone https://github.com/THU-MIG/yolov10.git "$YOLOV10"
"$VENV/bin/pip" install torch==2.0.1 torchvision==0.15.2 --index-url https://download.pytorch.org/whl/cu118
"$VENV/bin/pip" install "$YOLOV10" "numpy<2" huggingface-hub==0.23.2 safetensors==0.4.3

mkdir -p "$YOLOV10/weights"
for m in yolov10n yolov10l; do
    [ -f "$YOLOV10/weights/$m.pt" ] || curl -fL -o "$YOLOV10/weights/$m.pt" \
        "https://github.com/jameslahm/yolov10/releases/download/v1.0/$m.pt"
done
