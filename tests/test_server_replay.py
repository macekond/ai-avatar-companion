"""Replay: re-speak a stored Nova line on demand (no new turn / memory)."""
from __future__ import annotations

import json
import time
from unittest.mock import MagicMock, patch

import numpy as np
import pytest

from app.memory import MemoryManager, ChildMemory, ChildProfile
from app.pipeline.llm import LLMPipeline
from app.pipeline.stt import STTPipeline
from app.pipeline.tts import TTSPipeline
from app.server import _session
from app.transcript import TranscriptStore
from tests.conftest import MockWebSocket, make_fake_recorder

DUMMY_AUDIO = np.zeros(16_000, dtype=np.float32)


def _mock_stt(t=""):
    stt = MagicMock(spec=STTPipeline)
    stt.transcribe.return_value = t
    return stt


def _mock_llm(sentences=None):
    llm = MagicMock(spec=LLMPipeline)
    llm.chat.side_effect = lambda _t: iter(sentences or ["hi"])
    return llm


def _mock_tts():
    tts = MagicMock(spec=TTSPipeline)
    tts.speak_streaming.side_effect = lambda t, cb=None, stop=None: cb(0.0) if cb else None
    return tts


@pytest.fixture(autouse=True)
def _no_mic():
    with patch("app.server._MicRecorder",
               return_value=make_fake_recorder(DUMMY_AUDIO)):
        yield


class TestReplay:
    async def test_replay_speaks_text_and_returns_idle(self, base_config):
        tts = _mock_tts()
        ws = MockWebSocket([json.dumps({"type": "replay", "text": "Hello again"})])
        await _session(ws, base_config, _mock_stt(), _mock_llm(), tts)
        spoken = [c.args[0] for c in tts.speak_streaming.call_args_list]
        assert "Hello again" in spoken
        assert ws.sent_states()[-1] == "idle"
        assert "speaking" in ws.sent_states()

    async def test_replay_emits_sentence_with_text(self, base_config):
        ws = MockWebSocket([json.dumps({"type": "replay", "text": "Say this"})])
        await _session(ws, base_config, _mock_stt(), _mock_llm(), _mock_tts())
        assert any(s == "Say this" for s in ws.sent_sentences())

    async def test_replay_creates_no_conversation_turn(self, base_config):
        ws = MockWebSocket([json.dumps({"type": "replay", "text": "x"})])
        await _session(ws, base_config, _mock_stt(), _mock_llm(), _mock_tts())
        assert ws.sent_of_type("conversation_turn") == []

    async def test_replay_does_not_persist_or_extract(self, base_config, tmp_path):
        profiles = tmp_path / "profiles"
        profiles.mkdir()
        base_config.memory.profiles_dir = str(profiles)
        mem = MemoryManager(profiles, "lily")
        mem.save(ChildMemory(profile=ChildProfile(name="Lily")))
        fake_ex = MagicMock()
        with patch("app.server.MemoryExtractor", return_value=fake_ex):
            ws = MockWebSocket([json.dumps({"type": "replay", "text": "old line"})])
            await _session(ws, base_config, _mock_stt(), _mock_llm(), _mock_tts(), mem)
        fake_ex.extract.assert_not_called()
        assert TranscriptStore(tmp_path / "transcripts", "lily").load() == []

    async def test_replay_empty_text_ignored(self, base_config):
        # Send 'start' so the greeting fires — an ignored replay must add
        # no second speaking cycle on top of that greeting.
        tts = _mock_tts()
        ws = MockWebSocket([
            json.dumps({"type": "start"}),
            json.dumps({"type": "replay", "text": "   "}),
        ])
        await _session(ws, base_config, _mock_stt(), _mock_llm(), tts)
        assert ws.sent_states().count("speaking") == 1     # greeting only
        assert tts.speak_streaming.call_count == 1         # greeting only

    async def test_replay_missing_text_ignored(self, base_config):
        ws = MockWebSocket([
            json.dumps({"type": "start"}),
            json.dumps({"type": "replay"}),
        ])
        await _session(ws, base_config, _mock_stt(), _mock_llm(), _mock_tts())
        assert ws.sent_states().count("speaking") == 1     # greeting only

    async def test_stop_speak_interrupts_replay(self, base_config):
        finished = []

        def _slow(text, cb=None, stop=None):
            for _ in range(20):
                if stop is not None and stop.is_set():
                    return
                time.sleep(0.01)
            finished.append(text)

        tts = MagicMock(spec=TTSPipeline)
        tts.speak_streaming.side_effect = _slow
        ws = MockWebSocket([
            json.dumps({"type": "replay", "text": "long line"}),
            json.dumps({"type": "stop_speak"}),
        ])
        await _session(ws, base_config, _mock_stt(), _mock_llm(), tts)
        # The greeting (spoken without barge-in) may complete; the replayed line
        # must be interrupted before it finishes.
        assert "long line" not in finished
        assert ws.sent_states()[-1] == "idle"
