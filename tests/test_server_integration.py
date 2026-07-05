"""Integration tests for the WebSocket session handler (app/server.py).

_session() is tested directly with:
  - MockWebSocket (from conftest) for the WebSocket interface
  - MagicMock instances for the three pipeline components
  - app.server._record patched to avoid touching the sounddevice mic

No real Ollama, mic, or speakers required.
"""
from __future__ import annotations

import json
import numpy as np
import pytest
from unittest.mock import MagicMock, patch

from app.config import Config
from app.pipeline.llm import LLMPipeline
from app.pipeline.stt import STTPipeline
from app.pipeline.tts import TTSPipeline
from app.server import _session
from tests.conftest import MockWebSocket


# ── Helpers ────────────────────────────────────────────────────────────────

DUMMY_AUDIO = np.zeros(16_000, dtype=np.float32)   # 1 s of silence


def mock_stt(transcript: str = "I went to the park") -> MagicMock:
    stt = MagicMock(spec=STTPipeline)
    stt.transcribe.return_value = transcript
    return stt


def mock_llm(sentences: list[str] | None = None) -> MagicMock:
    if sentences is None:
        sentences = ["That sounds fun!"]
    llm = MagicMock(spec=LLMPipeline)
    # Use side_effect so each chat() call gets a fresh iterator
    llm.chat.side_effect = lambda _transcript: iter(sentences)
    return llm


def mock_tts() -> MagicMock:
    return MagicMock(spec=TTSPipeline)


def ptt_turn(*extra_msgs: dict) -> list[str]:
    """Build messages for one complete PTT turn, optionally followed by extras."""
    msgs = [
        json.dumps({"type": "ptt_start"}),
        json.dumps({"type": "ptt_stop"}),
    ]
    for m in extra_msgs:
        msgs.append(json.dumps(m))
    return msgs


@pytest.fixture(autouse=True)
def patch_record():
    """Patch _record for every test in this module — no mic needed."""
    with patch("app.server._record", return_value=DUMMY_AUDIO):
        yield


# ── On-connect behaviour ───────────────────────────────────────────────────

class TestOnConnect:
    async def test_first_message_is_init(self, base_config):
        ws = MockWebSocket([])
        await _session(ws, base_config, mock_stt(), mock_llm(), mock_tts())
        assert ws.sent[0]["type"] == "init"

    async def test_init_carries_correct_level(self, base_config):
        ws = MockWebSocket([])
        base_config.child.level = "B"
        await _session(ws, base_config, mock_stt(), mock_llm(), mock_tts())
        assert ws.sent[0] == {"type": "init", "level": "B"}

    async def test_greeting_contains_child_name(self, base_config):
        ws = MockWebSocket([])
        await _session(ws, base_config, mock_stt(), mock_llm(), mock_tts())
        assert any("TestKid" in s for s in ws.sent_sentences())

    async def test_greeting_state_is_speaking(self, base_config):
        ws = MockWebSocket([])
        await _session(ws, base_config, mock_stt(), mock_llm(), mock_tts())
        # The very first state change after init should be 'speaking' (greeting)
        assert ws.sent_states()[0] == "speaking"

    async def test_session_ends_in_idle(self, base_config):
        ws = MockWebSocket([])
        await _session(ws, base_config, mock_stt(), mock_llm(), mock_tts())
        assert ws.sent_states()[-1] == "idle"

    async def test_tts_called_for_greeting(self, base_config):
        ws = MockWebSocket([])
        tts = mock_tts()
        await _session(ws, base_config, mock_stt(), mock_llm(), tts)
        tts.speak_streaming.assert_called()


# ── Full PTT turn ──────────────────────────────────────────────────────────

class TestPTTTurn:
    async def test_ptt_start_triggers_listening(self, base_config):
        ws = MockWebSocket(ptt_turn())
        await _session(ws, base_config, mock_stt(), mock_llm(), mock_tts())
        assert "listening" in ws.sent_states()

    async def test_ptt_stop_triggers_thinking(self, base_config):
        ws = MockWebSocket(ptt_turn())
        await _session(ws, base_config, mock_stt(), mock_llm(), mock_tts())
        assert "thinking" in ws.sent_states()

    async def test_transcript_forwarded_to_client(self, base_config):
        ws = MockWebSocket(ptt_turn())
        await _session(ws, base_config, mock_stt("I played football"), mock_llm(), mock_tts())
        transcripts = [m["text"] for m in ws.sent_of_type("transcript")]
        assert "I played football" in transcripts

    async def test_llm_response_sent_as_sentence(self, base_config):
        ws = MockWebSocket(ptt_turn())
        await _session(ws, base_config, mock_stt(), mock_llm(["Wow, football!"]), mock_tts())
        assert any("football" in s for s in ws.sent_sentences())

    async def test_tts_called_once_per_llm_sentence(self, base_config):
        ws = MockWebSocket(ptt_turn())
        tts = mock_tts()
        await _session(ws, base_config, mock_stt(), mock_llm(["S1.", "S2.", "S3."]), tts)
        # 1 greeting + 3 from LLM = 4 total speak_streaming calls
        assert tts.speak_streaming.call_count == 4

    async def test_state_sequence_is_correct(self, base_config):
        ws = MockWebSocket(ptt_turn())
        await _session(ws, base_config, mock_stt(), mock_llm(), mock_tts())
        states = ws.sent_states()
        # Find the PTT-turn states (after initial speaking/idle from greeting)
        def first_index(lst, value):
            return next((i for i, v in enumerate(lst) if v == value), -1)
        li = first_index(states, "listening")
        th = first_index(states[li:], "thinking") + li
        sp = first_index(states[th:], "speaking") + th
        assert li < th < sp
        assert states[-1] == "idle"

    async def test_llm_receives_the_transcribed_text(self, base_config):
        ws = MockWebSocket(ptt_turn())
        stt = mock_stt("I love cats")
        llm = mock_llm()
        await _session(ws, base_config, stt, llm, mock_tts())
        llm.chat.assert_called_once_with("I love cats")

    async def test_two_consecutive_turns(self, base_config):
        messages = ptt_turn() + ptt_turn()
        ws = MockWebSocket(messages)
        llm = mock_llm()
        await _session(ws, base_config, mock_stt(), llm, mock_tts())
        assert llm.chat.call_count == 2

    async def test_amplitude_reset_sent_after_each_sentence(self, base_config):
        ws = MockWebSocket(ptt_turn())
        await _session(ws, base_config, mock_stt(), mock_llm(["Hello!"]), mock_tts())
        amp_msgs = ws.sent_of_type("amplitude")
        zero_resets = [m for m in amp_msgs if m.get("value") == 0.0]
        assert len(zero_resets) >= 1


# ── Empty transcript (didn't catch that) ──────────────────────────────────

class TestEmptyTranscript:
    async def test_empty_transcript_triggers_didnt_catch(self, base_config):
        ws = MockWebSocket(ptt_turn())
        await _session(ws, base_config, mock_stt(""), mock_llm(), mock_tts())
        assert "didnt_catch" in ws.sent_states()

    async def test_returns_to_idle_after_didnt_catch(self, base_config):
        ws = MockWebSocket(ptt_turn())
        await _session(ws, base_config, mock_stt(""), mock_llm(), mock_tts())
        states = ws.sent_states()
        dc_idx = states.index("didnt_catch")
        assert "idle" in states[dc_idx + 1:]

    async def test_llm_not_called_for_empty_transcript(self, base_config):
        ws = MockWebSocket(ptt_turn())
        llm = mock_llm()
        await _session(ws, base_config, mock_stt(""), llm, mock_tts())
        llm.chat.assert_not_called()

    async def test_tts_speaks_sorry_message(self, base_config):
        ws = MockWebSocket(ptt_turn())
        tts = mock_tts()
        await _session(ws, base_config, mock_stt(""), mock_llm(), tts)
        # Two calls: greeting + didnt_catch message
        assert tts.speak_streaming.call_count == 2


# ── Level switching ────────────────────────────────────────────────────────

class TestSetLevel:
    async def test_set_level_calls_llm_set_level(self, base_config):
        ws = MockWebSocket([json.dumps({"type": "set_level", "level": "C2"})])
        llm = mock_llm()
        await _session(ws, base_config, mock_stt(), llm, mock_tts())
        llm.set_level.assert_called_once_with("C2")

    async def test_set_level_does_not_emit_state_change(self, base_config):
        ws = MockWebSocket([json.dumps({"type": "set_level", "level": "B"})])
        await _session(ws, base_config, mock_stt(), mock_llm(), mock_tts())
        # Greeting produces speaking + idle; set_level should add nothing
        assert ws.sent_states() == ["speaking", "idle"]

    async def test_set_level_then_ptt_uses_new_level(self, base_config):
        """After set_level, the next PTT turn should call LLM (level was updated)."""
        messages = [
            json.dumps({"type": "set_level", "level": "C1"}),
            *ptt_turn(),
        ]
        ws = MockWebSocket(messages)
        llm = mock_llm()
        await _session(ws, base_config, mock_stt(), llm, mock_tts())
        llm.set_level.assert_called_once_with("C1")
        llm.chat.assert_called_once()


# ── Non-ptt_start messages are ignored ────────────────────────────────────

class TestUnknownMessages:
    async def test_unknown_message_type_is_ignored(self, base_config):
        ws = MockWebSocket([json.dumps({"type": "ping", "data": "hello"})])
        # Should complete without errors or state changes beyond greeting
        await _session(ws, base_config, mock_stt(), mock_llm(), mock_tts())
        assert ws.sent_states() == ["speaking", "idle"]
