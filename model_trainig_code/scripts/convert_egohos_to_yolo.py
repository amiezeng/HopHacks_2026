"""Convert EgoHOS segmentation masks into YOLO detection labels.

EgoHOS label PNGs store one category id per pixel:
    0 background, 1 left hand, 2 right hand,
    3/4/5 1st-order interacting object (left/right/both hands),
    6/7/8 2nd-order interacting object (left/right/both hands).

Each category appears at most once per image, but its mask is often split into
several fragments (occlusion, thin parts, the hand covering the object). As in
the tutorial, fragments of the same category are merged into one bounding box
by taking the min/max over all of them, so every object gets exactly one label.
YOLO class id = mask value - 1.
"""

import argparse
import os
import shutil
from functools import partial
from multiprocessing import Pool
from pathlib import Path

import cv2
import numpy as np
import yaml

NAMES = [
    "left_hand",
    "right_hand",
    "1st_order_interacting_object_left",
    "1st_order_interacting_object_right",
    "1st_order_interacting_object_both",
    "2nd_order_interacting_object_left",
    "2nd_order_interacting_object_right",
    "2nd_order_interacting_object_both",
]

# EgoHOS split name -> YOLO split name
SPLITS = {
    "train": "train",
    "val": "val",
    "test_indomain": "test",
    "test_outdomain": "test_outdomain",
}

IMG_EXTS = (".jpg", ".jpeg", ".png")


def mask_to_boxes(mask, min_area):
    """Return [(class_id, xc, yc, w, h)] normalized, one merged box per category."""
    h, w = mask.shape
    boxes = []
    for value in range(1, len(NAMES) + 1):
        binary = (mask == value).astype(np.uint8)
        if not binary.any():
            continue
        n, _, stats, _ = cv2.connectedComponentsWithStats(binary, connectivity=8)
        # stats rows: [x, y, width, height, area]; row 0 is the background
        frags = stats[1:]
        frags = frags[frags[:, cv2.CC_STAT_AREA] >= min_area]
        if len(frags) == 0:
            continue
        x0 = frags[:, cv2.CC_STAT_LEFT].min()
        y0 = frags[:, cv2.CC_STAT_TOP].min()
        x1 = (frags[:, cv2.CC_STAT_LEFT] + frags[:, cv2.CC_STAT_WIDTH]).max()
        y1 = (frags[:, cv2.CC_STAT_TOP] + frags[:, cv2.CC_STAT_HEIGHT]).max()
        boxes.append((value - 1, (x0 + x1) / 2 / w, (y0 + y1) / 2 / h, (x1 - x0) / w, (y1 - y0) / h))
    return boxes


def link_or_copy(src, dst):
    if dst.exists():
        dst.unlink()
    try:
        os.link(src, dst)
    except OSError:
        shutil.copy2(src, dst)


def convert_one(img_path, label_dir, out_img_dir, out_lbl_dir, min_area):
    label_path = label_dir / (img_path.stem + ".png")
    if not label_path.exists():
        return "missing"
    mask = cv2.imread(str(label_path), cv2.IMREAD_UNCHANGED)
    if mask is None:
        return "unreadable"
    if mask.ndim == 3:
        mask = mask[..., 0]
    boxes = mask_to_boxes(mask, min_area)
    link_or_copy(img_path, out_img_dir / img_path.name)
    with open(out_lbl_dir / (img_path.stem + ".txt"), "w") as f:
        for c, xc, yc, bw, bh in boxes:
            f.write(f"{c} {xc:.6f} {yc:.6f} {bw:.6f} {bh:.6f}\n")
    return "ok" if boxes else "empty"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", required=True, help="EgoHOS root containing train/, val/, test_indomain/ ...")
    ap.add_argument("--dst", required=True, help="output YOLO dataset root")
    ap.add_argument("--min-area", type=int, default=20, help="drop mask fragments smaller than this many pixels")
    ap.add_argument("--workers", type=int, default=os.cpu_count())
    args = ap.parse_args()

    src, dst = Path(args.src), Path(args.dst)
    present = {}
    for egohos_split, yolo_split in SPLITS.items():
        img_dir, label_dir = src / egohos_split / "image", src / egohos_split / "label"
        if not img_dir.is_dir():
            print(f"skip {egohos_split}: {img_dir} not found")
            continue
        out_img_dir, out_lbl_dir = dst / yolo_split / "images", dst / yolo_split / "labels"
        out_img_dir.mkdir(parents=True, exist_ok=True)
        out_lbl_dir.mkdir(parents=True, exist_ok=True)

        imgs = sorted(p for p in img_dir.iterdir() if p.suffix.lower() in IMG_EXTS)
        fn = partial(convert_one, label_dir=label_dir, out_img_dir=out_img_dir,
                     out_lbl_dir=out_lbl_dir, min_area=args.min_area)
        with Pool(args.workers) as pool:
            results = pool.map(fn, imgs, chunksize=64)
        counts = {k: results.count(k) for k in ("ok", "empty", "missing", "unreadable")}
        print(f"{egohos_split:>15} -> {yolo_split:<15} {len(imgs)} images {counts}")
        present[yolo_split] = f"{yolo_split}/images"

    data = {"path": str(dst.resolve()), **present, "nc": len(NAMES), "names": NAMES}
    with open(dst / "data.yaml", "w") as f:
        yaml.safe_dump(data, f, sort_keys=False)
    print(f"wrote {dst / 'data.yaml'}")


if __name__ == "__main__":
    main()
