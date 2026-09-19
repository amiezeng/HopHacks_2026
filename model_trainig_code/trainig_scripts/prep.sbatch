#!/bin/bash
#SBATCH --job-name=egohos-prep
#SBATCH --partition=gamma
#SBATCH --account=gamma
#SBATCH --qos=default
#SBATCH --cpus-per-task=4
#SBATCH --mem=16G
#SBATCH --time=2-00:00:00
#SBATCH --output=logs/%x-%j.out
set -euo pipefail
source "$SLURM_SUBMIT_DIR/config.sh"
SCRIPTS=$SLURM_SUBMIT_DIR/../scripts

bash "$SCRIPTS/download_egohos.sh"
"$VENV/bin/python" "$SCRIPTS/convert_egohos_to_yolo.py" --src "$RAW/data" --dst "$YOLO_DATA" --workers "$SLURM_CPUS_PER_TASK"
