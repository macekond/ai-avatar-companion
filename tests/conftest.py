"""Shared pytest fixtures and helpers used across the test suite."""
from __future__ import annotations

import json
import pytest

from app.config import Config, ChildConfig, PersonalityConfig, LLMConfig


# ── Shared config fixture ─────────────────────────────────────────────────

@pytest.fixture
def base_config() -> Config:
    """Minimal in-memory Config that avoids touching config.yaml."""
    config = Config()
    config.child = ChildConfig(name="TestKid", level="A")
    config.personality = PersonalityConfig(
        avatar_name="TestAvatar",
        system_prompt="Hi {child_name}! I am {avatar_name}.",
    )
    config.models.llm = LLMConfig(
        conversation_buffer_exchanges=6,
        max_response_tokens=80,
        temperature=0.7,
    )
    return config


# ── Fake microphone recorder ───────────────────────────────────────────────

def make_fake_recorder(audio=None):
    """Stand-in for app.server._MicRecorder — no real mic.

    `_session` builds the recorder itself, so tests patch app.server._MicRecorder
    with `return_value=make_fake_recorder(...)`. start()/close() are no-ops and
    stop() yields the fixed audio the test wants transcribed.
    """
    import numpy as np
    from unittest.mock import MagicMock

    rec = MagicMock()
    rec.stop.return_value = (
        np.zeros(16_000, dtype=np.float32) if audio is None else audio
    )
    return rec


# ── MockWebSocket ──────────────────────────────────────────────────────────

class MockWebSocket:
    """Simulates a websockets.ServerConnection for testing _session().

    Incoming messages (client → server) are queued upfront.
    Both the `async for ws:` iterator and explicit `await ws.recv()` calls
    consume from the same ordered message list, which matches how a real
    WebSocket works.

    Outgoing messages (server → client) are collected in `self.sent`.
    """

    def __init__(self, messages: list[str]) -> None:
        self.sent: list[dict] = []
        self._messages = list(messages)
        self._pos = 0

    def _next_raw(self) -> str | None:
        if self._pos < len(self._messages):
            msg = self._messages[self._pos]
            self._pos += 1
            return msg
        return None

    async def send(self, data: str) -> None:
        self.sent.append(json.loads(data))

    async def recv(self) -> str:
        """Explicit recv() call — used inside the async-for loop for ptt_stop."""
        import asyncio
        msg = self._next_raw()
        if msg is None:
            # No more messages: simulate a connection timeout so the server
            # hits the asyncio.TimeoutError branch and returns to idle.
            raise asyncio.TimeoutError
        return msg

    # Match the real websockets.ServerConnection interface: __aiter__ is an
    # async generator, and there is deliberately NO direct __anext__ method —
    # server code must use recv(). (A ws.__anext__() call once passed tests
    # against this mock and crashed against real connections.)
    def __aiter__(self):
        return self._iterate()

    async def _iterate(self):
        while True:
            msg = self._next_raw()
            if msg is None:
                return
            yield msg

    # ── Convenience accessors ──────────────────────────────────────────

    def sent_states(self) -> list[str]:
        return [m["state"] for m in self.sent if m.get("type") == "state"]

    def sent_sentences(self) -> list[str]:
        return [m["text"] for m in self.sent if m.get("type") == "sentence"]

    def sent_of_type(self, msg_type: str) -> list[dict]:
        return [m for m in self.sent if m.get("type") == msg_type]
