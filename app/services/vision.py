from __future__ import annotations

import asyncio
import logging
from collections import defaultdict
from dataclasses import dataclass
from typing import Any

import numpy as np

from app.services.persistence import EnrollmentStore

logger = logging.getLogger(__name__)


@dataclass
class RecognitionResult:
    name: str
    confidence: float


class FaceRecognizer:
    def __init__(
        self,
        enrollment_store: EnrollmentStore,
        tolerance: float,
    ) -> None:
        self.enrollment_store = enrollment_store
        self.tolerance = tolerance
        self.known_encodings: list[np.ndarray] = []
        self.known_names: list[str] = []
        self._face_recognition: Any | None = None
        self._load_encodings()

    def _load_module(self) -> Any:
        if self._face_recognition is None:
            try:
                import face_recognition
            except Exception as exc:
                raise RuntimeError("face_recognition is required for vision mode.") from exc
            self._face_recognition = face_recognition
        return self._face_recognition

    def _load_encodings(self) -> None:
        data = self.enrollment_store.load()
        users = data.get("users", [])
        for user in users:
            for enc in user.get("encodings", []):
                self.known_encodings.append(np.array(enc, dtype=np.float64))
                self.known_names.append(user["name"])
        logger.info("Loaded %s known face encodings.", len(self.known_encodings))

    def recognize(self, frame: np.ndarray) -> list[RecognitionResult]:
        if not self.known_encodings:
            return []
        cv2 = __import__("cv2")
        fr = self._load_module()

        rgb = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
        locations = fr.face_locations(rgb, model="hog")
        encodings = fr.face_encodings(rgb, locations)

        out: list[RecognitionResult] = []
        for encoding in encodings:
            distances = fr.face_distance(self.known_encodings, encoding)
            best_idx = int(np.argmin(distances))
            best_distance = float(distances[best_idx])
            if best_distance <= self.tolerance:
                confidence = max(0.0, 1.0 - best_distance)
                out.append(RecognitionResult(name=self.known_names[best_idx], confidence=confidence))
        return out


class VisionLoop:
    def __init__(self, camera_index: int, width: int, height: int, recognizer: FaceRecognizer, stable_frames: int) -> None:
        self.camera_index = camera_index
        self.width = width
        self.height = height
        self.recognizer = recognizer
        self.stable_frames = stable_frames
        self.running = False

    async def run(self, on_stable_match) -> None:
        cv2 = __import__("cv2")
        self.running = True
        cap = cv2.VideoCapture(self.camera_index)
        cap.set(cv2.CAP_PROP_FRAME_WIDTH, self.width)
        cap.set(cv2.CAP_PROP_FRAME_HEIGHT, self.height)
        stable_counts = defaultdict(int)

        if not cap.isOpened():
            logger.error("Unable to open camera index %s", self.camera_index)
            return

        try:
            while self.running:
                ok, frame = cap.read()
                if not ok:
                    await asyncio.sleep(0.2)
                    continue

                matches = self.recognizer.recognize(frame)
                seen_names = {m.name for m in matches}

                for name in list(stable_counts.keys()):
                    if name not in seen_names:
                        stable_counts[name] = 0

                for match in matches:
                    stable_counts[match.name] += 1
                    if stable_counts[match.name] >= self.stable_frames:
                        stable_counts[match.name] = 0
                        await on_stable_match(match)

                await asyncio.sleep(0.08)
        finally:
            cap.release()

    def stop(self) -> None:
        self.running = False
