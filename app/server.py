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
  {"type": "set_level",      "level": "B"}
  {"type": "switch_profile", "slug": "mia"}

Server → browser:
  {"type": "init",          "level": "A"}
  {"type": "profiles",      "list": ["lily","mia"], "active": "lily"}
  {"type": "onboarding_start"}
  {"type": "memory_loaded",  "name": "Lily", "age": 8}
  {"type": "state",         "state": "idle|listening|thinking|speaking|didnt_catch"}
  {"type": "transcript",    "text": "…"}
  {"type": "sentence",      "text": "…"}
  {"type": "amplitude",     "value": 0–1}

Run:
    python app/server.py
    python app/server.py --profile mia
"""
from __future__ import annotations

import asyncio
import json
import logging
import re
import threading
from typing import Any, Optional

import numpy as np
import websockets
from dotenv import load_dotenv

load_dotenv()

from app.config import Config
from app.memory import ChildMemory, ChildProfile, MemoryManager, name_to_slug
from app.memory_extractor import MemoryExtractor
from app.pipeline.llm import LLMPipeline
from app.pipeline.stt import STTPipeline, SAMPLE_RATE
from app.pipeline.tts import TTSPipeline
from app.telemetry import TelemetrySession

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("nova.server")

HOST = "localhost"
PORT = 8765

_REENGAGEMENT_HINT = (
    "The child seems quiet. Based on the memory context in the system prompt, "
    "introduce a fresh topic from their interests or suggest a quick, fun activity "
    "to practise their known language challenge."
)


# ---------------------------------------------------------------------------
# Server-side recording
# ---------------------------------------------------------------------------

def _record(stop: threading.Event) -> np.ndarray:
    """Record audio until *stop* is set. Called in a thread-pool executor."""
    import sounddevice as sd

    chunks: list[np.ndarray] = []

    def _cb(indata: np.ndarray, frames: int, _time, _status) -> None:
        chunks.append(indata.copy())

    with sd.InputStream(samplerate=SAMPLE_RATE, channels=1, dtype="float32",
                        callback=_cb):
        stop.wait()

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
    audio = await rec_task
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

    # ── Load / initialise memory ─────────────────────────────────────────
    memory: Optional[ChildMemory] = mem_mgr.load() if mem_mgr else None

    # ── On-connect messages ──────────────────────────────────────────────
    log.info("Client connected")
    await send({"type": "init", "level": config.child.level})

    if mem_mgr:
        await send({
            "type": "profiles",
            "list": mem_mgr.list_profiles(),
            "active": mem_mgr.slug,
        })

    # ── Start telemetry session ──────────────────────────────────────
    is_onboarding = mem_mgr is not None and memory is None
    if telemetry:
        telemetry.start(level=config.child.level, is_onboarding=is_onboarding)

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

    try:
        async for raw in ws:
            msg = json.loads(raw)
            mtype = msg.get("type")

            # ── Level change ─────────────────────────────────────────────
            if mtype == "set_level":
                llm.set_level(msg.get("level", "A"))
                log.info("Level changed to: %s", msg.get("level"))
                continue

            # ── Profile switch ───────────────────────────────────────────
            if mtype == "switch_profile" and mem_mgr:
                new_slug = msg.get("slug", "").strip()
                if not new_slug:
                    continue
                if memory:
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
                continue

            if mtype != "ptt_start":
                continue

            # ── LISTENING ────────────────────────────────────────────────
            await send({"type": "state", "state": "listening"})
            stop_rec = threading.Event()
            rec_task = loop.run_in_executor(None, _record, stop_rec)
            try:
                raw2 = await asyncio.wait_for(ws.recv(), timeout=30.0)
                json.loads(raw2)  # ptt_stop
            except asyncio.TimeoutError:
                stop_rec.set()
                await send({"type": "state", "state": "idle"})
                continue
            stop_rec.set()
            audio = await rec_task

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

            def _run_pipeline() -> None:
                try:
                    for i, sentence in enumerate(llm.chat(transcript)):
                        if i == 0:
                            _llm_ttft_ms.append(int((_time.monotonic() - _llm_t0) * 1000))
                        if stop_speaking.is_set():
                            break
                        spoken_sentences.append(sentence)
                        send_from_thread({"type": "sentence", "text": sentence})
                        tts.speak_streaming(sentence, amplitude_cb, stop_speaking)
                        send_from_thread({"type": "amplitude", "value": 0.0})
                except RuntimeError as exc:
                    log.error("Pipeline error: %s", exc)
                    send_from_thread({"type": "sentence",
                                      "text": "My brain is napping — try again!"})

            _turn_t0 = _time.monotonic()
            await asyncio.to_thread(_run_pipeline)
            total_ms = int((_time.monotonic() - _ptt_stop_t) * 1000)
            llm_ttft_ms = _llm_ttft_ms[0] if _llm_ttft_ms else 0
            await send({"type": "state", "state": "idle"})

            # ── POST-TURN EXTRACTION + TELEMETRY ───────────────────────────
            if mem_mgr and memory and extractor and spoken_sentences and transcript:
                full_reply = " ".join(spoken_sentences)
                _mem_ref = memory
                _mgr_ref = mem_mgr

                _tel_ref = telemetry
                _stt_ms_ref = stt_ms
                _ttft_ref = llm_ttft_ms
                _total_ref = total_ms
                _level_ref = config.child.level
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
                                total_ms=_total_ref,
                                level=_level_ref,
                                topic=result.topic,
                                problem=result.problem_raw,
                                engaged=result.engaged,
                                reengagement_fired=_reeng_ref,
                            )
                    except Exception as exc:
                        log.debug("Memory extraction failed (non-fatal): %s", exc)

                asyncio.ensure_future(asyncio.to_thread(_extract_and_save))

            elif telemetry and spoken_sentences and transcript:
                # No extractor — log turn without topic/problem metadata
                telemetry.log_turn(
                    transcript=transcript,
                    reply=" ".join(spoken_sentences),
                    stt_ms=stt_ms,
                    llm_ttft_ms=llm_ttft_ms,
                    total_ms=total_ms,
                    level=config.child.level,
                    engaged=len(transcript.split()) > config.memory.short_response_words,
                    reengagement_fired=reengagement_fired,
                )

    except websockets.ConnectionClosed:
        log.info("Client disconnected")
        if mem_mgr and memory:
            mem_mgr.prune(memory)
            mem_mgr.save(memory)
    finally:
        if telemetry:
            telemetry.end()
            log.info("Telemetry written to %s", telemetry.log_file)


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

async def _main(profile_slug: Optional[str] = None) -> None:
    config = Config.load("config.yaml")

    if profile_slug is None:
        profile_slug = name_to_slug(config.child.name)

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

    log.info("Loading pipeline models…")
    stt = STTPipeline(config)
    tts = TTSPipeline(config)
    llm = LLMPipeline(config)

    log.info("Nova WebSocket server → ws://%s:%d", HOST, PORT)

    async def _handler(ws):
        telemetry = None
        if config.telemetry.enabled:
            telemetry = TelemetrySession(config.telemetry.log_dir, profile_slug)
        await _session(ws, config, stt, llm, tts, mem_mgr, telemetry)

    async with websockets.serve(_handler, HOST, PORT):
        await asyncio.Future()


if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser(description="Nova WebSocket server")
    parser.add_argument("--profile",
                        help="Profile slug (overrides config.yaml child.name)")
    args = parser.parse_args()
    asyncio.run(_main(profile_slug=args.profile))