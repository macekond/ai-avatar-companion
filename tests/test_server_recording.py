"""Recording-lifetime tests for the WebSocket session (app/server.py).

The server used to open and close a fresh CoreAudio input stream on every PTT
turn. On macOS, repeatedly opening/closing the input device eventually wedges
it — the stream opens but its callback stops delivering frames — so the app
went permanently deaf a few minutes into a session (observed in the field:
~10 good turns, then every turn "didn't catch" forever).

The fix keeps ONE input stream open for the whole session and gates capture
with a flag, mirroring the CLI's `STTPipeline.record`. These tests pin that
invariant: the device is opened once per session, not once per turn.

They deliberately use the real `_MicRecorder` with a fake `sounddevice`, so
they measure how many times the stream is actually constructed.
"""
from __future__ import annotations

import json
import sys
from unittest.mock import MagicMock, patch

import numpy as np
import pytest

from app.pipeline.llm import LLMPipeline
from app.pipeline.stt import STTPipeline
from app.pipeline.tts import TTSPipeline
from app.server import _session
from tests.conftest import MockWebSocket


def _mock_stt(transcript: str = "I went to the park") -> MagicMock:
    stt = MagicMock(spec=STTPipeline)
    stt.transcribe.return_value = transcript
    return stt


def _mock_llm(sentences=None) -> MagicMock:
    sentences = sentences or ["That sounds fun!"]
    llm = MagicMock(spec=LLMPipeline)
    llm.chat.side_effect = lambda _t: iter(sentences)
    return llm


def _ptt_turn() -> list[str]:
    return [json.dumps({"type": "ptt_start"}), json.dumps({"type": "ptt_stop"})]


class _FakeInputStream:
    """Stand-in for sounddevice.InputStream that records how often it's built.

    Supports both the context-manager shape (the old per-turn code) and the
    start/stop/close shape (the persistent recorder), so the same test measures
    open-count regardless of which the implementation uses.
    """

    def __init__(self, opens: list, **kwargs) -> None:
        opens.append(kwargs)
        self._callback = kwargs.get("callback")

    def __enter__(self):
        return self

    def __exit__(self, *_a):
        return False

    def start(self):
        pass

    def stop(self):
        pass

    def close(self):
        pass


@pytest.fixture
def counting_sounddevice():
    """Install a fake `sounddevice` module and expose the list of opens."""
    opens: list = []
    fake = MagicMock()
    fake.InputStream.side_effect = lambda **kw: _FakeInputStream(opens, **kw)
    with patch.dict(sys.modules, {"sounddevice": fake}):
        yield opens


class TestInputStreamLifetime:
    async def test_input_device_opened_once_across_many_turns(
        self, base_config, counting_sounddevice
    ):
        ws = MockWebSocket(_ptt_turn() + _ptt_turn() + _ptt_turn())
        await _session(ws, base_config, _mock_stt(), _mock_llm(), MagicMock(spec=TTSPipeline))
        assert len(counting_sounddevice) == 1, (
            f"expected the mic stream to be opened once for the whole session, "
            f"got {len(counting_sounddevice)} opens (one per turn wedges the "
            f"CoreAudio device)"
        )
