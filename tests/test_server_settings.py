"""Tests for the Settings panel backend: voice list, set_voice, persistence."""
from __future__ import annotations

import json
from unittest.mock import MagicMock, patch

import numpy as np
import pytest

from app.pipeline.llm import LLMPipeline
from app.pipeline.stt import STTPipeline
from app.pipeline.tts import TTSPipeline
from app.server import _session, AVAILABLE_VOICES, _VOICE_IDS
from tests.conftest import MockWebSocket


DUMMY_AUDIO = np.zeros(16_000, dtype=np.float32)


def _mock_stt() -> MagicMock:
    stt = MagicMock(spec=STTPipeline)
    stt.transcribe.return_value = "hello"
    return stt


def _mock_llm() -> MagicMock:
    llm = MagicMock(spec=LLMPipeline)
    llm.chat.side_effect = lambda _t: iter(["Hi!"])
    return llm


def _mock_tts(reload_ok: bool = True, current: str = "en_US-kristin-medium") -> MagicMock:
    tts = MagicMock(spec=TTSPipeline)
    tts.reload_voice.return_value = reload_ok
    # spec=TTSPipeline exposes current_voice as a property; set it explicitly
    type(tts).current_voice = property(lambda self: current)
    tts.speak_streaming.side_effect = lambda t, cb=None, stop=None: cb(0.0) if cb else None
    return tts


@pytest.fixture(autouse=True)
def _no_mic():
    with patch("app.server._record", return_value=DUMMY_AUDIO):
        yield


# ── on-connect settings message ────────────────────────────────────────────

class TestSettingsOnConnect:
    async def test_settings_message_sent_with_voices_and_level(self, base_config):
        ws = MockWebSocket([])
        await _session(ws, base_config, _mock_stt(), _mock_llm(), _mock_tts())
        s = ws.sent_of_type("settings")
        assert len(s) == 1
        assert s[0]["voices"] == AVAILABLE_VOICES
        assert s[0]["level"] == base_config.child.level
        assert "voice" in s[0]

    async def test_voice_list_only_permissive_licenses(self):
        # Guard against re-adding the research-only lessac voice.
        ids = {v["id"] for v in AVAILABLE_VOICES}
        assert "en_US-lessac-medium" not in ids
        assert "en_US-kristin-medium" in ids


# ── set_voice handler ──────────────────────────────────────────────────────

class TestSetVoice:
    async def test_valid_voice_triggers_reload_and_persists(self, base_config):
        ws = MockWebSocket([json.dumps({"type": "set_voice",
                                        "voice": "en_US-joe-medium"})])
        tts = _mock_tts(reload_ok=True, current="en_US-joe-medium")
        with patch("app.server.save_setting") as save:
            await _session(ws, base_config, _mock_stt(), _mock_llm(), tts)
        tts.reload_voice.assert_called_once_with("en_US-joe-medium")
        save.assert_any_call("voice", "en_US-joe-medium")
        statuses = ws.sent_of_type("voice_status")
        assert statuses[0]["state"] == "loading"
        assert statuses[-1]["state"] == "ready"

    async def test_unknown_voice_ignored(self, base_config):
        ws = MockWebSocket([json.dumps({"type": "set_voice",
                                        "voice": "../evil"})])
        tts = _mock_tts()
        with patch("app.server.save_setting") as save:
            await _session(ws, base_config, _mock_stt(), _mock_llm(), tts)
        tts.reload_voice.assert_not_called()
        save.assert_not_called()
        assert ws.sent_of_type("voice_status") == []

    async def test_reload_failure_reports_error_and_no_persist(self, base_config):
        ws = MockWebSocket([json.dumps({"type": "set_voice",
                                        "voice": "en_US-norman-medium"})])
        tts = _mock_tts(reload_ok=False, current="en_US-kristin-medium")
        with patch("app.server.save_setting") as save:
            await _session(ws, base_config, _mock_stt(), _mock_llm(), tts)
        # Attempted, but failed → no voice persisted
        for c in save.call_args_list:
            assert c.args[0] != "voice"
        assert ws.sent_of_type("voice_status")[-1]["state"] == "error"


# ── set_level now persists ─────────────────────────────────────────────────

class TestLevelPersistence:
    async def test_set_level_persists(self, base_config):
        ws = MockWebSocket([json.dumps({"type": "set_level", "level": "C1"})])
        with patch("app.server.save_setting") as save:
            await _session(ws, base_config, _mock_stt(), _mock_llm(), _mock_tts())
        save.assert_any_call("level", "C1")
