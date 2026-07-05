"""STT pipeline stage: push-to-talk recording + faster-whisper transcription.

Interface:
    stt = STTPipeline(config)
    audio = stt.record()           # blocks: hold Space → record → release
    text  = stt.transcribe(audio)  # returns "" if no speech / low confidence

This module is intentionally self-contained so it can be swapped out in
later phases without touching the caller (e.g. when barge-in / VAD
auto-stop is added in Phase 3).
"""
from __future__ import annotations

import threading
from typing import TYPE_CHECKING

import numpy as np

if TYPE_CHECKING:
    from app.config import Config

SAMPLE_RATE = 16_000   # Whisper requires 16 kHz
MIN_DURATION_S = 0.3   # recordings shorter than this are silently discarded


class STTPipeline:
    """Wraps faster-whisper with push-to-talk recording via pynput."""

    def __init__(self, config: Config) -> None:
        self._config = config
        self._model = self._load_model(config)

    # ------------------------------------------------------------------
    # Public API
    # ------------------------------------------------------------------

    def record(self) -> np.ndarray:
        """Block until the user holds Space, record audio, return on release.

        Returns a float32 mono array at SAMPLE_RATE.
        Returns an empty array if Space was tapped too briefly.

        Raises RuntimeError if the keyboard listener cannot start (most
        commonly: macOS Accessibility permission not granted).
        """
        import sounddevice as sd
        from pynput import keyboard

        chunks: list[np.ndarray] = []
        started = threading.Event()
        done = threading.Event()

        def _audio_cb(indata: np.ndarray, frames: int, time, status) -> None:
            if started.is_set() and not done.is_set():
                chunks.append(indata.copy())

        def _on_press(key) -> None:
            if key == keyboard.Key.space:
                started.set()

        def _on_release(key):
            if key == keyboard.Key.space and started.is_set():
                done.set()
                return False  # stop the listener

        try:
            # Start audio stream before waiting for keypress so the first
            # frames are captured without a latency gap.
            with sd.InputStream(
                samplerate=SAMPLE_RATE,
                channels=1,
                dtype="float32",
                callback=_audio_cb,
            ):
                with keyboard.Listener(
                    on_press=_on_press,
                    on_release=_on_release,
                ) as listener:
                    done.wait()
        except Exception as exc:
            msg = str(exc)
            if "accessibility" in msg.lower() or "CGEventTap" in msg:
                raise RuntimeError(
                    "pynput needs Accessibility permission on macOS.\n"
                    "  System Settings → Privacy & Security → Accessibility\n"
                    "  → add Terminal (or your app) and try again."
                ) from exc
            raise

        if not chunks:
            return np.zeros(0, dtype=np.float32)

        audio = np.concatenate(chunks, axis=0).squeeze()
        return audio

    def transcribe(self, audio: np.ndarray) -> str:
        """Transcribe audio, returning the text or "" if no/low-confidence speech.

        Filters using:
        - minimum duration (avoids sending silence)
        - per-segment no_speech_prob threshold (from config)
        - per-segment avg_logprob (-1.0 floor for garbled output)
        """
        if audio.ndim == 0 or len(audio) < int(SAMPLE_RATE * MIN_DURATION_S):
            return ""

        threshold = self._config.models.stt.no_speech_threshold

        segments, _info = self._model.transcribe(
            audio,
            language="en",
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
