"""WebSocket server — Python sidecar for the Phase 3 browser UI.

Listens on ws://localhost:8765. Each browser connection gets its own
session: PTT recording → STT → LLM → TTS with amplitude streaming.

Message protocol
----------------
Browser → server:
  {"type": "ptt_start"}          — Space held down
  {"type": "ptt_stop"}           — Space released

Server → browser:
  {"type": "state",      "state": "idle|listening|thinking|speaking|didnt_catch"}
  {"type": "transcript", "text": "…"}    — what STT heard (shown to child)
  {"type": "sentence",   "text": "…"}    — avatar's next sentence (shown + spoken)
  {"type": "amplitude",  "value": 0–1}   — RMS energy for lip-sync at ~20 Hz

Run:
    python app/server.py
"""
from __future__ import annotations

import asyncio
import json
import logging
import threading
from typing import Any, Callable

import numpy as np
import websockets
from dotenv import load_dotenv

load_dotenv()

from app.config import Config
from app.pipeline.llm import LLMPipeline
from app.pipeline.stt import STTPipeline, SAMPLE_RATE
from app.pipeline.tts import TTSPipeline

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("nova.server")

HOST = "localhost"
PORT = 8765


# ---------------------------------------------------------------------------
# Server-side recording (no tty — stopped by a threading.Event)
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
# Session handler
# ---------------------------------------------------------------------------

async def _session(
    ws,
    config: Config,
    stt: STTPipeline,
    llm: LLMPipeline,
    tts: TTSPipeline,
) -> None:
    loop = asyncio.get_running_loop()
    avatar = config.personality.avatar_name
    child  = config.child.name

    async def send(data: dict[str, Any]) -> None:
        try:
            await ws.send(json.dumps(data))
        except Exception:
            pass

    def send_from_thread(data: dict[str, Any]) -> None:
        """Thread-safe fire-and-forget send."""
        asyncio.run_coroutine_threadsafe(send(data), loop)

    def amplitude_cb(value: float) -> None:
        send_from_thread({"type": "amplitude", "value": round(value, 3)})

    # --- Init: tell the frontend the current level ---
    log.info("Client connected")
    await send({"type": "init", "level": config.child.level})

    # --- Greeting ---
    await send({"type": "state", "state": "speaking"})
    greeting = (
        f"Hi {child}! I'm {avatar}, your English practice friend. "
        f"What did you do today?"
    )
    await send({"type": "sentence", "text": greeting})
    await asyncio.to_thread(tts.speak_streaming, greeting, amplitude_cb)
    await send({"type": "amplitude", "value": 0.0})
    await send({"type": "state", "state": "idle"})

    # --- Main loop ---
    try:
        async for raw in ws:
            msg = json.loads(raw)

            # Level change — takes effect from the next LLM turn
            if msg.get("type") == "set_level":
                level = msg.get("level", "A")
                llm.set_level(level)
                log.info("Level changed to: %s", level)
                continue

            if msg.get("type") != "ptt_start":
                continue

            # ── LISTENING ──────────────────────────────────────────────
            await send({"type": "state", "state": "listening"})
            stop_rec = threading.Event()
            rec_task = loop.run_in_executor(None, _record, stop_rec)

            try:
                raw2 = await asyncio.wait_for(ws.recv(), timeout=30.0)
                msg2 = json.loads(raw2)
            except asyncio.TimeoutError:
                stop_rec.set()
                await send({"type": "state", "state": "idle"})
                continue

            stop_rec.set()
            audio = await rec_task

            # ── THINKING ───────────────────────────────────────────────
            await send({"type": "state", "state": "thinking"})
            transcript = await asyncio.to_thread(stt.transcribe, audio)

            if not transcript:
                log.info("No speech detected")
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
            await send({"type": "state", "state": "speaking"})

            # ── SPEAKING (LLM stream → TTS per sentence) ───────────────
            stop_speaking = threading.Event()

            def _run_pipeline() -> None:
                try:
                    for sentence in llm.chat(transcript):
                        if stop_speaking.is_set():
                            break
                        send_from_thread({"type": "sentence", "text": sentence})
                        tts.speak_streaming(sentence, amplitude_cb, stop_speaking)
                        send_from_thread({"type": "amplitude", "value": 0.0})
                except RuntimeError as exc:
                    log.error("Pipeline error: %s", exc)
                    send_from_thread({"type": "sentence",
                                      "text": "My brain is napping — try again!"})

            await asyncio.to_thread(_run_pipeline)
            await send({"type": "state", "state": "idle"})

    except websockets.ConnectionClosed:
        log.info("Client disconnected")


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

async def _main() -> None:
    config = Config.load("config.yaml")

    log.info("Loading pipeline models…")
    stt = STTPipeline(config)
    tts = TTSPipeline(config)
    llm = LLMPipeline(config)

    log.info("Nova WebSocket server → ws://%s:%d", HOST, PORT)

    async def _handler(ws):
        await _session(ws, config, stt, llm, tts)

    async with websockets.serve(_handler, HOST, PORT):
        await asyncio.Future()   # run forever


if __name__ == "__main__":
    asyncio.run(_main())
