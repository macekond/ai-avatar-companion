"""TTS pipeline stage: synthesises text and plays audio.

Interface:
    tts = TTSPipeline(config)
    tts.speak("Hello!")          # synthesise and play, blocks until done
    tts.speak("Hello!", stop)    # same but stops early if stop event is set

Backend selection is driven by the active profile's practice *language*:
    English ("en"):
        1. Piper (piper-tts) — offline, good quality, child-friendly pitch
        2. macOS 'say' (Samantha) — zero-dependency fallback
    Japanese ("ja"):
        1. Kokoro-82M (kokoro-onnx, Apache-2.0) — offline neural, misaki g2p
        2. macOS 'say' (Kyoko) — zero-dependency fallback (works with no deps)

Piper has no usable Japanese voice, which is why Japanese uses Kokoro. Every
neural backend downloads its model on first use and, if unavailable, degrades
to the OS voice for that language — so Japanese speech works on macOS even
before Kokoro is installed.
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
# Local cache for downloaded Piper voice files
_VOICE_CACHE = Path.home() / ".local" / "share" / "piper" / "voices"

# Kokoro (Japanese neural TTS) model files + cache. Files are GitHub release
# assets from the kokoro-onnx project; downloaded on first Japanese use.
_KOKORO_CACHE = Path.home() / ".local" / "share" / "kokoro"
_KOKORO_MODEL_FILE = "kokoro-v1.0.onnx"
_KOKORO_VOICES_FILE = "voices-v1.0.bin"
_KOKORO_RELEASE = (
    "https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0"
)
_KOKORO_SAMPLE_RATE = 24_000
_KOKORO_DEFAULT_VOICE = "jf_alpha"   # Japanese female, warm — good child default

# OS ('say') voice per language, used when the neural backend is unavailable.
_SYSTEM_VOICE_BY_LANG = {"en": "Samantha", "ja": "Kyoko"}


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
        self._language = getattr(config.child, "language", "en")
        # Intended voice name (what current_voice reports until a backend is
        # actually built). May be "" if the profile prefers the language default.
        self._voice_name = config.models.tts.voice
        # Backend construction is DEFERRED to first speak(). A fresh install
        # whose first profile is Japanese should never download the English
        # Piper voice the config seed defaults to. On connect, the server's
        # _configure_active() calls reload_voice() when the loaded profile's
        # language/voice differ from what we report, which builds the right
        # backend up-front for that profile; otherwise the first greeting
        # triggers the build.
        self._backend = None

    @property
    def current_voice(self) -> str:
        """Voice name currently in use (or '' for the system fallback).

        Reports the *intended* voice even before the backend has been built,
        so the server's connect-time reconfig can compare against it without
        forcing an eager load.
        """
        if self._backend is None:
            return self._voice_name
        return getattr(self._backend, "voice_name", "")

    @property
    def language(self) -> str:
        """Practice language the current (or pending) backend synthesises for."""
        return self._language

    def _ensure_backend(self):
        """Lazily construct the backend the first time we actually need to speak."""
        if self._backend is None:
            self._backend = _create_backend(
                self._config, self._language, voice_override=self._voice_name,
            )
        return self._backend

    def reload_voice(self, voice_name: str, language: str | None = None) -> bool:
        """Swap voice (and optionally language), downloading the model if needed.

        *language* selects the backend family (English → Piper, Japanese →
        Kokoro); when None the current language is kept. If the neural backend
        can't load, _create_backend degrades to the OS voice for that language
        rather than failing, so the session keeps talking.

        Unlike speak(), this is eager — the caller (typically the Settings panel
        or a profile swap) has explicitly asked for a specific voice, so the
        download/load happens now rather than at the next utterance.
        """
        lang = language or self._language
        try:
            new_backend = _create_backend(self._config, lang, voice_override=voice_name)
        except Exception as exc:
            print(f"[TTS] Could not load voice '{voice_name}' ({lang}): {exc}")
            return False
        self._backend = new_backend
        self._language = lang
        # Report whatever the backend actually loaded ("" for a SystemTTS
        # fallback), so current_voice tells the truth.
        self._voice_name = getattr(new_backend, "voice_name", "")
        return True

    def speak(self, text: str, stop: threading.Event | None = None) -> None:
        """Synthesise *text* and play it.

        Blocks until playback is complete (or *stop* is set).
        Empty / whitespace-only strings are silently skipped.
        """
        text = text.strip()
        if not text:
            return
        self._ensure_backend().speak(text, stop)

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
        self._ensure_backend().speak_streaming(text, amplitude_cb, stop)


# ---------------------------------------------------------------------------
# Backend selection
# ---------------------------------------------------------------------------

def _create_backend(config: "Config", language: str, voice_override: str | None = None):
    """Build the TTS backend for *language*, falling back to the OS voice.

    Japanese routes to Kokoro (Piper has no usable Japanese voice); everything
    else routes to Piper. Any load failure degrades to the macOS 'say' voice
    for that language, so speech never hard-fails on a missing model.
    """
    if language == "ja":
        try:
            return _KokoroBackend(config, voice_override=voice_override)
        except Exception as exc:
            print(f"\n[TTS] Kokoro unavailable ({exc}), using macOS Japanese voice.")
            return _SystemTTSBackend(config, language="ja")

    try:
        return _PiperBackend(config, voice_override=voice_override)
    except Exception as exc:
        print(f"\n[TTS] Piper unavailable ({exc}), using macOS system voice.")
        return _SystemTTSBackend(config, language=language)


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
        chunks: list[np.ndarray] = []
        for chunk in self._voice.synthesize(text, syn_config=self._syn_config):
            if stop and stop.is_set():
                return
            chunks.append(chunk.audio_int16_array)

        if not chunks:
            return

        # Normalise to float32 [-1, 1] for the output stream
        audio = np.concatenate(chunks).astype(np.float32) / 32768.0
        _play_float_audio(audio, self._sample_rate, amplitude_cb, stop)


# ---------------------------------------------------------------------------
# Shared playback
# ---------------------------------------------------------------------------

def _play_float_audio(
    audio: np.ndarray,
    sample_rate: int,
    amplitude_cb=None,
    stop: threading.Event | None = None,
) -> None:
    """Play a float32 [-1, 1] mono buffer, pulsing *amplitude_cb* at ~20 Hz.

    Shared by every neural backend (Piper, Kokoro) so lip-sync amplitude and
    stop/barge-in behaviour stay identical regardless of which engine produced
    the audio.
    """
    import sounddevice as sd

    if audio is None or len(audio) == 0:
        if amplitude_cb:
            amplitude_cb(0.0)
        return

    BLOCK = max(256, sample_rate // 20)   # ~50 ms → ~20 Hz amplitude
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
        samplerate=sample_rate,
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
# Kokoro backend (Japanese neural TTS)
# ---------------------------------------------------------------------------

class _KokoroBackend:
    """Kokoro-82M via kokoro-onnx (Apache-2.0), offline neural Japanese TTS.

    Japanese needs grapheme-to-phoneme via misaki[ja] (→ pyopenjtalk + unidic);
    the phonemes are handed to Kokoro with ``is_phonemes=True``. The ~330 MB
    model + voice pack download on first use, like the Piper voices. Any missing
    dependency or model raises, and _create_backend falls back to macOS 'say'.
    """

    def __init__(self, config: "Config", voice_override: str | None = None) -> None:
        from kokoro_onnx import Kokoro
        from misaki import ja

        voice_name = voice_override or _KOKORO_DEFAULT_VOICE
        model_path, voices_path = _ensure_kokoro_files()

        print(f"Loading Kokoro voice ({voice_name})…", end="", flush=True)
        self._kokoro = Kokoro(str(model_path), str(voices_path))
        self._g2p = ja.JAG2P()
        self.voice_name = voice_name
        self._sample_rate = _KOKORO_SAMPLE_RATE
        # Piper's length_scale slows a learner's speech; Kokoro's speed is the
        # inverse (speed < 1 = slower), so map through the reciprocal.
        length_scale = getattr(config.models.tts, "length_scale", 1.0) or 1.0
        self._speed = 1.0 / length_scale
        print(" ready.")

    def speak(self, text: str, stop: threading.Event | None = None) -> None:
        self.speak_streaming(text, amplitude_cb=None, stop=stop)

    def speak_streaming(
        self,
        text: str,
        amplitude_cb=None,
        stop: threading.Event | None = None,
    ) -> None:
        if stop and stop.is_set():
            return
        # misaki[ja]'s JAG2P callable returns a plain phonemes string in 0.9+;
        # older releases returned (phonemes, tokens). Handle both, otherwise the
        # unpack raises before Kokoro sees anything — which crashes speech and
        # silently falls back to macOS 'say', making every voice sound the same
        # (all four Kokoro chips end up voiced by Kyoko). Regression pin in
        # tests/test_pipeline_tts.py.
        result = self._g2p(text)
        phonemes = result if isinstance(result, str) else result[0]
        samples, sample_rate = self._kokoro.create(
            phonemes, voice=self.voice_name, speed=self._speed, is_phonemes=True,
        )
        if stop and stop.is_set():
            return
        _play_float_audio(np.asarray(samples, dtype=np.float32), sample_rate,
                          amplitude_cb, stop)


# ---------------------------------------------------------------------------
# macOS system TTS fallback
# ---------------------------------------------------------------------------

class _SystemTTSBackend:
    """Uses macOS 'say' command — no install, instant availability.

    NOTE: this is a pragmatic macOS-only deviation from the design's
    XTTS-v2 / ElevenLabs fallback chain. A neural backend (Piper for English,
    Kokoro for Japanese) is preferred; `say` fires only when that backend's
    model or dependencies are missing. The 'say' voice tracks the practice
    language (Samantha for English, Kyoko for Japanese) so Japanese profiles
    still speak Japanese with zero extra dependencies. On Linux/Windows this
    backend will fail — those platforms should install the neural backend.
    """

    _RATE = 160  # words per minute (default ~175; slightly slower for a learner)

    def __init__(self, config: "Config", language: str = "en") -> None:
        # '' voice_name signals "OS fallback, not a catalog voice" to the UI.
        self.voice_name = ""
        self._say_voice = _SYSTEM_VOICE_BY_LANG.get(language, "Samantha")
        print(f"[TTS] Using macOS system voice ({self._say_voice}, {self._RATE} wpm)")

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
            ["say", "-v", self._say_voice, "-r", str(self._RATE), text]
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

def voice_is_cached(voice_name: str) -> bool:
    """True if the voice model is already downloaded (no fetch needed)."""
    return (_VOICE_CACHE / f"{voice_name}.onnx").exists()


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


# ---------------------------------------------------------------------------
# Kokoro model downloader
# ---------------------------------------------------------------------------

def kokoro_is_cached() -> bool:
    """True if both Kokoro model files are already downloaded."""
    return ((_KOKORO_CACHE / _KOKORO_MODEL_FILE).exists()
            and (_KOKORO_CACHE / _KOKORO_VOICES_FILE).exists())


def _ensure_kokoro_files() -> tuple[Path, Path]:
    """Return (model_path, voices_path), downloading them on first use."""
    _KOKORO_CACHE.mkdir(parents=True, exist_ok=True)
    model_path = _KOKORO_CACHE / _KOKORO_MODEL_FILE
    voices_path = _KOKORO_CACHE / _KOKORO_VOICES_FILE
    if not model_path.exists():
        _download_kokoro_file(_KOKORO_MODEL_FILE, model_path)
    if not voices_path.exists():
        _download_kokoro_file(_KOKORO_VOICES_FILE, voices_path)
    return model_path, voices_path


def _download_kokoro_file(filename: str, dest: Path) -> None:
    import urllib.request

    url = f"{_KOKORO_RELEASE}/{filename}"
    print(f"\nDownloading Kokoro model file: {filename} (first Japanese use)…")
    # Download to a temp path then rename, so an interrupted download never
    # leaves a truncated file that looks "cached".
    tmp = dest.with_name(dest.name + ".part")
    urllib.request.urlretrieve(url, tmp)
    tmp.replace(dest)
    print(f"  → saved to {dest}")
