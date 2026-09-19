"""Download YOLOE-26n-seg (open-vocabulary) and export it to CoreML with a fixed text-prompt vocabulary.

YOLOE takes text prompts at runtime in PyTorch, but CoreML can't run the text encoder, so the prompts are
baked in with set_classes() before export. The exported model is end-to-end (NMS-free): [1, 300, 6 + 32]
rows of x1, y1, x2, y2, score, class, mask coeffs, plus a [1, 32, 160, 160] proto tensor. Class names are
stored in the model metadata; app/Segmentation.swift decodes this layout.

Usage: python export_yoloe.py [--classes "beverage can" "soda can" ...] [--out ../../models/yoloe-26n-seg.mlpackage]
Needs ultralytics >= 8.4 (YOLOE-26 weights).
"""
import argparse
import shutil
from pathlib import Path

from ultralytics import YOLOE

DEFAULT_CLASSES = ["beverage can", "soda can"]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--weights", default="../../models/yoloe-26n-seg.pt")
    parser.add_argument("--classes", nargs="+", default=DEFAULT_CLASSES)
    parser.add_argument("--imgsz", type=int, default=640)
    parser.add_argument("--out", default=None, help="where to move the exported .mlpackage")
    args = parser.parse_args()

    model = YOLOE(args.weights)  # downloads the weights on first use
    model.set_classes(args.classes, model.get_text_pe(args.classes))
    exported = Path(model.export(format="coreml", imgsz=args.imgsz, nms=False))
    print(f"exported {exported} with classes {args.classes}")

    if args.out and Path(args.out).resolve() != exported.resolve():
        out = Path(args.out)
        if out.exists():
            shutil.rmtree(out)
        shutil.move(str(exported), out)
        print(f"moved to {out}")


if __name__ == "__main__":
    main()
