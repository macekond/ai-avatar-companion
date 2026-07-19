"""STT pipeline stage: push-to-talk recording + faster-whisper transcription.

Interface:
    stt = STTPipeline(config)
    audio = stt.record()           # blocks: Space to start, Space to stop
    text  = stt.transcribe(audio)  # returns "" if no speech / low confidence

Recording uses tty/termios raw mode (stdlib only) so no macOS Accessibility
permission is required. The hold-Space mechanic in the design document is
for the final Tauri shell UI; in the terminal prototype, a toggle (press
once to start, press once to stop) is the correct interaction model.
"""
from __future__ import annotations

import os
import sys
import termios
import threading
import tty
from pathlib import Path
from typing import TYPE_CHECKING

import numpy as np

if TYPE_CHECKING:
    from app.config import Config

SAMPLE_RATE = 16_000   # Whisper requires 16 kHz
MIN_DURATION_S = 0.3   # recordings shorter than this are silently discarded


def whisper_is_cached(model_id: str, cache_dir: "Path | None" = None) -> bool:
    """True if the faster-whisper model is already downloaded (no fetch needed).

    Bare size names ("small.en") resolve to Systran's HuggingFace repo; a
    model_id that is itself a local directory or an explicit "org/repo" is used
    as-is. Mirrors tts.voice_is_cached so the setup screen can honestly say
    "loading" rather than "downloading ~600 MB" on cached launches.

    A `models--…/snapshots` folder with no snapshot inside means an interrupted
    download — reported as *not* cached so the first-run message still shows.
    """
    if os.path.isdir(model_id):
        return True
    repo = model_id if "/" in model_id else f"Systran/faster-whisper-{model_id}"
    if cache_dir is not None:
        base = Path(cache_dir)
    else:
        from huggingface_hub.constants import HF_HUB_CACHE
        base = Path(HF_HUB_CACHE)
    snapshots = base / ("models--" + repo.replace("/", "--")) / "snapshots"
    return snapshots.is_dir() and any(snapshots.iterdir())

_STOP_KEYS = {' ', '\r', '\n'}  # Space or Enter = stop recording
_QUIT_KEYS = {'\x03', '\x1b', 'q', 'Q'}  # Ctrl-C, Escape, q = exit


class STTPipeline:
    """Wraps faster-whisper with toggle-mode recording via tty raw input."""

    def __init__(self, config: Config) -> None:
        self._config = config
        self._model = self._load_model(config)

    # ------------------------------------------------------------------
    # Public API
    # ------------------------------------------------------------------

    def record(self) -> np.ndarray:
        """Toggle-mode recording via terminal raw input — no permissions required.

        Press Space (or Enter) to START recording.
        Press Space (or Enter) again to STOP and return the audio.
        Ctrl-C / Escape / q exits the voice loop (raises KeyboardInterrupt).

        Returns a float32 mono array at SAMPLE_RATE, or an empty array if
        the recording was too short to be useful.
        """
        import sounddevice as sd

        if not sys.stdin.isatty():
            raise RuntimeError("stdin is not a TTY — cannot read keystrokes.")

        chunks: list[np.ndarray] = []
        capturing = threading.Event()

        def _audio_cb(indata: np.ndarray, frames: int, time, status) -> None:
            if capturing.is_set():
                chunks.append(indata.copy())

        fd = sys.stdin.fileno()
        saved = termios.tcgetattr(fd)

        try:
            tty.setraw(fd)

            # Audio stream always open; we only collect when capturing is set,
            # so the first frame is never dropped by stream startup latency.
            with sd.InputStream(
                samplerate=SAMPLE_RATE,
                channels=1,
                dtype="float32",
                callback=_audio_cb,
            ):
                # --- wait for START key ---
                while True:
                    ch = sys.stdin.read(1)
                    if ch in _QUIT_KEYS:
                        raise KeyboardInterrupt
                    if ch in _STOP_KEYS:
                        capturing.set()
                        break

                # --- wait for STOP key ---
                while True:
                    ch = sys.stdin.read(1)
                    if ch in _QUIT_KEYS:
                        raise KeyboardInterrupt
                    if ch in _STOP_KEYS:
                        break

        finally:
            termios.tcsetattr(fd, termios.TCSADRAIN, saved)

        if not chunks:
            return np.zeros(0, dtype=np.float32)

        audio = np.concatenate(chunks, axis=0).squeeze()
        return audio

    def transcribe(self, audio: np.ndarray, language: str | None = None) -> str:
        """Transcribe audio, returning the text or "" if no/low-confidence speech.

        *language* is the ISO code Whisper should decode as ("en", "ja", …). It
        must be passed per call because the active child's practice language can
        change at runtime (profile swap). When None, falls back to the config's
        default language. The model must be multilingual (e.g. "small", not the
        English-only "small.en") for any non-English language to work.

        Filters using:
        - minimum duration (avoids sending silence)
        - per-segment no_speech_prob threshold (from config)
        - per-segment avg_logprob (-1.0 floor for garbled output)
        """
        if audio.ndim == 0 or len(audio) < int(SAMPLE_RATE * MIN_DURATION_S):
            return ""

        threshold = self._config.models.stt.no_speech_threshold
        lang = language or getattr(self._config.child, "language", "en")

        segments, _info = self._model.transcribe(
            audio,
            language=lang,
            vad_filter=True,
            vad_parameters={"min_silence_duration_ms": 300},
        )

        good: list[str] = []
        for seg in segments:
            if seg.no_speech_prob >= threshold:
                continue
            if seg.avg_logprob < -1.0:
                continue
            text = seg.text.strip()
            if text:
                good.append(text)

        return " ".join(good)

    # ------------------------------------------------------------------
    # Internals
    # ------------------------------------------------------------------

    @staticmethod
    def _load_model(config: Config):
        from faster_whisper import WhisperModel

        model_id = config.models.stt.model
        print(f"Loading Whisper model ({model_id}) — first run downloads ~500 MB…",
              end="", flush=True)
        model = WhisperModel(
            model_id,
            device="cpu",
            compute_type="auto",
        )
        print(" ready.")
        return model
