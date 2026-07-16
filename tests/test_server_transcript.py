"""Tests for the transcript feature: conversation_turn + conversation_correction."""
from __future__ import annotations

import json
from unittest.mock import MagicMock, patch

import numpy as np
import pytest

from app.memory import MemoryManager, ChildMemory, ChildProfile
from app.memory_extractor import ExtractionResult
from app.pipeline.llm import LLMPipeline
from app.pipeline.stt import STTPipeline
from app.pipeline.tts import TTSPipeline
from app.server import _session
from app.transcript import TranscriptStore
from tests.conftest import MockWebSocket, make_fake_recorder


DUMMY_AUDIO = np.zeros(16_000, dtype=np.float32)


def _profile_dirs(tmp_path):
    """Return (profiles_dir, transcripts_dir) laid out as the app expects."""
    profiles = tmp_path / "profiles"
    profiles.mkdir(exist_ok=True)
    return profiles, tmp_path / "transcripts"


def _mem_mgr(tmp_path, base_config, slug="lily"):
    profiles, _ = _profile_dirs(tmp_path)
    base_config.memory.profiles_dir = str(profiles)
    mgr = MemoryManager(profiles, slug)
    mgr.save(ChildMemory(profile=ChildProfile(name=slug.capitalize())))
    return mgr


def _mock_stt(transcript: str) -> MagicMock:
    stt = MagicMock(spec=STTPipeline)
    stt.transcribe.return_value = transcript
    return stt


def _mock_llm(sentences: list[str]) -> MagicMock:
    llm = MagicMock(spec=LLMPipeline)
    llm.chat.side_effect = lambda _t: iter(sentences)
    return llm


def _mock_tts() -> MagicMock:
    tts = MagicMock(spec=TTSPipeline)
    tts.speak_streaming.side_effect = lambda t, cb=None, stop=None: cb(0.0) if cb else None
    return tts


def _ptt_turn(*extra: dict) -> list[str]:
    msgs = [json.dumps({"type": "ptt_start"}), json.dumps({"type": "ptt_stop"})]
    for m in extra:
        msgs.append(json.dumps(m))
    return msgs


@pytest.fixture(autouse=True)
def _no_mic():
    with patch("app.server._MicRecorder",
               return_value=make_fake_recorder(DUMMY_AUDIO)):
        yield


class TestConversationTurn:
    async def test_turn_emitted_with_you_and_nova(self, base_config):
        ws = MockWebSocket(_ptt_turn())
        await _session(ws, base_config, _mock_stt("I played football"),
                       _mock_llm(["That sounds fun!"]), _mock_tts())
        turns = ws.sent_of_type("conversation_turn")
        assert len(turns) == 1
        assert turns[0]["you"] == "I played football"
        assert turns[0]["nova"] == "That sounds fun!"
        assert turns[0]["id"] == 1

    async def test_no_turn_on_empty_transcript(self, base_config):
        ws = MockWebSocket(_ptt_turn())
        await _session(ws, base_config, _mock_stt(""),  # didn't-catch path
                       _mock_llm(["x"]), _mock_tts())
        assert ws.sent_of_type("conversation_turn") == []

    async def test_ids_increment_across_turns(self, base_config):
        ws = MockWebSocket(_ptt_turn() + _ptt_turn())
        await _session(ws, base_config, _mock_stt("hi there friend"),
                       _mock_llm(["Hello!"]), _mock_tts())
        ids = [t["id"] for t in ws.sent_of_type("conversation_turn")]
        assert ids == [1, 2]


class TestConversationCorrection:
    async def test_correction_emitted_with_parsed_problem(self, base_config, tmp_path):
        profiles = tmp_path / "profiles"
        profiles.mkdir()
        base_config.memory.profiles_dir = str(profiles)
        mem = MemoryManager(profiles, "lily")
        mem.save(ChildMemory(profile=ChildProfile(name="Lily")))

        fake = MagicMock()
        fake.extract.return_value = ExtractionResult(
            topic="school", problem_raw="past_tense: goed -> went", engaged=True)

        with patch("app.server.MemoryExtractor", return_value=fake):
            ws = MockWebSocket(_ptt_turn())
            await _session(ws, base_config, _mock_stt("I goed to school"),
                           _mock_llm(["You went to school!"]), _mock_tts(), mem)

        corrections = ws.sent_of_type("conversation_correction")
        assert len(corrections) == 1
        c = corrections[0]
        assert c["id"] == 1                     # matches the turn id
        assert c["kind"] == "past_tense"
        assert c["wrong"] == "goed"
        assert c["right"] == "went"

    async def test_no_correction_when_no_problem(self, base_config, tmp_path):
        profiles = tmp_path / "profiles"
        profiles.mkdir()
        base_config.memory.profiles_dir = str(profiles)
        mem = MemoryManager(profiles, "lily")
        mem.save(ChildMemory(profile=ChildProfile(name="Lily")))

        fake = MagicMock()
        fake.extract.return_value = ExtractionResult(
            topic="park", problem_raw=None, engaged=True)

        with patch("app.server.MemoryExtractor", return_value=fake):
            ws = MockWebSocket(_ptt_turn())
            await _session(ws, base_config, _mock_stt("I went to the park today"),
                           _mock_llm(["Nice!"]), _mock_tts(), mem)

        assert ws.sent_of_type("conversation_correction") == []
        # The turn itself is still emitted.
        assert len(ws.sent_of_type("conversation_turn")) == 1


class TestTranscriptPersistence:
    async def test_completed_turn_is_persisted_to_disk(self, base_config, tmp_path):
        _, transcripts = _profile_dirs(tmp_path)
        mem = _mem_mgr(tmp_path, base_config)
        ws = MockWebSocket(_ptt_turn())
        await _session(ws, base_config, _mock_stt("I played football"),
                       _mock_llm(["That sounds fun!"]), _mock_tts(), mem)

        stored = TranscriptStore(transcripts, "lily").load()
        assert len(stored) == 1
        assert stored[0]["you"] == "I played football"
        assert stored[0]["nova"] == "That sounds fun!"

    async def test_history_replayed_on_connect(self, base_config, tmp_path):
        _, transcripts = _profile_dirs(tmp_path)
        mem = _mem_mgr(tmp_path, base_config)
        TranscriptStore(transcripts, "lily").append_turn(1, "hi earlier", "hello!")

        ws = MockWebSocket([])   # no PTT — just connect
        await _session(ws, base_config, _mock_stt("x"), _mock_llm(["y"]),
                       _mock_tts(), mem)

        replayed = ws.sent_of_type("conversation_turn")
        assert any(t["you"] == "hi earlier" and t["nova"] == "hello!"
                   for t in replayed)
        # The UI list is cleared before replay so a reconnect can't double it up.
        assert ws.sent_of_type("conversation_reset")

    async def test_ids_continue_after_replayed_history(self, base_config, tmp_path):
        _, transcripts = _profile_dirs(tmp_path)
        mem = _mem_mgr(tmp_path, base_config)
        store = TranscriptStore(transcripts, "lily")
        store.append_turn(1, "old one", "r1")
        store.append_turn(2, "old two", "r2")

        ws = MockWebSocket(_ptt_turn())
        await _session(ws, base_config, _mock_stt("a brand new thing"),
                       _mock_llm(["Nice!"]), _mock_tts(), mem)

        # The live turn must not collide with replayed ids 1 and 2.
        live = [t for t in ws.sent_of_type("conversation_turn")
                if t["you"] == "a brand new thing"]
        assert len(live) == 1
        assert live[0]["id"] == 3
        assert store.last_id() == 3

    async def test_correction_is_persisted(self, base_config, tmp_path):
        _, transcripts = _profile_dirs(tmp_path)
        mem = _mem_mgr(tmp_path, base_config)
        fake = MagicMock()
        fake.extract.return_value = ExtractionResult(
            topic="school", problem_raw="past_tense: goed -> went", engaged=True)

        with patch("app.server.MemoryExtractor", return_value=fake):
            ws = MockWebSocket(_ptt_turn())
            await _session(ws, base_config, _mock_stt("I goed to school"),
                           _mock_llm(["You went to school!"]), _mock_tts(), mem)

        stored = TranscriptStore(transcripts, "lily").load()
        assert stored[0]["corrections"] == [
            {"kind": "past_tense", "wrong": "goed", "right": "went"}
        ]
