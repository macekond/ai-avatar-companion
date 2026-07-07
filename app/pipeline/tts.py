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
        self._config = config
        self._backend = _create_backend(config)

    @property
    def current_voice(self) -> str:
        """Voice name currently in use (or '' for the system fallback)."""
        return getattr(self._backend, "voice_name", "")

    def reload_voice(self, voice_name: str) -> bool:
        """Swap to a different Piper voice, downloading it if needed.

        Returns True on success. On failure the previous backend is kept so
        the session keeps working with the old voice.
        """
        try:
            new_backend = _PiperBackend(self._config, voice_override=voice_name)
        except Exception as exc:
            print(f"[TTS] Could not load voice '{voice_name}': {exc}")
            return False
        self._backend = new_backend
        return True

    def speak(self, text: str, stop: threading.Event | None = None) -> None:
        """Synthesise *text* and play it.

        Blocks until playback is complete (or *stop* is set).
        Empty / whitespace-only strings are silently skipped.
        """
        text = text.strip()
        if not text:
            return
        self._backend.speak(text, stop)

    def speak_streaming(
        self,
        text: str,
        amplitude_cb=None,
        stop: threading.Event | None = None,
    ) -> None:
        """Synthesise and play *text*, calling *amplitude_cb(float)* at ~20 Hz.

        *amplitude_cb* receives normalised RMS energy (0.0–1.0) and is called
        from the audio thread — must be thread-safe (use run_coroutine_threadsafe
        for asyncio contexts). Falls back to plain speak() when callback is None.
        """
        text = text.strip()
        if not text:
            return
        self._backend.speak_streaming(text, amplitude_cb, stop)


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

    def __init__(self, config: "Config", voice_override: str | None = None) -> None:
        from piper.voice import PiperVoice
        from piper.config import SynthesisConfig

        voice_name = voice_override or config.models.tts.voice
        model_path = _ensure_voice(voice_name)

        print(f"Loading Piper voice ({voice_name})…", end="", flush=True)
        self._voice = PiperVoice.load(str(model_path))
        self.voice_name = voice_name
        self._sample_rate: int = self._voice.config.sample_rate
        self._syn_config = SynthesisConfig(
            length_scale=config.models.tts.length_scale,
        )
        print(" ready.")

    def speak(self, text: str, stop: threading.Event | None = None) -> None:
        self.speak_streaming(text, amplitude_cb=None, stop=stop)

    def speak_streaming(
        self,
        text: str,
        amplitude_cb=None,
        stop: threading.Event | None = None,
    ) -> None:
        import sounddevice as sd

        chunks: list[np.ndarray] = []
        for chunk in self._voice.synthesize(text, syn_config=self._syn_config):
            if stop and stop.is_set():
                return
            chunks.append(chunk.audio_int16_array)

        if not chunks:
            return

        # Normalise to float32 [-1, 1] for the output stream
        audio = np.concatenate(chunks).astype(np.float32) / 32768.0
        BLOCK = max(256, self._sample_rate // 20)   # ~50 ms → ~20 Hz amplitude
        pos = [0]

        def _cb(outdata, frames, _time, _status):
            end = pos[0] + frames
            chunk = audio[pos[0]:end]
            n = len(chunk)
            outdata[:n, 0] = chunk
            outdata[n:, 0] = 0.0
            if amplitude_cb and n > 0:
                rms = float(np.sqrt(np.mean(chunk.astype(np.float64) ** 2)))
                amplitude_cb(min(1.0, rms * 5.0))
            pos[0] = end

        with sd.OutputStream(
            samplerate=self._sample_rate,
            channels=1,
            dtype="float32",
            blocksize=BLOCK,
            callback=_cb,
        ):
            while pos[0] < len(audio):
                if stop and stop.is_set():
                    break
                time.sleep(0.02)
            time.sleep(0.05)   # flush last block

        if amplitude_cb:
            amplitude_cb(0.0)


# ---------------------------------------------------------------------------
# macOS system TTS fallback
# ---------------------------------------------------------------------------

class _SystemTTSBackend:
    """Uses macOS 'say' command — no install, instant availability.

    NOTE: this is a pragmatic macOS-only deviation from the design's
    XTTS-v2 / ElevenLabs fallback chain. Piper is preferred; `say`
    fires only when Piper voice files or the piper binary are missing.
    On Linux/Windows this backend will fail — those platforms should
    ensure the Piper voice files are installed.
    """

    # Samantha is the clearest built-in US English voice for a learner
    _VOICE = "Samantha"
    _RATE = 160  # words per minute (default ~175; slightly slower for a learner)

    def __init__(self, config: "Config") -> None:
        print(f"[TTS] Using macOS system voice ({self._VOICE}, {self._RATE} wpm)")

    def speak(self, text: str, stop: threading.Event | None = None) -> None:
        self.speak_streaming(text, amplitude_cb=None, stop=stop)

    def speak_streaming(
        self,
        text: str,
        amplitude_cb=None,
        stop: threading.Event | None = None,
    ) -> None:
        import math

        proc = subprocess.Popen(
            ["say", "-v", self._VOICE, "-r", str(self._RATE), text]
        )
        t = 0.0
        while proc.poll() is None:
            if stop and stop.is_set():
                proc.terminate()
                break
            if amplitude_cb:
                amplitude_cb(abs(math.sin(t * 8.0)) * 0.6)
            t += 0.05
            time.sleep(0.05)
        if amplitude_cb:
            amplitude_cb(0.0)


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
