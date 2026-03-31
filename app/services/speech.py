from __future__ import annotations

import asyncio
import tempfile
from pathlib import Path


class PiperSpeechService:
    def __init__(self, piper_bin: Path, model: Path, audio_player_bin: str, audio_device: str) -> None:
        self.piper_bin = piper_bin
        self.model = model
        self.audio_player_bin = audio_player_bin
        self.audio_device = audio_device

    async def speak(self, text: str) -> None:
        with tempfile.TemporaryDirectory() as td:
            wav_path = Path(td) / "briefing.wav"
            piper_cmd = [str(self.piper_bin), "--model", str(self.model), "--output_file", str(wav_path)]
            proc = await asyncio.create_subprocess_exec(
                *piper_cmd,
                stdin=asyncio.subprocess.PIPE,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
            )
            await proc.communicate(input=text.encode("utf-8"))
            if proc.returncode != 0:
                raise RuntimeError("Piper speech generation failed.")

            play_cmd = [self.audio_player_bin, "-D", self.audio_device, str(wav_path)]
            play_proc = await asyncio.create_subprocess_exec(*play_cmd)
            await play_proc.communicate()
            if play_proc.returncode != 0:
                raise RuntimeError("Audio playback failed.")
