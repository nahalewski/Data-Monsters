#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
from pathlib import Path

import cv2
import face_recognition


def enroll(name: str, camera_index: int, output_path: Path, samples: int) -> None:
    output_path.parent.mkdir(parents=True, exist_ok=True)
    data = {"users": []}
    if output_path.exists():
        data = json.loads(output_path.read_text())

    cap = cv2.VideoCapture(camera_index)
    if not cap.isOpened():
        raise RuntimeError(f"Could not open camera index {camera_index}")

    encodings = []
    print("Look at the camera. Press ENTER to capture each sample.")
    try:
        while len(encodings) < samples:
            ok, frame = cap.read()
            if not ok:
                continue
            cv2.imshow("Enrollment", frame)
            key = cv2.waitKey(1)
            if key == 13:
                rgb = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
                boxes = face_recognition.face_locations(rgb, model="hog")
                if len(boxes) != 1:
                    print("Need exactly one visible face, try again.")
                    continue
                vec = face_recognition.face_encodings(rgb, boxes)[0]
                encodings.append(vec.tolist())
                print(f"Captured sample {len(encodings)}/{samples}")
    finally:
        cap.release()
        cv2.destroyAllWindows()

    data["users"] = [u for u in data.get("users", []) if u.get("name") != name]
    data["users"].append({"name": name, "encodings": encodings})
    output_path.write_text(json.dumps(data, indent=2))
    print(f"Saved enrollment for {name} -> {output_path}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Enroll a face profile for the morning assistant")
    parser.add_argument("--name", required=True)
    parser.add_argument("--camera-index", type=int, default=0)
    parser.add_argument("--output", default="data/enrollments.json")
    parser.add_argument("--samples", type=int, default=5)
    args = parser.parse_args()
    enroll(args.name, args.camera_index, Path(args.output), args.samples)
