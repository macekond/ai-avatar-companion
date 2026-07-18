"""WebSocket server — Python sidecar for the Phase 3 browser UI.

Listens on ws://localhost:8765. Each browser connection gets its own
session: PTT recording → STT → LLM → TTS with amplitude streaming.

Memory layer (optional, controlled by config.memory.enabled):
  - On connect: load profile; send 'profiles' and 'init' messages.
  - First session (no profile file): onboarding flow (name + age).
  - Per turn: post-turn extraction updates topics/problems asynchronously.
  - Re-engagement: after N short responses, inject a hint into the LLM.
  - Profile switch: 'switch_profile' message reloads memory without reload.

Message protocol
----------------
Browser → server:
  {"type": "start"}                          # user tapped "Say hi to Nova!"
  {"type": "ptt_start"}
  {"type": "ptt_stop"}
  {"type": "stop_speak"}                     # barge-in while speaking/thinking
  {"type": "replay",         "text": "…"}    # re-speak a stored line
  {"type": "set_level",      "level": "B"}    # valid for the active language only
  {"type": "set_language",   "language": "ja"}  # resets level+voice to lang defaults
  {"type": "set_voice",      "voice": "en_US-kristin-medium"}
  {"type": "preview_voice",  "voice": "en_US-kristin-medium"}  # sample line, doesn't change active voice
  {"type": "switch_profile", "slug": "mia"}   # + optional "language"/"level" to CREATE
  {"type": "delete_profile", "slug": "mia"}
  {"type": "avatar_loaded", "key": "VIPEHero_2707"}   # avatar changed → refresh appearance

Language + level are per-profile (stored on ChildProfile): "en" uses CEFR levels
(Pre A/A/B/C1/C2) with Piper voices; "ja" uses JLPT (N5..N1) with Kokoro voices.
switch_profile to a NEW slug carrying "language"+"level" creates that profile from
the modal and skips spoken onboarding; without them the spoken onboarding runs.

For Japanese profiles, text-carrying messages (sentence, transcript,
conversation_turn, conversation_correction) also carry a sibling `<field>_html`
with furigana-annotated HTML (<ruby>漢字<rt>かんじ</rt></ruby>), e.g. `text_html`,
`you_html`, `nova_html`, `wrong_html`, `right_html`. The UI renders the html
variant when present, else falls back to the plain field.

Server → browser:
  {"type": "init",          "level": "A", "language": "en"}
  {"type": "settings", "language": "en", "languages": ["en","ja"],
                       "levels": ["Pre A","A","B","C1","C2"], "level": "A",
                       "voices": [{"id","label"}, …], "voice": "en_US-kristin-medium"}
  {"type": "voice_status",   "state": "downloading|loading|ready|error", "voice": …}  # set_voice progress
  {"type": "preview_status", "state": "downloading|loading|ready|error", "voice": …}  # preview_voice progress
  {"type": "profiles",      "list": ["lily","mia"], "active": "lily"}
  {"type": "profile_error", "message": "Can't remove the only child."}
  {"type": "onboarding_start"}
  {"type": "memory_loaded",  "name": "Lily", "age": 8, "language": "en", "level": "A"}
  {"type": "state",         "state": "awaiting_start|idle|listening|thinking|speaking|didnt_catch"}
  {"type": "transcript",    "text": "…"}
  {"type": "sentence",      "text": "…"}
  {"type": "amplitude",     "value": 0–1}
  {"type": "conversation_reset"}                     # clear panel before replay
  {"type": "conversation_turn",       "id": 1, "you": "…", "nova": "…"}
  {"type": "conversation_correction", "id": 1, "kind": "past_tense",
                                      "wrong": "goed", "right": "went"}

On connect (and on profile switch) the server replays the active child's saved
transcript: a 'conversation_reset' followed by the stored 'conversation_turn' /
'conversation_correction' messages, so history survives a relaunch.

Run:
    python -m app.server
    python -m app.server --profile mia
"""
from __future__ import annotations

import asyncio
import json
import logging
import re
import sys
import threading
from pathlib import Path
from typing import Any, Optional

import numpy as np
import websockets
from dotenv import load_dotenv

load_dotenv()

from app.appearance import AppearanceStore, DEFAULT_AVATAR_KEY
from app.config import Config, default_config_path
from app.greetings import system_text, age_suffix
from app.memory import ChildMemory, ChildProfile, MemoryManager, name_to_slug
from app.setup import check_ollama
from app.logging_setup import configure_logging, logfmt_str
from app.transcript import TranscriptStore

# Curated voice list for the Settings panel, keyed by practice language.
# English voices are Piper (permissive licenses only — the previous default
# en_US-lessac was Blizzard-licensed/research-only and is excluded). Japanese
# voices are Kokoro (Apache-2.0). Voices are language-specific, so the picker
# and set_voice validation are both scoped to the active profile's language.
AVAILABLE_VOICES = {
    "en": [
        {"id": "en_US-kristin-medium", "label": "Kristin — bright, younger (US)"},
        {"id": "en_US-ljspeech-medium", "label": "LJ — calm, clear (US)"},
        {"id": "en_US-joe-medium",      "label": "Joe — friendly male (US)"},
        {"id": "en_US-norman-medium",   "label": "Norman — deeper male (US)"},
    ],
    "ja": [
        {"id": "jf_alpha",      "label": "Alpha — warm female (JP)"},
        {"id": "jf_gongitsune", "label": "Gongitsune — gentle female (JP)"},
        {"id": "jf_nezumi",     "label": "Nezumi — bright female (JP)"},
        {"id": "jm_kumo",       "label": "Kumo — friendly male (JP)"},
    ],
}
_VOICE_IDS = {lang: {v["id"] for v in vs} for lang, vs in AVAILABLE_VOICES.items()}


def _voices_for(language: str) -> list[dict]:
    """Voice catalog for *language* (English list if language is unknown)."""
    return AVAILABLE_VOICES.get(language, AVAILABLE_VOICES["en"])


def _is_valid_voice(language: str, voice_id: str) -> bool:
    return voice_id in _VOICE_IDS.get(language, set())


def _language_of_voice(voice_id: str) -> str:
    """Practice language a catalog voice id belongs to, or "" if unknown.

    Used by preview_voice, which (unlike set_voice) previews a voice outside
    the active language, so validation can't rely on active_language alone.
    """
    for lang, ids in _VOICE_IDS.items():
        if voice_id in ids:
            return lang
    return ""


def _default_voice_for(language: str, config: "Config") -> str:
    """Default voice id for *language*: config's voice for English, else the
    first catalog entry (Kokoro default for Japanese)."""
    if language == "en":
        return config.models.tts.voice
    vs = AVAILABLE_VOICES.get(language, [])
    return vs[0]["id"] if vs else ""


def _voice_download_pending(language: str, voice_id: str) -> bool:
    """True if selecting this voice will trigger a first-use model download."""
    if language == "ja":
        return not kokoro_is_cached()
    return not voice_is_cached(voice_id)
from app.memory_extractor import MemoryExtractor
from app.pipeline.llm import LLMPipeline
from app.pipeline.stt import STTPipeline, SAMPLE_RATE, whisper_is_cached
from app.pipeline.tts import TTSPipeline, voice_is_cached, kokoro_is_cached
from app.levels import LANGUAGES, levels_for, default_level_for
from app.furigana import annotate_for
from app.telemetry import TelemetrySession

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("nova.server")

HOST = "localhost"
PORT = 8765

# Origin allow-list for the WebSocket server. Browsers permit cross-origin
# WebSocket connections to localhost, so any webpage the user has open could
# otherwise activate the microphone and read transcripts. Only the UI's dev
# and preview origins are allowed. `None` (no Origin header) is allowed
# because it identifies non-browser clients — local processes that could
# forge any header anyway; the Origin check only defends the browser threat
# model. The string "null" is deliberately NOT allowed: sandboxed iframes on
# arbitrary websites send `Origin: null`, so allowing it would reopen the
# cross-origin hole.
ALLOWED_ORIGINS = [
    "http://localhost:5173",   # Vite dev
    "http://127.0.0.1:5173",
    "http://localhost:4173",   # Vite preview
    "http://127.0.0.1:4173",
    "tauri://localhost",       # Tauri v2 webview (macOS/Linux WKWebView)
    "http://tauri.localhost",  # Tauri v2 webview (Windows WebView2)
    None,                      # non-browser clients (no Origin header)
]

_REENGAGEMENT_HINT = (
    "The child seems quiet. Based on the memory context in the system prompt, "
    "introduce a fresh topic from their interests or suggest a quick, fun activity "
    "to practise their known language challenge."
)


# ---------------------------------------------------------------------------
# Server-side recording
# ---------------------------------------------------------------------------

# How long to wait for the recording thread after PTT release before giving
# up. Opening the input stream can block indefinitely when microphone
# permission is missing (macOS TCC) — the session must not hang with it.
RECORD_GRACE_S = 10.0

# How long teardown/profile-swap waits for in-flight extraction tasks before
# abandoning them. Abandoning does not stop the underlying thread, so anything
# that must not race a late task cannot rely on this alone — see
# MemoryManager's deleted-slug tombstone.
DRAIN_TIMEOUT_S = 5.0


class _MicRecorder:
    """Session-scoped microphone capture over a single persistent input stream.

    Opening and closing a CoreAudio input stream on *every* PTT turn eventually
    wedges the device on macOS — the stream opens but its callback stops
    delivering frames — so the server went permanently deaf a few minutes into
    a session (field-observed: ~10 good turns, then every turn "didn't catch").
    The CLI never hit this because `STTPipeline.record` keeps one stream open
    and gates capture with a flag; this mirrors that.

    Lifecycle per turn: `start()` clears the buffer and begins capturing (the
    stream is opened lazily on the first call and reused thereafter); `stop()`
    stops capturing and returns the audio. `close()` tears the stream down at
    the end of the session. All three are safe to call from a worker thread.
    """

    def __init__(self) -> None:
        self._chunks: list[np.ndarray] = []
        self._capturing = threading.Event()
        self._lock = threading.Lock()
        self._stream = None
        self._failed = False

    def _ensure_stream(self) -> None:
        if self._stream is not None or self._failed:
            return
        import sounddevice as sd

        def _cb(indata: np.ndarray, frames: int, _time, _status) -> None:
            # Runs on PortAudio's thread for the whole session; only keep frames
            # while a turn is actually capturing.
            if self._capturing.is_set():
                with self._lock:
                    self._chunks.append(indata.copy())

        stream = None
        try:
            stream = sd.InputStream(samplerate=SAMPLE_RATE, channels=1,
                                    dtype="float32", callback=_cb)
            stream.start()
            self._stream = stream
        except Exception as exc:
            # Missing mic permission (macOS TCC) surfaces here. Mark failed so
            # every turn flows into the didn't-catch path instead of retrying a
            # blocking open each time. Close a stream that constructed but
            # failed to start, so it isn't leaked.
            log.error("Microphone unavailable (permission denied?): %s", exc)
            self._failed = True
            if stream is not None:
                try:
                    stream.close()
                except Exception:
                    pass

    def start(self) -> None:
        with self._lock:
            self._chunks = []
        self._capturing.set()
        self._ensure_stream()

    def stop(self) -> np.ndarray:
        """Stop capturing and return the recorded audio (empty on any failure)."""
        self._capturing.clear()
        with self._lock:
            chunks, self._chunks = self._chunks, []
        if not chunks:
            # Distinguish a wedged/blank device (stream open, callback delivered
            # nothing) from an unavailable one (open failed / never opened), so a
            # field log tells a device wedge from a permission problem.
            cause = ("stream_unavailable"
                     if (self._failed or self._stream is None) else "no_frames")
            log.warning("capture_empty cause=%s", cause)
            return np.zeros(0, dtype=np.float32)
        return np.concatenate(chunks, axis=0).squeeze()

    def close(self) -> None:
        self._capturing.clear()
        stream, self._stream = self._stream, None
        if stream is not None:
            try:
                stream.stop()
                stream.close()
            except Exception:
                pass


# ---------------------------------------------------------------------------
# Name / age extraction (onboarding)
# ---------------------------------------------------------------------------

_FILLER = {"my", "name", "is", "i'm", "i", "am", "it", "a", "the",
           "just", "hi", "hello", "hey", "its", "im"}
_WORD_NUMS = {
    "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
    "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
    "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14,
    "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18,
}


def _extract_name(text: str) -> Optional[str]:
    for word in text.lower().split():
        w = re.sub(r"[^a-z]", "", word)
        if w and w not in _FILLER and w.isalpha() and len(w) >= 2:
            return w.capitalize()
    return None


def _extract_age(text: str) -> Optional[int]:
    for word in text.split():
        w = re.sub(r"[^0-9]", "", word)
        if w.isdigit() and 1 <= int(w) <= 18:
            return int(w)
    for word in text.lower().split():
        w = re.sub(r"[^a-z]", "", word)
        if w in _WORD_NUMS:
            return _WORD_NUMS[w]
    return None


# ---------------------------------------------------------------------------
# One PTT turn helper
# ---------------------------------------------------------------------------

async def _await_ptt(next_raw, stash, wanted: str, timeout: float = 60.0) -> bool:
    """Read until a ``wanted`` PTT message arrives; True if it did.

    Anything else (avatar_loaded, set_level, …) is handed to ``stash`` for the
    main loop to process later, never consumed as if it were the PTT message.
    Swallowing one would shift every later read by one: the child's ptt_start
    would be taken for the ptt_stop ending a recording that never captured
    their answer. ``stash`` must not feed back into ``next_raw`` before this
    returns, or the same message would be read and re-stashed forever.
    """
    while True:
        try:
            raw = await asyncio.wait_for(next_raw(), timeout=timeout)
        except asyncio.TimeoutError:
            return False
        try:
            mtype = json.loads(raw).get("type")
        except (json.JSONDecodeError, TypeError, AttributeError):
            continue        # malformed frame — drop it, keep waiting
        if mtype == wanted:
            return True
        stash(raw)


async def _one_ptt_turn(
    next_raw,
    stash,
    stt: STTPipeline,
    recorder: "_MicRecorder",
    send,
) -> str:
    """Wait for Space-release, record, and return the transcript (may be empty)."""
    await send({"type": "state", "state": "listening"})
    try:
        await asyncio.wait_for(asyncio.to_thread(recorder.start), RECORD_GRACE_S)
    except Exception:
        # First-turn stream open can block without mic permission; don't hang.
        log.error("Recording did not start — treating as no audio")
    if not await _await_ptt(next_raw, stash, "ptt_stop"):
        await asyncio.to_thread(recorder.stop)
        await send({"type": "state", "state": "idle"})
        return ""
    audio = await asyncio.to_thread(recorder.stop)
    await send({"type": "state", "state": "thinking"})
    return await asyncio.to_thread(stt.transcribe, audio)


# ---------------------------------------------------------------------------
# Onboarding
# ---------------------------------------------------------------------------

async def _run_onboarding(
    next_raw,
    stash,
    config: Config,
    stt: STTPipeline,
    tts: TTSPipeline,
    mem_mgr: MemoryManager,
    recorder: "_MicRecorder",
    send,
    send_from_thread,
) -> ChildMemory:
    """Two-turn onboarding: learn the child's name and age.

    Reads through ``next_raw`` (the same buffer the main loop drains) rather
    than the socket directly, so messages the UI sends on connect — notably
    'avatar_loaded' from ws.onopen, which lands before the first question is
    even asked — are stashed for the main loop instead of being mistaken for
    the child's Space-press.
    """
    avatar = config.personality.avatar_name

    def amp(v: float) -> None:
        send_from_thread({"type": "amplitude", "value": round(v, 3)})

    # --- Ask for name ---
    q1 = system_text("onboarding_ask_name", config.child.language, avatar=avatar)
    await send({"type": "state", "state": "speaking"})
    await send({"type": "sentence", "text": q1})
    await asyncio.to_thread(tts.speak_streaming, q1, amp)
    await send({"type": "amplitude", "value": 0.0})
    await send({"type": "state", "state": "idle"})

    # wait for Space-press, then record
    await _await_ptt(next_raw, stash, "ptt_start")
    name_transcript = await _one_ptt_turn(next_raw, stash, stt, recorder, send)
    name = _extract_name(name_transcript) if name_transcript else None
    if not name:
        name = "Friend"

    # --- Ask for age ---
    q2 = system_text("onboarding_ask_age", config.child.language, name=name)
    await send({"type": "state", "state": "speaking"})
    await send({"type": "sentence", "text": q2})
    await asyncio.to_thread(tts.speak_streaming, q2, amp)
    await send({"type": "amplitude", "value": 0.0})
    await send({"type": "state", "state": "idle"})

    await _await_ptt(next_raw, stash, "ptt_start")
    age_transcript = await _one_ptt_turn(next_raw, stash, stt, recorder, send)
    age = _extract_age(age_transcript) if age_transcript else None

    memory = ChildMemory(profile=ChildProfile(name=name, age=age))
    mem_mgr.save(memory)
    log.info("Onboarding complete: name=%s age=%s", name, age)
    return memory


# ---------------------------------------------------------------------------
# Greeting helper
# ---------------------------------------------------------------------------

async def _send_greeting(
    config: Config,
    memory: Optional[ChildMemory],
    tts: TTSPipeline,
    send,
    send_from_thread,
    language: str,
) -> None:
    avatar = config.personality.avatar_name

    if memory:
        name = memory.profile.name
        age_note = age_suffix(memory.profile.age, language)
        if memory.topics:
            recent_topic = sorted(
                memory.topics, key=lambda t: t.last_mentioned, reverse=True
            )[0].keyword
            text = system_text("greeting_returning_topic", language,
                                name=name, age_suffix=age_note, topic=recent_topic)
        else:
            text = system_text("greeting_returning", language,
                                name=name, age_suffix=age_note)
    else:
        name = config.child.name
        text = system_text("greeting_new", language, name=name, avatar=avatar)

    def amp(v: float) -> None:
        send_from_thread({"type": "amplitude", "value": round(v, 3)})

    await send({"type": "state", "state": "speaking"})
    await send({"type": "sentence", "text": text})
    await asyncio.to_thread(tts.speak_streaming, text, amp)
    await send({"type": "amplitude", "value": 0.0})
    await send({"type": "state", "state": "idle"})


# ---------------------------------------------------------------------------
# Session handler
# ---------------------------------------------------------------------------

async def _session(
    ws,
    config: Config,
    stt: STTPipeline,
    llm: LLMPipeline,
    tts: TTSPipeline,
    mem_mgr: Optional[MemoryManager] = None,
    telemetry: Optional[TelemetrySession] = None,
) -> None:
    loop = asyncio.get_running_loop()

    async def send(data: dict[str, Any]) -> None:
        try:
            await ws.send(json.dumps(data))
        except Exception:
            pass

    def send_from_thread(data: dict[str, Any]) -> None:
        asyncio.run_coroutine_threadsafe(send(data), loop)

    def amplitude_cb(value: float) -> None:
        send_from_thread({"type": "amplitude", "value": round(value, 3)})

    import time as _time
    extractor = MemoryExtractor(config.models.llm.model) if mem_mgr else None

    # Fire-and-forget extraction tasks, awaited on teardown so the last
    # turn's telemetry (written inside them) isn't lost and the final
    # memory save doesn't race a still-running background save.
    pending_tasks: list[asyncio.Task] = []

    async def _drain_pending(timeout: float | None = None) -> None:
        still_running = [t for t in pending_tasks if not t.done()]
        if still_running:
            await asyncio.wait(
                still_running,
                timeout=DRAIN_TIMEOUT_S if timeout is None else timeout,
            )
        pending_tasks.clear()

    def _apply_extracted_memory(mem_ref: ChildMemory) -> None:
        """Refresh the LLM with freshly extracted memory — but only if that
        child is still active. An extraction task schedules this via
        call_soon_threadsafe; if a profile swap happened in the meantime, the
        callback can land *after* the swap already loaded the new child's
        memory, so re-applying the old ref would leak one child's context into
        another. Gating on identity makes the stale callback a no-op."""
        if mem_ref is memory:
            llm.set_memory(mem_ref)

    # Messages consumed by a phase they don't belong to — the barge-in watcher,
    # the listening phase, or onboarding — are buffered here and drained before
    # the next real read from the socket. Declared before onboarding because it
    # reads through this buffer too.
    buffered_msgs: list[str] = []

    async def _next_raw() -> str:
        if buffered_msgs:
            return buffered_msgs.pop(0)
        # ws.recv(), not async-for/__anext__: the real websockets
        # ServerConnection has no __anext__ (only __aiter__), so iteration
        # helpers must go through recv(). Raises ConnectionClosed on close.
        return await ws.recv()

    async def _onboard(mgr: MemoryManager) -> ChildMemory:
        """Run onboarding, re-queueing anything it set aside for the main loop.

        The stash is local, not buffered_msgs itself: _next_raw pops from
        buffered_msgs, so stashing there mid-onboarding would re-serve the same
        message to the reader that just set it aside — an infinite loop.
        """
        stashed: list[str] = []
        result = await _run_onboarding(
            _next_raw, stashed.append, config, stt, tts, mgr, recorder,
            send, send_from_thread,
        )
        buffered_msgs.extend(stashed)
        return result

    # One microphone stream for the whole session (see _MicRecorder): opening a
    # fresh CoreAudio stream per turn wedges the device after a few minutes.
    recorder = _MicRecorder()

    # Active practice language / level / voice for THIS session. Seeded from
    # config, then set from the loaded profile (or a profile swap). STT reads
    # active_language per turn; the LLM prompt and TTS backend are rebuilt via
    # _configure_active(). Telemetry and the Settings panel reflect what the
    # child is actually practising.
    active_language = getattr(config.child, "language", "en")
    active_level = config.child.level
    active_voice = config.models.tts.voice

    def _sync_active_state(mem: Optional[ChildMemory]) -> None:
        """Point LLM at *mem*'s profile language/level (fast, synchronous).

        A level is only valid inside its language's taxonomy, so both move
        together. This updates active_language/active_level/active_voice and
        the LLM prompt immediately, so callers can ship settings/memory_loaded
        messages without waiting on a TTS reload.
        """
        nonlocal active_language, active_level, active_voice
        prof = mem.profile if mem is not None else None
        if prof is not None:
            active_language = getattr(prof, "language", "") or config.child.language
            active_level = getattr(prof, "level", "") or default_level_for(active_language)
            active_voice = getattr(prof, "voice", "") or _default_voice_for(active_language, config)
        llm.set_language_level(active_language, active_level)

    async def _reload_tts_if_changed() -> None:
        """Reload the TTS voice off the event loop, only if it actually changed.

        TTS reload can load or download a model (~100-500ms), so this is kept
        separate from _sync_active_state and awaited only where the delay is
        acceptable (initial connect, after a swap's fast state update already
        shipped).
        """
        if (active_voice, active_language) != (tts.current_voice, tts.language):
            await asyncio.to_thread(tts.reload_voice, active_voice, active_language)

    async def _configure_active(mem: Optional[ChildMemory]) -> None:
        """Point LLM + TTS at *mem*'s profile language/level/voice (slow path).

        Retained for call sites that need the old synchronous-looking combo of
        state update + TTS reload in one step.
        """
        _sync_active_state(mem)
        await _reload_tts_if_changed()

    async def _send_settings() -> None:
        """Send the Settings-panel state for the ACTIVE profile's language."""
        await send({
            "type": "settings",
            "language": active_language,
            "languages": LANGUAGES,
            "levels": levels_for(active_language),
            "level": active_level,
            "voices": _voices_for(active_language),
            "voice": active_voice,
        })

    def _with_furigana(msg: dict, *fields: str) -> dict:
        """For Japanese profiles, annotate the given text *fields* on *msg*
        with a ``<field>_html`` sibling carrying furigana-tagged HTML.

        The UI checks the ``_html`` variant first and falls back to the plain
        field when absent, so English profiles pass through unchanged. TTS
        always reads the plain text — <ruby> markup is display-only.
        """
        if active_language != "ja":
            return msg
        for f in fields:
            text = msg.get(f)
            if isinstance(text, str) and text:
                html = annotate_for(text, active_language)
                if html:
                    msg[f + "_html"] = html
        return msg

    # The LLM pipeline is shared across WebSocket connections, so start each
    # session with a clean history — otherwise a fresh tab (or a second child
    # after a hot-swap) inherits whatever conversation was in progress.
    llm.clear_history()

    # Appearance: the avatar can answer "what do you look like?" from a curated
    # (or cached auto-derived) description. Set the default avatar now; the UI's
    # 'avatar_loaded' message refreshes it if a different avatar is shown.
    appearance_store = AppearanceStore(
        Path(config.memory.profiles_dir).expanduser().parent / "avatars"
    )

    def _apply_appearance(key: str) -> None:
        found = appearance_store.get(key)
        llm.set_appearance(found.description if found else None)

    _apply_appearance(DEFAULT_AVATAR_KEY)

    # Persistent per-child conversation history (survives relaunch). Lives in a
    # sibling dir of profiles/, like avatars/. Display-only — never fed back
    # into the prompt.
    transcripts_dir = (
        Path(config.memory.profiles_dir).expanduser().parent / "transcripts"
    )
    transcript_store: Optional[TranscriptStore] = None
    conv_turn_n = 0        # id for transcript entries (child↔Nova exchanges)
    consecutive_short = 0

    async def _load_transcript(slug: str) -> None:
        """Repoint history at ``slug``, clear the UI panel, and replay stored turns.

        Sending conversation_reset first means a reconnect or a profile switch
        rebuilds the panel from disk instead of appending on top of what's
        already shown. conv_turn_n continues past the last stored id so a live
        turn never collides with a replayed one.
        """
        nonlocal transcript_store, conv_turn_n
        await send({"type": "conversation_reset"})
        transcript_store = TranscriptStore(transcripts_dir, slug) if mem_mgr else None
        if transcript_store is None:
            conv_turn_n = 0
            return
        for t in transcript_store.load():
            await send(_with_furigana(
                {"type": "conversation_turn", "id": t["id"],
                 "you": t["you"], "nova": t["nova"]},
                "you", "nova",
            ))
            for c in t["corrections"]:
                await send(_with_furigana(
                    {"type": "conversation_correction", "id": t["id"],
                     "kind": c["kind"], "wrong": c["wrong"], "right": c["right"]},
                    "wrong", "right",
                ))
        conv_turn_n = transcript_store.last_id()

    # ── Load / initialise memory ─────────────────────────────────────────
    memory: Optional[ChildMemory] = mem_mgr.load() if mem_mgr else None

    # Point the pipeline at the loaded profile's language/level/voice before
    # announcing state, so init/settings/telemetry reflect the real profile.
    # Awaiting the TTS reload here is fine — the user isn't looking at the UI
    # yet, so there's no perceived delay to avoid (unlike a profile swap).
    _sync_active_state(memory)
    await _reload_tts_if_changed()

    # ── On-connect messages ──────────────────────────────────────────────
    log.info("Client connected")
    await send({"type": "init", "level": active_level, "language": active_language})

    # Settings panel state: language, levels + voices for that language, current
    # selections.
    await _send_settings()

    if mem_mgr:
        await send({
            "type": "profiles",
            "list": mem_mgr.list_profiles(),
            "active": mem_mgr.slug,
        })

    # ── Start telemetry session ──────────────────────────────────────
    is_onboarding = mem_mgr is not None and memory is None
    if telemetry:
        telemetry.start(level=active_level, is_onboarding=is_onboarding)

    # ── Onboarding or memory-loaded ──────────────────────────────────────
    if mem_mgr and memory is None:
        await send({"type": "onboarding_start"})
        memory = await _onboard(mem_mgr)
        await _configure_active(memory)
        await _send_settings()
        llm.set_memory(memory)
    elif memory is not None:
        llm.set_memory(memory)
        await send({"type": "memory_loaded",
                    "name": memory.profile.name,
                    "age": memory.profile.age,
                    "language": memory.profile.language,
                    "level": memory.profile.level})
    else:
        llm.set_memory(None)

    # Replay this profile's saved conversation into the transcript panel.
    if mem_mgr:
        await _load_transcript(mem_mgr.slug)

    # ── Wait for the user to initiate ─────────────────────────────────────
    # Don't fire the greeting on connect — the app used to start speaking the
    # moment the browser attached, which is startling. Instead, park in an
    # awaiting_start state until the user either taps the on-screen prompt
    # ({type:"start"}) or holds Space to talk. A profile swap within this
    # session parks back in awaiting_start the same way, so switching kids
    # never talks at the parent unprompted.
    has_greeted = False
    await send({"type": "state", "state": "awaiting_start"})

    # ── Main loop ────────────────────────────────────────────────────────
    async def _swap_profile(
        new_slug: str,
        save_current: bool = True,
        create_language: Optional[str] = None,
        create_level: Optional[str] = None,
        create_name: Optional[str] = None,
    ) -> None:
        """Hot-swap the active child profile to ``new_slug``.

        Drains in-flight extraction tasks first (a slow task from the previous
        child would otherwise call llm.set_memory with the old memory *after*
        the swap, leaking one child's context into another's). Then syncs the
        fast LLM state (prompt language/level) via _sync_active_state() and
        ships settings/memory_loaded/profiles messages immediately — the slower
        TTS reload (_reload_tts_if_changed()) only happens after, so the UI
        never sits on "Loading..." waiting for a voice model swap. The session
        parks back in awaiting_start rather than auto-greeting, consistent
        with the initial connect.

        When the target profile has no file yet:
          - if *create_language* is given (parent chose name+language+level in
            the Settings modal), the profile is created directly from those and
            the spoken name/age onboarding is skipped;
          - otherwise the spoken onboarding runs (first-run / legacy path).

        ``save_current=False`` skips persisting the outgoing memory — used when
        the outgoing profile was just deleted and must not be resurrected.
        """
        nonlocal mem_mgr, memory, consecutive_short, has_greeted
        await _drain_pending()
        if save_current and memory is not None:
            mem_mgr.prune(memory)
            mem_mgr.save(memory)
        mem_mgr = MemoryManager(
            config.memory.profiles_dir, new_slug,
            max_topics=config.memory.max_topics,
            max_problems=config.memory.max_problems,
            topic_ttl_days=config.memory.topic_ttl_days,
            problem_ttl_days=config.memory.problem_ttl_days,
        )
        memory = mem_mgr.load()
        llm.set_memory(memory)      # may be None; clears the previous child
        llm.clear_history()
        consecutive_short = 0
        if memory is None and create_language:
            # Parent-created via the modal: build the profile from the chosen
            # name/language/level and skip spoken onboarding.
            lang = create_language if create_language in LANGUAGES else config.child.language
            lvl = create_level if create_level in levels_for(lang) else default_level_for(lang)
            memory = ChildMemory(profile=ChildProfile(
                name=(create_name or new_slug).strip() or new_slug,
                language=lang, level=lvl,
            ))
            mem_mgr.save(memory)
            llm.set_memory(memory)
            _sync_active_state(memory)
            await _send_settings()
            await send({"type": "memory_loaded",
                        "name": memory.profile.name, "age": memory.profile.age,
                        "language": memory.profile.language,
                        "level": memory.profile.level})
        elif memory is None:
            # First-run / legacy spoken onboarding.
            _sync_active_state(None)
            await send({"type": "onboarding_start"})
            memory = await _onboard(mem_mgr)
            llm.set_memory(memory)
            _sync_active_state(memory)
            await _send_settings()
        else:
            _sync_active_state(memory)
            await _send_settings()
            await send({"type": "memory_loaded",
                        "name": memory.profile.name, "age": memory.profile.age,
                        "language": memory.profile.language,
                        "level": memory.profile.level})
        # Send the profiles list AFTER any save/onboarding: on the create/onboard
        # paths the new file didn't exist yet at the top of the function, so a
        # profiles broadcast up there would ship a stale list and the UI would
        # never render the new kid's chip (regression pin in test_server_settings).
        await send({"type": "profiles",
                    "list": mem_mgr.list_profiles(),
                    "active": new_slug})
        await _load_transcript(new_slug)
        await _reload_tts_if_changed()
        has_greeted = False
        await send({"type": "state", "state": "awaiting_start"})

    async def _run_speaking(speech_fn) -> None:
        """Run speech_fn(stop_event) in a worker thread while watching the socket
        for a `stop_speak` barge-in. Shared by the live reply and replay so both
        interrupt identically. Non-stop_speak messages are buffered for the main
        loop; a drained MockWebSocket (TimeoutError) simply ends the watcher.
        """
        stop_speaking = threading.Event()

        async def _watch_for_stop() -> None:
            while True:
                try:
                    raw3 = await ws.recv()
                except (asyncio.TimeoutError, websockets.ConnectionClosed,
                        StopAsyncIteration):
                    return
                try:
                    m = json.loads(raw3)
                except (ValueError, TypeError):
                    continue
                if m.get("type") == "stop_speak":
                    stop_speaking.set()
                    return
                buffered_msgs.append(raw3)

        pipeline_task = asyncio.create_task(asyncio.to_thread(speech_fn, stop_speaking))
        watcher_task = asyncio.create_task(_watch_for_stop())
        done, _ = await asyncio.wait(
            {pipeline_task, watcher_task}, return_when=asyncio.FIRST_COMPLETED)
        if watcher_task not in done:
            watcher_task.cancel()
            try:
                await watcher_task
            except asyncio.CancelledError:
                pass
        if pipeline_task not in done:
            await pipeline_task

    async def _speak_interruptible(text: str) -> None:
        """Re-speak `text` (a replay) with the same barge-in as a live reply.

        Pure playback: no transcript entry, no memory extraction, no telemetry.
        """
        await send({"type": "state", "state": "speaking"})
        await send(_with_furigana({"type": "sentence", "text": text}, "text"))

        def _speak(stop_speaking) -> None:
            tts.speak_streaming(text, amplitude_cb, stop_speaking)

        await _run_speaking(_speak)
        await send({"type": "amplitude", "value": 0.0})
        await send({"type": "state", "state": "idle"})

    try:
        while True:
            try:
                raw = await _next_raw()
            except websockets.ConnectionClosed as exc:
                # Log the close code/reason: 1001 "going away" is a page
                # reload/navigation, 1006 an abnormal drop. This one line is
                # what a field disconnect report needs.
                log.info("client_disconnect code=%s reason=%s",
                         exc.code, logfmt_str(exc.reason))
                break
            except (StopAsyncIteration, asyncio.TimeoutError):
                # TimeoutError: test mocks signal queue exhaustion this way.
                break
            msg = json.loads(raw)
            mtype = msg.get("type")

            # ── User-initiated first greeting ───────────────────────────
            # The child (or a parent tapping for them) has signalled they're
            # ready to hear from Nova. Fire the greeting once per session.
            if mtype == "start" and not has_greeted:
                has_greeted = True
                await send({"type": "state", "state": "idle"})
                await _send_greeting(config, memory, tts, send, send_from_thread, active_language)
                continue

            # ── Level change ─────────────────────────────────────────────
            if mtype == "set_level":
                new_level = msg.get("level", "")
                # Reject a level outside the active language's taxonomy (e.g. a
                # CEFR level for a Japanese profile) — it would blank the prompt.
                if new_level not in levels_for(active_language):
                    continue
                llm.set_level(new_level)
                active_level = new_level
                # Level lives on the profile now, not global settings.
                if memory is not None:
                    memory.profile.level = new_level
                    mem_mgr.save(memory)
                log.info("Level changed to: %s", new_level)
                continue

            # ── Language change ──────────────────────────────────────────
            if mtype == "set_language":
                new_lang = msg.get("language", "")
                if new_lang not in LANGUAGES:
                    continue
                # A level is only valid within its language, so switching
                # language resets level + voice to that language's defaults.
                active_language = new_lang
                active_level = default_level_for(new_lang)
                active_voice = _default_voice_for(new_lang, config)
                llm.set_language_level(active_language, active_level)
                if memory is not None:
                    memory.profile.language = active_language
                    memory.profile.level = active_level
                    memory.profile.voice = ""   # fall back to language default
                    mem_mgr.save(memory)
                # Switching backends (Piper↔Kokoro) may download a model.
                await send({
                    "type": "voice_status",
                    "state": ("downloading"
                              if _voice_download_pending(active_language, active_voice)
                              else "loading"),
                    "voice": active_voice,
                })
                ok = await asyncio.to_thread(tts.reload_voice, active_voice, active_language)
                await send({"type": "voice_status",
                            "state": "ready" if ok else "error",
                            "voice": tts.current_voice or active_voice})
                await _send_settings()
                log.info("Language changed to: %s (level %s)", active_language, active_level)
                continue

            # ── Avatar changed: refresh appearance description ───────────
            if mtype == "avatar_loaded":
                _apply_appearance(msg.get("key", ""))
                continue

            # ── Replay: re-speak a stored line (no new turn, no memory) ───
            if mtype == "replay":
                text = msg.get("text", "")
                if isinstance(text, str) and text.strip():
                    await _speak_interruptible(text.strip())
                continue

            # ── Voice change ─────────────────────────────────────────────
            if mtype == "set_voice":
                new_voice = msg.get("voice", "")
                # Validate against the ACTIVE language's catalog only.
                if not _is_valid_voice(active_language, new_voice):
                    continue
                # First use pulls the model (Piper voice ~60 MB, or the Kokoro
                # model) — tell the UI it's downloading, not just loading.
                downloading = _voice_download_pending(active_language, new_voice)
                await send({
                    "type": "voice_status",
                    "state": "downloading" if downloading else "loading",
                    "voice": new_voice,
                })
                # Reloading loads (and may download) the model — off the loop.
                ok = await asyncio.to_thread(tts.reload_voice, new_voice, active_language)
                if ok:
                    active_voice = new_voice
                    if active_language == "en":
                        config.models.tts.voice = new_voice
                    # Voice lives on the profile now (voices are language-scoped).
                    if memory is not None:
                        memory.profile.voice = new_voice
                        mem_mgr.save(memory)
                    log.info("Voice changed to: %s", new_voice)
                await send({"type": "voice_status",
                            "state": "ready" if ok else "error",
                            "voice": tts.current_voice or new_voice})
                continue

            # ── Voice preview: sample line in ANY voice, active voice untouched ──
            if mtype == "preview_voice":
                preview_voice_id = msg.get("voice", "")
                preview_lang = _language_of_voice(preview_voice_id)
                if not preview_lang:
                    continue  # unknown voice id — ignore silently, like set_voice
                sample = system_text("preview_sample", preview_lang)
                downloading = _voice_download_pending(preview_lang, preview_voice_id)
                await send({
                    "type": "preview_status",
                    "state": "downloading" if downloading else "loading",
                    "voice": preview_voice_id,
                })
                # A preview_voice sent while Nova is mid-reply is naturally
                # queued, not raced: while _run_speaking() owns the socket the
                # message lands in its watcher and is buffered for the main
                # loop, so this handler only ever runs once speaking is done —
                # it can't interrupt or overlap the active playback.
                try:
                    await asyncio.to_thread(tts.preview, sample, preview_voice_id, preview_lang)
                    await send({"type": "preview_status", "state": "ready",
                                "voice": preview_voice_id})
                except Exception as exc:
                    log.error("Voice preview failed (%s): %s", preview_voice_id, exc)
                    await send({"type": "preview_status", "state": "error",
                                "voice": preview_voice_id})
                continue

            # ── Profile switch ───────────────────────────────────────────
            if mtype == "switch_profile" and mem_mgr:
                # Never trust a client-supplied slug: run it through the same
                # sanitizer the UI uses so a crafted slug can't escape the
                # profiles directory (path traversal → arbitrary file write).
                raw_slug = msg.get("slug", "")
                if not isinstance(raw_slug, str) or not raw_slug.strip():
                    continue
                # fallback="" so a name with no ASCII letters or digits at all
                # ("李明", "Мария") is rejected instead of collapsing to the
                # "child" default — two such names would otherwise share one
                # profile and read each other's memory.
                new_slug = name_to_slug(raw_slug, fallback="")
                if not new_slug:
                    await send({
                        "type": "profile_error",
                        "message": "Please use letters or numbers in the name.",
                    })
                    continue
                # When the modal is *creating* a child it also sends the chosen
                # language + level; validated and used only if the slug is new
                # (an existing profile keeps its own stored language/level).
                raw_lang = msg.get("language")
                create_language = raw_lang if raw_lang in LANGUAGES else None
                create_level = msg.get("level") if isinstance(msg.get("level"), str) else None
                await _swap_profile(
                    new_slug,
                    create_language=create_language,
                    create_level=create_level,
                    create_name=raw_slug.strip() or None,
                )
                continue

            # ── Profile delete ───────────────────────────────────────────
            if mtype == "delete_profile" and mem_mgr:
                # Sanitise the same way switch does — a client slug is never
                # trusted to reach the filesystem unfiltered.
                raw_slug = msg.get("slug", "")
                if not isinstance(raw_slug, str) or not raw_slug.strip():
                    continue
                # fallback="" so junk that sanitises to nothing is rejected
                # rather than collapsing to the "child" default and deleting
                # an unrelated profile.
                target = name_to_slug(raw_slug, fallback="")
                profiles = mem_mgr.list_profiles()
                if not target or target not in profiles:
                    continue
                # Refuse to delete the last remaining child — the app always
                # needs an active profile to fall back to.
                if len(profiles) <= 1:
                    await send({"type": "profile_error",
                                "message": "Can't remove the only child."})
                    continue
                remaining = [p for p in profiles if p != target]
                if target == mem_mgr.slug:
                    # Drain in-flight extraction tasks BEFORE unlinking: a
                    # pending task holds the outgoing profile's MemoryManager
                    # and would re-create the file via save() if we deleted
                    # first. save_current=False then skips the explicit re-save
                    # during the swap.
                    await _drain_pending()
                    mem_mgr.delete_profile(target)
                    # Delete via the live store instance so it's tombstoned: a
                    # correction task that outlived the drain holds this same
                    # object and would otherwise recreate the file.
                    (transcript_store or
                     TranscriptStore(transcripts_dir, target)).delete()
                    await _swap_profile(remaining[0], save_current=False)
                else:
                    mem_mgr.delete_profile(target)
                    # Non-active profile has no in-flight tasks (draining happens
                    # when switching away from it), so a fresh instance is fine.
                    TranscriptStore(transcripts_dir, target).delete()
                    await send({"type": "profiles",
                                "list": remaining,
                                "active": mem_mgr.slug})
                continue

            if mtype != "ptt_start":
                continue

            # Child pressed Space before tapping the start prompt — that's a
            # valid start signal too. Skip the greeting (they're initiating
            # already) and just proceed to LISTENING.
            has_greeted = True

            # ── LISTENING ────────────────────────────────────────────────
            await send({"type": "state", "state": "listening"})
            try:
                # start() opens the persistent stream on the first turn; later
                # turns just re-arm capture. Bounded so a permission-blocked
                # open can't hang the session.
                await asyncio.wait_for(
                    asyncio.to_thread(recorder.start), RECORD_GRACE_S)
            except Exception:
                log.error("Recording did not start — treating as no audio")
            # Read until ptt_stop; anything else that arrives mid-recording
            # (e.g. a set_level click) is stashed and replayed to the main
            # loop after this turn instead of being swallowed.
            stashed: list[str] = []
            got_stop = False
            try:
                while True:
                    if buffered_msgs:
                        raw2 = buffered_msgs.pop(0)
                    else:
                        raw2 = await asyncio.wait_for(ws.recv(), timeout=30.0)
                    if json.loads(raw2).get("type") == "ptt_stop":
                        got_stop = True
                        break
                    stashed.append(raw2)
            except asyncio.TimeoutError:
                pass
            buffered_msgs.extend(stashed)
            if not got_stop:
                await asyncio.to_thread(recorder.stop)   # discard partial audio
                await send({"type": "state", "state": "idle"})
                continue
            audio = await asyncio.to_thread(recorder.stop)

            # ── THINKING ─────────────────────────────────────────────────
            await send({"type": "state", "state": "thinking"})
            _stt_t0 = _time.monotonic()
            transcript = await asyncio.to_thread(stt.transcribe, audio, active_language)
            stt_ms = int((_time.monotonic() - _stt_t0) * 1000)
            _ptt_stop_t = _stt_t0   # approximate ptt_stop time as stt start

            if not transcript:
                log.info("No speech detected")
                if telemetry:
                    telemetry.log_didnt_catch()
                await send({"type": "state", "state": "didnt_catch"})
                sorry = system_text("sorry", active_language)
                await send({"type": "sentence", "text": sorry})
                await asyncio.to_thread(tts.speak_streaming, sorry, amplitude_cb)
                await send({"type": "amplitude", "value": 0.0})
                await asyncio.sleep(0.4)
                await send({"type": "state", "state": "idle"})
                continue

            log.info("Heard: %s", transcript)
            await send(_with_furigana({"type": "transcript", "text": transcript},
                                      "text"))

            word_count = len(transcript.split())
            if word_count <= config.memory.short_response_words:
                consecutive_short += 1
            else:
                consecutive_short = 0

            # ── SPEAKING ─────────────────────────────────────────────────
            await send({"type": "state", "state": "speaking"})
            spoken_sentences: list[str] = []

            reengagement_fired = bool(
                mem_mgr and memory and
                consecutive_short >= config.memory.short_response_streak
            )
            if reengagement_fired:
                llm.set_hint(_REENGAGEMENT_HINT)
                consecutive_short = 0

            _llm_t0 = _time.monotonic()
            _llm_ttft_ms: list[int] = []  # filled by first sentence
            _first_audio_ms: list[int] = []  # release → first TTS frame

            def _tracked_amp(value: float) -> None:
                if not _first_audio_ms and value > 0:
                    _first_audio_ms.append(
                        int((_time.monotonic() - _ptt_stop_t) * 1000)
                    )
                amplitude_cb(value)

            def _run_pipeline(stop_speaking) -> None:
                try:
                    for i, sentence in enumerate(llm.chat(transcript)):
                        if i == 0:
                            _llm_ttft_ms.append(int((_time.monotonic() - _llm_t0) * 1000))
                        if stop_speaking.is_set():
                            break
                        spoken_sentences.append(sentence)
                        send_from_thread(_with_furigana(
                            {"type": "sentence", "text": sentence}, "text"))
                        tts.speak_streaming(sentence, _tracked_amp, stop_speaking)
                        send_from_thread({"type": "amplitude", "value": 0.0})
                except RuntimeError as exc:
                    log.error("Pipeline error: %s", exc)
                    send_from_thread({"type": "sentence",
                                      "text": system_text("napping", active_language)})

            # Barge-in while the reply streams: a `stop_speak` sets the shared
            # stop event (TTS aborts, loop breaks after the current sentence);
            # other messages are buffered for the main loop. See _run_speaking.
            await _run_speaking(_run_pipeline)

            total_ms = int((_time.monotonic() - _ptt_stop_t) * 1000)
            llm_ttft_ms = _llm_ttft_ms[0] if _llm_ttft_ms else 0
            first_audio_ms = _first_audio_ms[0] if _first_audio_ms else 0
            await send({"type": "state", "state": "idle"})

            # ── Transcript entry (immediate; corrections patched in later) ──
            if spoken_sentences and transcript:
                conv_turn_n += 1
                nova_reply = " ".join(spoken_sentences)
                await send(_with_furigana({
                    "type": "conversation_turn",
                    "id": conv_turn_n,
                    "you": transcript,
                    "nova": nova_reply,
                }, "you", "nova"))
                if transcript_store:
                    transcript_store.append_turn(conv_turn_n, transcript, nova_reply)

            # ── POST-TURN EXTRACTION + TELEMETRY ───────────────────────────
            if mem_mgr and memory and extractor and spoken_sentences and transcript:
                full_reply = " ".join(spoken_sentences)
                _mem_ref = memory
                _mgr_ref = mem_mgr
                _store_ref = transcript_store   # bound now so a later swap can't misroute
                _conv_id = conv_turn_n

                _tel_ref = telemetry
                _stt_ms_ref = stt_ms
                _ttft_ref = llm_ttft_ms
                _first_audio_ref = first_audio_ms
                _total_ref = total_ms
                _level_ref = active_level
                _reeng_ref = reengagement_fired
                _wc_ref = len(transcript.split())

                def _extract_and_save() -> None:
                    try:
                        result = extractor.extract(transcript, full_reply)
                        if result.topic:
                            _mgr_ref.update_topic(_mem_ref, result.topic)
                        parsed = result.parse_problem()
                        if parsed:
                            _mgr_ref.update_problem(_mem_ref, *parsed)
                            # Patch the transcript entry with the correction so
                            # the tab can highlight what was gently fixed.
                            ptype, wrong, right = parsed
                            send_from_thread(_with_furigana({
                                "type": "conversation_correction",
                                "id": _conv_id,
                                "kind": ptype,
                                "wrong": wrong,
                                "right": right,
                            }, "wrong", "right"))
                            if _store_ref:
                                _store_ref.append_correction(
                                    _conv_id, ptype, wrong, right)
                        _mgr_ref.prune(_mem_ref)
                        _mgr_ref.save(_mem_ref)
                        loop.call_soon_threadsafe(_apply_extracted_memory, _mem_ref)
                        # Record telemetry turn with extracted metadata
                        if _tel_ref:
                            _tel_ref.log_turn(
                                transcript=transcript,
                                reply=full_reply,
                                stt_ms=_stt_ms_ref,
                                llm_ttft_ms=_ttft_ref,
                                first_audio_ms=_first_audio_ref,
                                total_ms=_total_ref,
                                level=_level_ref,
                                topic=result.topic,
                                problem=result.problem_raw,
                                engaged=result.engaged,
                                reengagement_fired=_reeng_ref,
                            )
                    except Exception as exc:
                        log.debug("Memory extraction failed (non-fatal): %s", exc)

                pending_tasks.append(
                    asyncio.ensure_future(asyncio.to_thread(_extract_and_save))
                )

            elif telemetry and spoken_sentences and transcript:
                # No extractor — log turn without topic/problem metadata
                telemetry.log_turn(
                    transcript=transcript,
                    reply=" ".join(spoken_sentences),
                    stt_ms=stt_ms,
                    llm_ttft_ms=llm_ttft_ms,
                    first_audio_ms=first_audio_ms,
                    total_ms=total_ms,
                    level=active_level,
                    engaged=len(transcript.split()) > config.memory.short_response_words,
                    reengagement_fired=reengagement_fired,
                )

    except websockets.ConnectionClosed:
        log.info("Client disconnected")
    finally:
        # Await pending extraction/save tasks so we don't (a) lose the last
        # turn's telemetry (log_turn happens inside these) or (b) race the
        # disconnect-time memory save below. Tasks still running after the
        # timeout are abandoned — safe, because telemetry._write no-ops
        # once the file handle is closed.
        await _drain_pending()
        recorder.close()
        if mem_mgr and memory:
            try:
                mem_mgr.prune(memory)
                mem_mgr.save(memory)
            except Exception as exc:
                log.debug("Final memory save failed: %s", exc)
        if telemetry:
            telemetry.end()
            log.info("Telemetry written to %s", telemetry.log_file)


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

async def _main(profile_slug: Optional[str] = None, port: int = PORT,
                managed: bool = False) -> None:
    config = Config.load(str(default_config_path()))

    # Language, level, and voice are now stored per-profile (on ChildProfile),
    # not in global settings.json — a global voice/level would be wrong across
    # children and languages. config.yaml still supplies the seed defaults for
    # the first-run profile.

    # Persist the server's own log beside telemetry (the packaged app's stderr
    # is otherwise lost). After config load so log_dir is known.
    configure_logging(config.telemetry.log_dir)

    if profile_slug is None:
        profile_slug = name_to_slug(config.child.name)
    else:
        # Uniform invariant: no unsanitized slug ever reaches MemoryManager,
        # whether it came from config, the CLI, or a WebSocket message.
        profile_slug = name_to_slug(profile_slug)

    mem_mgr: Optional[MemoryManager] = None
    if config.memory.enabled:
        mem_mgr = MemoryManager(
            config.memory.profiles_dir,
            profile_slug,
            max_topics=config.memory.max_topics,
            max_problems=config.memory.max_problems,
            topic_ttl_days=config.memory.topic_ttl_days,
            problem_ttl_days=config.memory.problem_ttl_days,
        )
        log.info("Memory enabled — profile: %s", profile_slug)

    # ── Deferred pipeline init (design §2.8) ─────────────────────────────
    # The socket opens BEFORE models load, so the UI can connect immediately
    # and render setup progress: first-run model downloads (~600 MB) and the
    # Ollama check no longer block the server. Until `ready` fires, handlers
    # hold clients on a setup screen instead of starting a session.
    loop = asyncio.get_running_loop()
    pipelines: dict[str, Any] = {"stt": None, "llm": None, "tts": None}
    ready = asyncio.Event()
    setup_state = {"phase": "starting", "detail": ""}
    setup_watchers: set = set()

    async def _broadcast_setup(phase: str, detail: str = "") -> None:
        setup_state.update(phase=phase, detail=detail)
        log.info("Setup: %s %s", phase, detail)
        payload = json.dumps({"type": "setup_status", "phase": phase,
                              "detail": detail})
        for w in list(setup_watchers):
            try:
                await w.send(payload)
            except Exception:
                setup_watchers.discard(w)

    async def _init_pipelines() -> None:
        # Phase A: Ollama check — re-poll so the parent can install/start
        # Ollama without relaunching the app.
        while True:
            ok, msg = await asyncio.to_thread(
                check_ollama, config.models.llm.model)
            if ok:
                break
            await _broadcast_setup("ollama_missing", msg)
            await asyncio.sleep(3.0)

        # Phase B: model load. Only advertise a download when something
        # actually needs fetching — otherwise a cached relaunch (models already
        # on disk) shows the "downloading ~600 MB, only happens once" screen and
        # looks like it's re-downloading every time.
        need_download = not (
            voice_is_cached(config.models.tts.voice)
            and whisper_is_cached(config.models.stt.model)
        )
        if need_download:
            await _broadcast_setup(
                "downloading_models",
                "Loading voice models — the first run downloads about 600 MB.")
        else:
            await _broadcast_setup("loading_models")
        pipelines["stt"] = await asyncio.to_thread(STTPipeline, config)
        pipelines["tts"] = await asyncio.to_thread(TTSPipeline, config)
        pipelines["llm"] = LLMPipeline(config)   # no local weights; cheap

        ready.set()
        await _broadcast_setup("ready")

    init_task = asyncio.ensure_future(_init_pipelines())

    async def _handler(ws):
        if not ready.is_set():
            setup_watchers.add(ws)
            try:
                await ws.send(json.dumps(
                    {"type": "setup_status", **setup_state}))
                await ready.wait()
                await ws.send(json.dumps(
                    {"type": "setup_status", "phase": "ready", "detail": ""}))
            except Exception:
                return   # client went away during setup
            finally:
                setup_watchers.discard(ws)
        telemetry = None
        if config.telemetry.enabled:
            telemetry = TelemetrySession(config.telemetry.log_dir, profile_slug)
        await _session(ws, config, pipelines["stt"], pipelines["llm"],
                       pipelines["tts"], mem_mgr, telemetry)

    # With --managed (set by the Tauri shell, which owns our stdin pipe),
    # shut down when stdin closes: parent death — including SIGKILL —
    # surfaces here as EOF, so no orphaned sidecar survives the app.
    stop = loop.create_future()

    def _watch_stdin() -> None:
        try:
            while sys.stdin.buffer.read(4096):
                pass
        except Exception:
            pass
        log.info("stdin closed — parent exited, shutting down")
        loop.call_soon_threadsafe(
            lambda: stop.done() or stop.set_result(None))
        # Clean shutdown can be blocked by non-daemon worker threads (e.g.
        # a model download in progress). The parent is gone — nothing is
        # worth waiting for. Hard-exit if we're still alive shortly after.
        import os
        import time
        time.sleep(10.0)
        log.warning("shutdown still pending 10 s after stdin EOF — exiting")
        os._exit(0)

    if managed:
        threading.Thread(target=_watch_stdin, daemon=True).start()

    async with websockets.serve(_handler, HOST, port, origins=ALLOWED_ORIGINS):
        log.info("Nova WebSocket server → ws://%s:%d", HOST, port)
        # Readiness line for the Tauri shell (stdout is a pipe — flush).
        print(f"NOVA_READY ws://{HOST}:{port}", flush=True)
        try:
            await stop
        finally:
            init_task.cancel()


if __name__ == "__main__":
    import argparse
    import multiprocessing
    # Frozen (PyInstaller) builds: library code (huggingface_hub, ctranslate2)
    # spawns helper processes by re-invoking this executable; freeze_support
    # dispatches those re-invocations instead of falling through to argparse.
    multiprocessing.freeze_support()
    parser = argparse.ArgumentParser(description="Nova WebSocket server")
    parser.add_argument("--profile",
                        help="Profile slug (overrides config.yaml child.name)")
    parser.add_argument("--port", type=int, default=PORT,
                        help=f"WebSocket port (default {PORT})")
    parser.add_argument("--managed", action="store_true",
                        help="Exit when stdin closes (set by the app shell "
                             "that spawned this process)")
    args = parser.parse_args()
    asyncio.run(_main(profile_slug=args.profile, port=args.port,
                      managed=args.managed))