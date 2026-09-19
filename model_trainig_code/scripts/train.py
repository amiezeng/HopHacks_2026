import argparse 

import torch
from ultralytics import YOLOv10


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--data", required=True, help="data.yaml written by convert_egohos_to_yolo.py")
    ap.add_argument("--weights", required=True, help="pretrained checkpoint, e.g. yolov10n.pt")
    ap.add_argument("--name", default="trained_model")
    ap.add_argument("--project", default="runs/train")
    ap.add_argument("--epochs", type=int, default=130)
    ap.add_argument("--batch", type=int, default=32)
    ap.add_argument("--workers", type=int, default=8)
    ap.add_argument("--fraction", type=float, default=1.0, help="fraction of the train set to use (smoke tests)")
    args = ap.parse_args()

    # The tutorial hardcodes device=[0,1]; use every GPU Slurm gave us instead.
    n_gpus = torch.cuda.device_count()
    device = list(range(n_gpus)) if n_gpus > 1 else (0 if n_gpus == 1 else "cpu")

    model = YOLOv10(args.weights)
    model.train(
            data=args.data,
            batch=args.batch,
            imgsz=640,
            epochs=args.epochs,
            optimizer="SGD",
            lr0=0.01,
            lrf=0.1,
            weight_decay=0.0005,
            momentum=0.937,
            verbose=True,
            device=device,
            workers=args.workers,
            project=args.project,
            name=args.name,
            exist_ok=False,
            rect=False,
            multi_scale=False,
            single_cls=False,
            fraction=args.fraction,
            # Deviation from the tutorial: Ultralytics mirrors images left-right 50% of the
            # time by default without swapping class ids, which would teach the model that
            # a mirrored left hand is still "left_hand". Disable it for these classes.
            fliplr=0.0,
            )


if __name__ == "__main__":
    main()

