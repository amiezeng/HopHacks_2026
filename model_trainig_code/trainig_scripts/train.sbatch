#!/bin/bash
#SBATCH --job-name=yolov10-egohos
#SBATCH --partition=gamma
#SBATCH --account=gamma
#SBATCH --qos=medium
#SBATCH --gres=gpu:2
#SBATCH --cpus-per-task=8
#SBATCH --mem=64G
#SBATCH --time=2-00:00:00
#SBATCH --output=logs/%x-%j.out
set -euo pipefail
source "$SLURM_SUBMIT_DIR/config.sh"
SCRIPTS=$SLURM_SUBMIT_DIR/../scripts

nvidia-smi
cd "$YOLOV10"   # like the tutorial; also where Ultralytics drops its AMP-check weights
# medium QoS caps jobs at 8 CPUs, so 4 dataloader workers per GPU (tutorial used 8).
"$VENV/bin/python" "$SCRIPTS/train.py" \
    --data "${DATA_YAML:-$YOLO_DATA/data.yaml}" \
    --weights "$YOLOV10/weights/yolov10n.pt" \
    --project "$RUNS/train" \
    --name "${RUN_NAME:-trained_model}" \
    --workers 4 \
    ${TRAIN_ARGS:-}
