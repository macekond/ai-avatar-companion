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
  {"type": "ptt_start"}
  {"type": "ptt_stop"}
  {"type": "stop_speak"}                     # barge-in while speaking/thinking
  {"type": "set_level",      "level": "B"}
  {"type": "set_voice",      "voice": "en_US-kristin-medium"}
  {"type": "switch_profile", "slug": "mia"}
  {"type": "delete_profile", "slug": "mia"}
  {"type": "avatar_loaded", "key": "VIPEHero_2707"}   # avatar changed → refresh appearance

Server → browser:
  {"type": "init",          "level": "A"}
  {"type": "profiles",      "list": ["lily","mia"], "active": "lily"}
  {"type": "profile_error", "message": "Can't remove the only child."}
  {"type": "onboarding_start"}
  {"type": "memory_loaded",  "name": "Lily", "age": 8}
  {"type": "state",         "state": "idle|listening|thinking|speaking|didnt_catch"}
  {"type": "transcript",    "text": "…"}
  {"type": "sentence",      "text": "…"}
  {"type": "amplitude",     "value": 0–1}
  {"type": "conversation_turn",       "id": 1, "you": "…", "nova": "…"}
  {"type": "conversation_correction", "id": 1, "kind": "past_tense",
                                      "wrong": "goed", "right": "went"}

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

from app.config import Config, default_config_path
from app.memory import ChildMemory, ChildProfile, MemoryManager, name_to_slug
from app.settings import load_settings, save_setting
from app.setup import check_ollama

# Curated voice list for the Settings panel. Deliberately limited to voices
# with permissive licenses (public domain / CC0) — the previous default
# en_US-lessac was Blizzard-licensed (research only) and is excluded.
AVAILABLE_VOICES = [
    {"id": "en_US-kristin-medium", "label": "Kristin — bright, younger (US)"},
    {"id": "en_US-ljspeech-medium", "label": "LJ — calm, clear (US)"},
    {"id": "en_US-joe-medium",      "label": "Joe — friendly male (US)"},
    {"id": "en_US-norman-medium",   "label": "Norman — deeper male (US)"},
]
_VOICE_IDS = {v["id"] for v in AVAILABLE_VOICES}
from app.appearance import AppearanceStore, DEFAULT_AVATAR_KEY
from app.memory_extractor import MemoryExtractor
from app.pipeline.llm import LLMPipeline
from app.pipeline.stt import STTPipeline, SAMPLE_RATE
from app.pipeline.tts import TTSPipeline, voice_is_cached
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


def _record(stop: threading.Event) -> np.ndarray:
    """Record audio until *stop* is set. Called in a thread-pool executor.

    Returns an empty array on any failure (no mic, permission denied) so the
    caller flows into the didn't-catch path instead of crashing the session.
    """
    import sounddevice as sd

    chunks: list[np.ndarray] = []

    def _cb(indata: np.ndarray, frames: int, _time, _status) -> None:
        chunks.append(indata.copy())

    try:
        with sd.InputStream(samplerate=SAMPLE_RATE, channels=1,
                            dtype="float32", callback=_cb):
            stop.wait()
    except Exception as exc:
        log.error("Recording failed (mic unavailable or permission denied): %s", exc)
        return np.zeros(0, dtype=np.float32)

    if not chunks:
        return np.zeros(0, dtype=np.float32)
    return np.concatenate(chunks, axis=0).squeeze()


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

async def _one_ptt_turn(
    ws,
    stt: STTPipeline,
    loop: asyncio.AbstractEventLoop,
    send,
) -> str:
    """Wait for Space-press, record, and return the transcript (may be empty)."""
    await send({"type": "state", "state": "listening"})
    stop_rec = threading.Event()
    rec_task = loop.run_in_executor(None, _record, stop_rec)
    try:
        raw = await asyncio.wait_for(ws.recv(), timeout=60.0)
        json.loads(raw)  # consume ptt_stop
    except asyncio.TimeoutError:
        stop_rec.set()
        await send({"type": "state", "state": "idle"})
        return ""
    stop_rec.set()
    try:
        audio = await asyncio.wait_for(rec_task, RECORD_GRACE_S)
    except Exception:
        log.error("Recording did not complete — treating as no audio")
        audio = np.zeros(0, dtype=np.float32)
    await send({"type": "state", "state": "thinking"})
    return await asyncio.to_thread(stt.transcribe, audio)


# ---------------------------------------------------------------------------
# Onboarding
# ---------------------------------------------------------------------------

async def _run_onboarding(
    ws,
    config: Config,
    stt: STTPipeline,
    tts: TTSPipeline,
    mem_mgr: MemoryManager,
    loop: asyncio.AbstractEventLoop,
    send,
    send_from_thread,
) -> ChildMemory:
    """Two-turn onboarding: learn the child's name and age."""
    avatar = config.personality.avatar_name

    def amp(v: float) -> None:
        send_from_thread({"type": "amplitude", "value": round(v, 3)})

    # --- Ask for name ---
    q1 = (f"Hi! I'm {avatar}, your English practice friend! "
          f"I'm so happy to meet you! What's your name?")
    await send({"type": "state", "state": "speaking"})
    await send({"type": "sentence", "text": q1})
    await asyncio.to_thread(tts.speak_streaming, q1, amp)
    await send({"type": "amplitude", "value": 0.0})
    await send({"type": "state", "state": "idle"})

    # consume ptt_start, then record
    try:
        await asyncio.wait_for(ws.recv(), timeout=60.0)
    except asyncio.TimeoutError:
        pass
    name_transcript = await _one_ptt_turn(ws, stt, loop, send)
    name = _extract_name(name_transcript) if name_transcript else None
    if not name:
        name = "Friend"

    # --- Ask for age ---
    q2 = f"What a lovely name, {name}! How old are you?"
    await send({"type": "state", "state": "speaking"})
    await send({"type": "sentence", "text": q2})
    await asyncio.to_thread(tts.speak_streaming, q2, amp)
    await send({"type": "amplitude", "value": 0.0})
    await send({"type": "state", "state": "idle"})

    try:
        await asyncio.wait_for(ws.recv(), timeout=60.0)
    except asyncio.TimeoutError:
        pass
    age_transcript = await _one_ptt_turn(ws, stt, loop, send)
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
) -> None:
    avatar = config.personality.avatar_name

    if memory:
        name = memory.profile.name
        age_note = f" (age {memory.profile.age})" if memory.profile.age else ""
        if memory.topics:
            recent_topic = sorted(
                memory.topics, key=lambda t: t.last_mentioned, reverse=True
            )[0].keyword
            text = (f"Welcome back, {name}{age_note}! "
                    f"Last time we talked about {recent_topic}. "
                    f"What's new today?")
        else:
            text = (f"Welcome back, {name}{age_note}! "
                    f"I missed you! What did you get up to?")
    else:
        name = config.child.name
        text = (f"Hi {name}! I'm {avatar}, your English practice friend. "
                f"What did you do today?")

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

    async def _drain_pending(timeout: float = 5.0) -> None:
        still_running = [t for t in pending_tasks if not t.done()]
        if still_running:
            await asyncio.wait(still_running, timeout=timeout)
        pending_tasks.clear()

    # Level for this session — starts from config, updated by UI 'set_level'
    # so telemetry reflects what the child is actually practising.
    active_level = config.child.level

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

    # ── Load / initialise memory ─────────────────────────────────────────
    memory: Optional[ChildMemory] = mem_mgr.load() if mem_mgr else None

    # ── On-connect messages ──────────────────────────────────────────────
    log.info("Client connected")
    await send({"type": "init", "level": active_level})

    # Settings panel state: available voices + current selection + level.
    await send({
        "type": "settings",
        "voices": AVAILABLE_VOICES,
        "voice": config.models.tts.voice,
        "level": active_level,
    })

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
        memory = await _run_onboarding(
            ws, config, stt, tts, mem_mgr, loop, send, send_from_thread,
        )
        llm.set_memory(memory)
    elif memory is not None:
        llm.set_memory(memory)
        await send({"type": "memory_loaded",
                    "name": memory.profile.name,
                    "age": memory.profile.age})
    else:
        llm.set_memory(None)

    # ── Opening greeting ─────────────────────────────────────────────────
    await _send_greeting(config, memory, tts, send, send_from_thread)

    # ── Main loop ────────────────────────────────────────────────────────
    consecutive_short = 0
    conv_turn_n = 0   # id for transcript entries (child↔Nova exchanges)

    async def _swap_profile(new_slug: str, save_current: bool = True) -> None:
        """Hot-swap the active child profile to ``new_slug``.

        Drains in-flight extraction tasks first (a slow task from the previous
        child would otherwise call llm.set_memory with the old memory *after*
        the swap, leaking one child's context into another's). When the target
        profile has no file yet, runs onboarding; otherwise greets normally.

        ``save_current=False`` skips persisting the outgoing memory — used when
        the outgoing profile was just deleted and must not be resurrected.
        """
        nonlocal mem_mgr, memory, consecutive_short
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
        llm.set_memory(memory)
        llm.clear_history()
        consecutive_short = 0
        await send({"type": "profiles",
                    "list": mem_mgr.list_profiles(),
                    "active": new_slug})
        if memory is None:
            await send({"type": "onboarding_start"})
            memory = await _run_onboarding(
                ws, config, stt, tts, mem_mgr, loop, send, send_from_thread,
            )
            llm.set_memory(memory)
        else:
            await send({"type": "memory_loaded",
                        "name": memory.profile.name,
                        "age": memory.profile.age})
        await _send_greeting(config, memory, tts, send, send_from_thread)

    # Messages consumed by the barge-in watcher (or by the listening phase)
    # that belong to the main loop are buffered here and drained before the
    # next real read from the socket.
    buffered_msgs: list[str] = []

    async def _next_raw() -> str:
        if buffered_msgs:
            return buffered_msgs.pop(0)
        # ws.recv(), not async-for/__anext__: the real websockets
        # ServerConnection has no __anext__ (only __aiter__), so iteration
        # helpers must go through recv(). Raises ConnectionClosed on close.
        return await ws.recv()

    try:
        while True:
            try:
                raw = await _next_raw()
            except (websockets.ConnectionClosed, StopAsyncIteration,
                    asyncio.TimeoutError):
                # ConnectionClosed: client left. TimeoutError: test mocks
                # signal queue exhaustion this way.
                break
            msg = json.loads(raw)
            mtype = msg.get("type")

            # ── Level change ─────────────────────────────────────────────
            if mtype == "set_level":
                new_level = msg.get("level", "A")
                llm.set_level(new_level)
                active_level = new_level
                save_setting("level", new_level)
                log.info("Level changed to: %s", new_level)
                continue

            # ── Avatar changed: refresh appearance description ───────────
            if mtype == "avatar_loaded":
                _apply_appearance(msg.get("key", ""))
                continue

            # ── Voice change ─────────────────────────────────────────────
            if mtype == "set_voice":
                new_voice = msg.get("voice", "")
                if new_voice not in _VOICE_IDS:
                    continue
                # First use of a voice pulls ~60 MB from HuggingFace — tell
                # the UI it's downloading (not just loading) so it can show a
                # clear one-time indicator.
                downloading = not voice_is_cached(new_voice)
                await send({
                    "type": "voice_status",
                    "state": "downloading" if downloading else "loading",
                    "voice": new_voice,
                })
                # Reloading loads (and may download) the model — off the loop.
                ok = await asyncio.to_thread(tts.reload_voice, new_voice)
                if ok:
                    config.models.tts.voice = new_voice
                    save_setting("voice", new_voice)
                    log.info("Voice changed to: %s", new_voice)
                await send({"type": "voice_status",
                            "state": "ready" if ok else "error",
                            "voice": tts.current_voice or new_voice})
                continue

            # ── Profile switch ───────────────────────────────────────────
            if mtype == "switch_profile" and mem_mgr:
                # Never trust a client-supplied slug: run it through the same
                # sanitizer the UI uses so a crafted slug can't escape the
                # profiles directory (path traversal → arbitrary file write).
                raw_slug = msg.get("slug", "")
                if not isinstance(raw_slug, str) or not raw_slug.strip():
                    continue
                new_slug = name_to_slug(raw_slug)
                await _swap_profile(new_slug)
                continue

            # ── Profile delete ───────────────────────────────────────────
            if mtype == "delete_profile" and mem_mgr:
                # Sanitise the same way switch does — a client slug is never
                # trusted to reach the filesystem unfiltered.
                raw_slug = msg.get("slug", "")
                if not isinstance(raw_slug, str) or not raw_slug.strip():
                    continue
                target = name_to_slug(raw_slug)
                profiles = mem_mgr.list_profiles()
                if target not in profiles:
                    continue
                # Refuse to delete the last remaining child — the app always
                # needs an active profile to fall back to.
                if len(profiles) <= 1:
                    await send({"type": "profile_error",
                                "message": "Can't remove the only child."})
                    continue
                was_active = target == mem_mgr.slug
                mem_mgr.delete_profile(target)
                if was_active:
                    # Don't persist the outgoing memory — the file is gone and
                    # saving would resurrect the profile we just deleted.
                    memory = None
                    remaining = [p for p in profiles if p != target]
                    await _swap_profile(remaining[0], save_current=False)
                else:
                    await send({"type": "profiles",
                                "list": mem_mgr.list_profiles(),
                                "active": mem_mgr.slug})
                continue

            if mtype != "ptt_start":
                continue

            # ── LISTENING ────────────────────────────────────────────────
            await send({"type": "state", "state": "listening"})
            stop_rec = threading.Event()
            rec_task = loop.run_in_executor(None, _record, stop_rec)
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
                stop_rec.set()
                await send({"type": "state", "state": "idle"})
                continue
            stop_rec.set()
            try:
                audio = await asyncio.wait_for(rec_task, RECORD_GRACE_S)
            except Exception:
                # Stream open can hang without mic permission; don't let the
                # session hang with it — flow into the didn't-catch path.
                log.error("Recording did not complete — treating as no audio")
                audio = np.zeros(0, dtype=np.float32)

            # ── THINKING ─────────────────────────────────────────────────
            await send({"type": "state", "state": "thinking"})
            _stt_t0 = _time.monotonic()
            transcript = await asyncio.to_thread(stt.transcribe, audio)
            stt_ms = int((_time.monotonic() - _stt_t0) * 1000)
            _ptt_stop_t = _stt_t0   # approximate ptt_stop time as stt start

            if not transcript:
                log.info("No speech detected")
                if telemetry:
                    telemetry.log_didnt_catch()
                await send({"type": "state", "state": "didnt_catch"})
                sorry = "I didn't hear you — try again!"
                await send({"type": "sentence", "text": sorry})
                await asyncio.to_thread(tts.speak_streaming, sorry, amplitude_cb)
                await send({"type": "amplitude", "value": 0.0})
                await asyncio.sleep(0.4)
                await send({"type": "state", "state": "idle"})
                continue

            log.info("Heard: %s", transcript)
            await send({"type": "transcript", "text": transcript})

            word_count = len(transcript.split())
            if word_count <= config.memory.short_response_words:
                consecutive_short += 1
            else:
                consecutive_short = 0

            # ── SPEAKING ─────────────────────────────────────────────────
            await send({"type": "state", "state": "speaking"})
            stop_speaking = threading.Event()
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

            def _run_pipeline() -> None:
                try:
                    for i, sentence in enumerate(llm.chat(transcript)):
                        if i == 0:
                            _llm_ttft_ms.append(int((_time.monotonic() - _llm_t0) * 1000))
                        if stop_speaking.is_set():
                            break
                        spoken_sentences.append(sentence)
                        send_from_thread({"type": "sentence", "text": sentence})
                        tts.speak_streaming(sentence, _tracked_amp, stop_speaking)
                        send_from_thread({"type": "amplitude", "value": 0.0})
                except RuntimeError as exc:
                    log.error("Pipeline error: %s", exc)
                    send_from_thread({"type": "sentence",
                                      "text": "My brain is napping — try again!"})

            # Barge-in: while the pipeline runs, watch the socket for a
            # `stop_speak` message. When one arrives, set the shared stop
            # event so TTS aborts and the pipeline breaks after the current
            # sentence. Other messages are buffered for the main loop.
            # (Catching asyncio.TimeoutError also lets MockWebSocket-based
            # tests terminate the watcher when their message queue drains.)
            async def _watch_for_stop() -> None:
                while True:
                    try:
                        raw3 = await ws.recv()
                    except (asyncio.TimeoutError,
                            websockets.ConnectionClosed,
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

            _turn_t0 = _time.monotonic()
            pipeline_task = asyncio.create_task(asyncio.to_thread(_run_pipeline))
            watcher_task = asyncio.create_task(_watch_for_stop())
            done, _ = await asyncio.wait(
                {pipeline_task, watcher_task},
                return_when=asyncio.FIRST_COMPLETED,
            )
            if watcher_task not in done:
                watcher_task.cancel()
                try:
                    await watcher_task
                except asyncio.CancelledError:
                    pass
            if pipeline_task not in done:
                # Watcher fired first: wait for the pipeline to unwind (TTS
                # honors stop_speaking; loop breaks after current sentence).
                await pipeline_task

            total_ms = int((_time.monotonic() - _ptt_stop_t) * 1000)
            llm_ttft_ms = _llm_ttft_ms[0] if _llm_ttft_ms else 0
            first_audio_ms = _first_audio_ms[0] if _first_audio_ms else 0
            await send({"type": "state", "state": "idle"})

            # ── Transcript entry (immediate; corrections patched in later) ──
            if spoken_sentences and transcript:
                conv_turn_n += 1
                await send({
                    "type": "conversation_turn",
                    "id": conv_turn_n,
                    "you": transcript,
                    "nova": " ".join(spoken_sentences),
                })

            # ── POST-TURN EXTRACTION + TELEMETRY ───────────────────────────
            if mem_mgr and memory and extractor and spoken_sentences and transcript:
                full_reply = " ".join(spoken_sentences)
                _mem_ref = memory
                _mgr_ref = mem_mgr
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
                            send_from_thread({
                                "type": "conversation_correction",
                                "id": _conv_id,
                                "kind": ptype,
                                "wrong": wrong,
                                "right": right,
                            })
                        _mgr_ref.prune(_mem_ref)
                        _mgr_ref.save(_mem_ref)
                        loop.call_soon_threadsafe(llm.set_memory, _mem_ref)
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

    # Apply persisted user settings (Settings panel) over config defaults.
    _saved = load_settings()
    if _saved.get("voice") in _VOICE_IDS:
        config.models.tts.voice = _saved["voice"]
    if _saved.get("level"):
        config.child.level = _saved["level"]

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

        # Phase B: model load (downloads on first run, cached afterwards).
        await _broadcast_setup(
            "downloading_models",
            "Loading voice models — the first run downloads about 600 MB.")
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