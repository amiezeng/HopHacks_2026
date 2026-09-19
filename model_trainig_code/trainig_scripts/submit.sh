#!/bin/bash
# Submit data prep, then training once prep succeeds.
#
# The EgoHOS Google Drive link is often over quota, so prep keeps retrying.
# Chain A tries right away with time limits short enough to finish before the
# monthly maintenance reservation. If prep A fails (quota still exhausted),
# chain B takes over with full time limits. Slurm is configured with
# kill_invalid_depend, so whichever chain isn't needed is cancelled automatically.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p logs

prep_a=$(sbatch --parsable --time=14:00:00 --export=ALL,MAX_TRIES=13 prep.sbatch)
train_a=$(sbatch --parsable --time=08:00:00 --dependency=afterok:$prep_a train.sbatch)
prep_b=$(sbatch --parsable --dependency=afternotok:$prep_a prep.sbatch)
train_b=$(sbatch --parsable --dependency=afterok:$prep_b train.sbatch)

echo "chain A: prep $prep_a -> train $train_a"
echo "chain B: prep $prep_b -> train $train_b (only if $prep_a fails)"
