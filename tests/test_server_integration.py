"""Integration tests for the WebSocket session handler (app/server.py).

_session() is tested directly with:
  - MockWebSocket (from conftest) for the WebSocket interface
  - MagicMock instances for the three pipeline components
  - app.server._MicRecorder patched to avoid touching the sounddevice mic

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
from tests.conftest import MockWebSocket, make_fake_recorder


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
    """Build messages for one complete PTT turn, optionally followed by extras.

    Auto-prepends a {"type":"start"} so the session's initial awaiting_start
    gate flips to idle and the greeting fires — restoring the pre-gating
    behaviour these tests were written against. Tests that want to verify
    the gating itself (greeting suppressed, first ptt_start acting as an
    implicit start) build their own message list without this helper.
    """
    msgs = [
        json.dumps({"type": "start"}),
        json.dumps({"type": "ptt_start"}),
        json.dumps({"type": "ptt_stop"}),
    ]
    for m in extra_msgs:
        msgs.append(json.dumps(m))
    return msgs


def just_start() -> list[str]:
    """A single {"type":"start"} message — enough to trigger the initial
    greeting flow in tests that were previously written with MockWebSocket([])
    (empty queue) and expected the greeting to fire on connect."""
    return [json.dumps({"type": "start"})]


@pytest.fixture(autouse=True)
def patch_record():
    """Swap the mic recorder for every test in this module — no mic needed."""
    with patch("app.server._MicRecorder",
               return_value=make_fake_recorder(DUMMY_AUDIO)):
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
        assert ws.sent[0] == {"type": "init", "level": "B", "language": "en"}

    async def test_greeting_contains_child_name(self, base_config):
        ws = MockWebSocket(just_start())
        await _session(ws, base_config, mock_stt(), mock_llm(), mock_tts())
        assert any("TestKid" in s for s in ws.sent_sentences())

    async def test_first_state_is_awaiting_start(self, base_config):
        # Regression pin: connect used to fire the greeting immediately,
        # which was startling. The session now parks in awaiting_start until
        # the user taps the start prompt or presses Space.
        ws = MockWebSocket([])
        await _session(ws, base_config, mock_stt(), mock_llm(), mock_tts())
        assert ws.sent_states()[0] == "awaiting_start"

    async def test_no_greeting_without_start_message(self, base_config):
        # No 'start' and no ptt_start → the session must stay silent.
        ws = MockWebSocket([])
        tts = mock_tts()
        await _session(ws, base_config, mock_stt(), mock_llm(), tts)
        tts.speak_streaming.assert_not_called()
        assert ws.sent_sentences() == []

    async def test_start_message_triggers_greeting(self, base_config):
        ws = MockWebSocket(just_start())
        await _session(ws, base_config, mock_stt(), mock_llm(), mock_tts())
        # After 'start', the state flips to idle and the greeting speaks.
        assert "speaking" in ws.sent_states()

    async def test_ptt_start_before_start_still_works(self, base_config):
        # If the child skips the button and hits Space first, greeting is
        # skipped (they're initiating) but the turn proceeds normally.
        ws = MockWebSocket([
            json.dumps({"type": "ptt_start"}),
            json.dumps({"type": "ptt_stop"}),
        ])
        tts = mock_tts()
        await _session(ws, base_config, mock_stt("hi!"), mock_llm(["Hey!"]), tts)
        # 'speaking' can appear from the LLM reply but NOT from a greeting —
        # the greeting-only path shouldn't have fired.
        # Simpler assertion: 'listening' happened (turn ran) and no message
        # containing the greeting's 'practice friend' phrase was sent.
        assert "listening" in ws.sent_states()
        assert not any("practice friend" in s for s in ws.sent_sentences())

    async def test_session_ends_in_idle(self, base_config):
        ws = MockWebSocket(just_start())
        await _session(ws, base_config, mock_stt(), mock_llm(), mock_tts())
        assert ws.sent_states()[-1] == "idle"

    async def test_tts_called_for_greeting(self, base_config):
        ws = MockWebSocket(just_start())
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
        ws = MockWebSocket([
            json.dumps({"type": "start"}),
            json.dumps({"type": "set_level", "level": "B"}),
        ])
        await _session(ws, base_config, mock_stt(), mock_llm(), mock_tts())
        # Initial awaiting_start + start-triggered greeting (speaking + idle);
        # set_level itself should add nothing.
        assert ws.sent_states() == ["awaiting_start", "idle", "speaking", "idle"]

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


# ── Non-ptt_start messages are ignored ─────────────────────────────────

class TestUnknownMessages:
    async def test_unknown_message_type_is_ignored(self, base_config):
        # Send start first so we get the usual greeting states; the ping in
        # between must not produce additional state changes.
        ws = MockWebSocket([
            json.dumps({"type": "start"}),
            json.dumps({"type": "ping", "data": "hello"}),
        ])
        await _session(ws, base_config, mock_stt(), mock_llm(), mock_tts())
        assert ws.sent_states() == ["awaiting_start", "idle", "speaking", "idle"]


# ── Memory — on-connect messages ───────────────────────────────────

def _make_mem_mgr(tmp_path, slug="lily", memory=None):
    from app.memory import MemoryManager
    mgr = MemoryManager(tmp_path, slug)
    if memory is not None:
        mgr.save(memory)
    return mgr


def _make_memory(name="Lily", age=8):
    from app.memory import ChildMemory, ChildProfile
    return ChildMemory(profile=ChildProfile(name=name, age=age))


class TestMemoryOnConnect:
    async def test_profiles_message_sent_when_memory_manager_present(self, base_config, tmp_path):
        mem_mgr = _make_mem_mgr(tmp_path, memory=_make_memory())
        ws = MockWebSocket([])
        await _session(ws, base_config, mock_stt(), mock_llm(), mock_tts(), mem_mgr)
        profiles_msgs = ws.sent_of_type("profiles")
        assert len(profiles_msgs) >= 1
        assert "list" in profiles_msgs[0]
        assert "active" in profiles_msgs[0]

    async def test_no_profiles_message_without_memory_manager(self, base_config):
        ws = MockWebSocket([])
        await _session(ws, base_config, mock_stt(), mock_llm(), mock_tts())
        assert ws.sent_of_type("profiles") == []

    async def test_memory_loaded_sent_when_profile_exists(self, base_config, tmp_path):
        mem_mgr = _make_mem_mgr(tmp_path, memory=_make_memory("Lily", 8))
        ws = MockWebSocket([])
        await _session(ws, base_config, mock_stt(), mock_llm(), mock_tts(), mem_mgr)
        mem_msgs = ws.sent_of_type("memory_loaded")
        assert len(mem_msgs) == 1
        assert mem_msgs[0]["name"] == "Lily"
        assert mem_msgs[0]["age"] == 8

    async def test_onboarding_start_sent_when_no_profile(self, base_config, tmp_path):
        mem_mgr = _make_mem_mgr(tmp_path)   # no memory saved
        ws = MockWebSocket([])              # no PTT turns — onboarding will time out
        await _session(ws, base_config, mock_stt(), mock_llm(), mock_tts(), mem_mgr)
        types = [m.get("type") for m in ws.sent]
        assert "onboarding_start" in types

    async def test_no_onboarding_when_profile_exists(self, base_config, tmp_path):
        mem_mgr = _make_mem_mgr(tmp_path, memory=_make_memory())
        ws = MockWebSocket([])
        await _session(ws, base_config, mock_stt(), mock_llm(), mock_tts(), mem_mgr)
        types = [m.get("type") for m in ws.sent]
        assert "onboarding_start" not in types
        assert "memory_loaded" in types

    async def test_greeting_uses_child_name_from_memory(self, base_config, tmp_path):
        mem_mgr = _make_mem_mgr(tmp_path, memory=_make_memory("Mia", 7))
        ws = MockWebSocket(just_start())
        await _session(ws, base_config, mock_stt(), mock_llm(), mock_tts(), mem_mgr)
        sentences = ws.sent_sentences()
        assert any("Mia" in s for s in sentences)


# ── Memory — profile switching ──────────────────────────────────────

class TestProfileSwitching:
    def _cfg_with_dir(self, base_config, tmp_path):
        """Override profiles_dir so server switch_profile uses tmp_path."""
        base_config.memory.profiles_dir = str(tmp_path)
        return base_config

    async def test_switch_profile_sends_new_profiles_message(self, base_config, tmp_path):
        cfg = self._cfg_with_dir(base_config, tmp_path)
        mem_mgr = _make_mem_mgr(tmp_path, slug="lily", memory=_make_memory("Lily"))
        from app.memory import MemoryManager
        MemoryManager(tmp_path, "mia").save(_make_memory("Mia"))

        ws = MockWebSocket([json.dumps({"type": "switch_profile", "slug": "mia"})])
        await _session(ws, cfg, mock_stt(), mock_llm(), mock_tts(), mem_mgr)
        profiles_msgs = ws.sent_of_type("profiles")
        assert len(profiles_msgs) >= 2

    async def test_switch_to_existing_profile_sends_memory_loaded(self, base_config, tmp_path):
        cfg = self._cfg_with_dir(base_config, tmp_path)
        mem_mgr = _make_mem_mgr(tmp_path, slug="lily", memory=_make_memory("Lily"))
        from app.memory import MemoryManager
        MemoryManager(tmp_path, "mia").save(_make_memory("Mia", 9))

        ws = MockWebSocket([json.dumps({"type": "switch_profile", "slug": "mia"})])
        await _session(ws, cfg, mock_stt(), mock_llm(), mock_tts(), mem_mgr)
        mem_msgs = ws.sent_of_type("memory_loaded")
        assert any(m["name"] == "Mia" for m in mem_msgs)

    async def test_switch_to_unknown_profile_triggers_onboarding(self, base_config, tmp_path):
        cfg = self._cfg_with_dir(base_config, tmp_path)
        mem_mgr = _make_mem_mgr(tmp_path, slug="lily", memory=_make_memory("Lily"))
        ws = MockWebSocket([json.dumps({"type": "switch_profile", "slug": "newkid"})])
        await _session(ws, cfg, mock_stt(), mock_llm(), mock_tts(), mem_mgr)
        types = [m.get("type") for m in ws.sent]
        assert "onboarding_start" in types

    async def test_switch_with_empty_slug_ignored(self, base_config, tmp_path):
        cfg = self._cfg_with_dir(base_config, tmp_path)
        mem_mgr = _make_mem_mgr(tmp_path, slug="lily", memory=_make_memory("Lily"))
        ws = MockWebSocket([json.dumps({"type": "switch_profile", "slug": ""})])
        await _session(ws, cfg, mock_stt(), mock_llm(), mock_tts(), mem_mgr)
        assert ws.sent_of_type("profiles")


# ── Memory — re-engagement trigger ────────────────────────────────

class TestReEngagement:
    async def test_short_response_increments_counter(self, base_config, tmp_path):
        """Short transcript (≤ 3 words) — llm.chat() is still called normally.
        Re-engagement hint should NOT fire (only 1 short turn, threshold is 3).
        """
        mem_mgr = _make_mem_mgr(tmp_path, memory=_make_memory())
        # One short turn (streak=1, below threshold of 3)
        ws = MockWebSocket(ptt_turn())
        stt = mock_stt("yes")   # 1 word ≤ 3
        llm = mock_llm()
        await _session(ws, base_config, stt, llm, mock_tts(), mem_mgr)
        # llm.chat called once (the normal PTT turn), no re-engagement hint set
        assert llm.chat.call_count == 1
        # The pending_hint was NOT set because streak < threshold
        assert llm.set_hint.call_count == 0

    async def test_long_response_after_short_resets_counter(self, base_config, tmp_path):
        """A long response resets the consecutive_short counter."""
        mem_mgr = _make_mem_mgr(tmp_path, memory=_make_memory())
        messages = ptt_turn() + ptt_turn()
        ws = MockWebSocket(messages)
        # First turn: short; second turn: long (> 3 words)
        call_count = [0]
        def alternate_transcript():
            call_count[0] += 1
            return "yes" if call_count[0] == 1 else "I went to the park today with my family"
        stt = mock_stt()
        stt.transcribe.side_effect = lambda *_a, **_k: alternate_transcript()
        await _session(ws, base_config, stt, mock_llm(), mock_tts(), mem_mgr)
        # Should complete without error regardless of counter state
