# Shared paths. Everything large lives on scratch (home is only 30G).
SCRATCH=/fs/nexus-scratch/$USER
VENV=$SCRATCH/venv
YOLOV10=$SCRATCH/yolov10          # THU-MIG/yolov10 checkout + weights/
RAW=$SCRATCH/egohos_raw           # unzipped EgoHOS (RAW/data/{train,val,test_indomain,test_outdomain})
YOLO_DATA=$SCRATCH/egohos_yolo    # converted YOLO dataset + data.yaml
RUNS=$SCRATCH/runs
export YOLO_CONFIG_DIR=$SCRATCH/.ultralytics
