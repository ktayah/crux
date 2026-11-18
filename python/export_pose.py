# /// script
# requires-python = ">=3.10"
# dependencies = ["ultralytics>=8.3", "onnx>=1.16", "onnxslim"]
# ///
"""Export the pose model the Elixir app runs, as ONNX.

This is the only Python in the MVP. The contract with the Elixir side is:

  input  "images": f32 [1, 3, 640, 640], RGB, 0..1, letterboxed (centered pad)
  output          : f32 [1, 56, 8400]
                    rows 0-3  box cx, cy, w, h (input pixels)
                    row  4    person confidence
                    rows 5-55 17 COCO keypoints as (x, y, visibility)

Run from the repo root:  uv run python/export_pose.py
"""

import shutil
from pathlib import Path

from ultralytics import YOLO

OUT = Path(__file__).resolve().parent.parent / "priv" / "models" / "pose.onnx"


def main() -> None:
    model = YOLO("yolo11n-pose.pt")
    exported = model.export(format="onnx", imgsz=640, opset=17, dynamic=False, simplify=True)
    OUT.parent.mkdir(parents=True, exist_ok=True)
    shutil.move(exported, OUT)
    print(f"wrote {OUT}")


if __name__ == "__main__":
    main()
