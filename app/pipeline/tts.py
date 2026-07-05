"""TTS pipeline stage: synthesises text and plays audio.

Interface:
    tts = TTSPipeline(config)
    tts.speak("Hello!")          # synthesise and play, blocks until done
    tts.speak("Hello!", stop)    # same but stops early if stop event is set

Backend selection (automatic):
    1. Piper (piper-tts) — offline, good quality, child-friendly pitch
    2. macOS system TTS ('say') — zero-dependency fallback, always works

The voice model is downloaded automatically on first use (~60 MB).
"""
from __future__ import annotations

import subprocess
import threading
import time
from pathlib import Path
from typing import TYPE_CHECKING

import numpy as np

if TYPE_CHECKING:
    from app.config import Config

# HuggingFace repo that hosts all Piper voice models
_HF_REPO = "rhasspy/piper-voices"
# Local cache for downloaded voice files
_VOICE_CACHE = Path.home() / ".local" / "share" / "piper" / "voices"


# ---------------------------------------------------------------------------
# Public facade
# ---------------------------------------------------------------------------

class TTSPipeline:
    """Synthesises speech from text sentences.

    The public interface is intentionally minimal so the backend can be
    swapped (e.g. XTTS v2, ElevenLabs) without touching the caller.
    """

    def __init__(self, config: Config) -> None:
        self._backend = _create_backend(config)

    def speak(self, text: str, stop: threading.Event | None = None) -> None:
        """Synthesise *text* and play it.

        Blocks until playback is complete (or *stop* is set).
        Empty / whitespace-only strings are silently skipped.
        """
        text = text.strip()
        if not text:
            return
        self._backend.speak(text, stop)


# ---------------------------------------------------------------------------
# Backend selection
# ---------------------------------------------------------------------------

def _create_backend(config: "Config"):
    try:
        backend = _PiperBackend(config)
        return backend
    except Exception as exc:
        print(f"\n[TTS] Piper unavailable ({exc}), using macOS system voice.")
        return _SystemTTSBackend(config)


# ---------------------------------------------------------------------------
# Piper backend
# ---------------------------------------------------------------------------

class _PiperBackend:
    """Piper TTS: downloads the voice model on first use, synthesises offline."""

    def __init__(self, config: "Config") -> None:
        from piper.voice import PiperVoice
        from piper.config import SynthesisConfig

        voice_name = config.models.tts.voice
        model_path = _ensure_voice(voice_name)

        print(f"Loading Piper voice ({voice_name})…", end="", flush=True)
        self._voice = PiperVoice.load(str(model_path))
        self._sample_rate: int = self._voice.config.sample_rate
        self._syn_config = SynthesisConfig(
            length_scale=config.models.tts.length_scale,
        )
        print(" ready.")

    def speak(self, text: str, stop: threading.Event | None = None) -> None:
        import sounddevice as sd

        # Synthesise all chunks first (Piper is fast enough that buffering
        # the full sentence adds negligible latency vs. streaming)
        chunks: list[np.ndarray] = []
        for chunk in self._voice.synthesize(text, syn_config=self._syn_config):
            if stop and stop.is_set():
                return
            chunks.append(chunk.audio_int16_array)

        if not chunks:
            return

        audio = np.concatenate(chunks)
        sd.play(audio, samplerate=self._sample_rate)

        # Poll so we can honour stop events during playback
        while True:
            try:
                stream = sd.get_stream()
                if not stream.active:
                    break
            except Exception:
                break
            if stop and stop.is_set():
                sd.stop()
                return
            time.sleep(0.02)


# ---------------------------------------------------------------------------
# macOS system TTS fallback
# ---------------------------------------------------------------------------

class _SystemTTSBackend:
    """Uses macOS 'say' command — no install, instant availability."""

    # Samantha is the clearest built-in US English voice for a learner
    _VOICE = "Samantha"
    _RATE = 160  # words per minute (default ~175; slightly slower for a learner)

    def __init__(self, config: "Config") -> None:
        print(f"[TTS] Using macOS system voice ({self._VOICE}, {self._RATE} wpm)")

    def speak(self, text: str, stop: threading.Event | None = None) -> None:
        proc = subprocess.Popen(
            ["say", "-v", self._VOICE, "-r", str(self._RATE), text]
        )
        if stop:
            while proc.poll() is None:
                if stop.is_set():
                    proc.terminate()
                    return
                time.sleep(0.05)
        else:
            proc.wait()


# ---------------------------------------------------------------------------
# Voice downloader
# ---------------------------------------------------------------------------

def _ensure_voice(voice_name: str) -> Path:
    """Return path to the local .onnx model, downloading it if needed.

    Voice name format: en_US-lessac-medium
    HF path pattern:   en/en_US/lessac/medium/en_US-lessac-medium.onnx
    """
    _VOICE_CACHE.mkdir(parents=True, exist_ok=True)
    model_path = _VOICE_CACHE / f"{voice_name}.onnx"

    if not model_path.exists():
        _download_voice(voice_name, model_path)

    # Config JSON sits alongside the model file
    config_path = _VOICE_CACHE / f"{voice_name}.onnx.json"
    if not config_path.exists():
        _download_voice_file(voice_name, f"{voice_name}.onnx.json", config_path)

    return model_path


def _hf_path(voice_name: str) -> str:
    """Convert 'en_US-lessac-medium' → 'en/en_US/lessac/medium'."""
    parts = voice_name.split("-")          # ['en_US', 'lessac', 'medium']
    lang = parts[0].split("_")[0]          # 'en'
    return f"{lang}/{parts[0]}/{parts[1]}/{parts[2]}"


def _download_voice(voice_name: str, dest: Path) -> None:
    _download_voice_file(voice_name, f"{voice_name}.onnx", dest)


def _download_voice_file(voice_name: str, filename: str, dest: Path) -> None:
    from huggingface_hub import hf_hub_download

    hf_path = _hf_path(voice_name)
    print(f"\nDownloading Piper voice file: {filename}…")
    local = hf_hub_download(
        repo_id=_HF_REPO,
        filename=f"{hf_path}/{filename}",
        local_dir=str(_VOICE_CACHE),
    )
    # hf_hub_download may nest under subfolders; copy to expected flat location
    local_path = Path(local)
    if local_path != dest:
        import shutil
        shutil.copy2(local_path, dest)
    print(f"  → saved to {dest}")
