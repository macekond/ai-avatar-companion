"""Regression tests for barge-in, active-level tracking, and first_audio_ms.

Covers:
  - Barge-in: `stop_speak` while speaking aborts playback
  - Messages arriving during the speaking phase are buffered, not swallowed
  - UI level changes reach telemetry (`active_level`)
  - `first_audio_ms` (release → first TTS frame) captured per turn
  - Profile switch drains in-flight extraction tasks (no cross-child leak)
"""
from __future__ import annotations

import json
import threading
import time
from pathlib import Path
from unittest.mock import MagicMock, patch

import numpy as np
import pytest

from app.memory import MemoryManager, ChildMemory, ChildProfile
from app.pipeline.llm import LLMPipeline
from app.pipeline.stt import STTPipeline
from app.pipeline.tts import TTSPipeline
from app.server import _session
from app.telemetry import TelemetrySession
from tests.conftest import MockWebSocket


DUMMY_AUDIO = np.zeros(16_000, dtype=np.float32)


# ── Local mock builders ─────────────────────────────────────────────────────

def _mock_stt(transcript: str = "I went to the park today with my friends") -> MagicMock:
    stt = MagicMock(spec=STTPipeline)
    stt.transcribe.return_value = transcript
    return stt


def _mock_llm(sentences: list[str] | None = None) -> MagicMock:
    if sentences is None:
        sentences = ["That sounds fun!"]
    llm = MagicMock(spec=LLMPipeline)
    llm.chat.side_effect = lambda _t: iter(sentences)
    return llm


def _mock_tts_with_amplitude(peak: float = 0.7, delay_s: float = 0.01) -> MagicMock:
    """TTS mock whose speak_streaming invokes the amplitude callback, so the
    server's first-audio timestamp path fires. A small delay is inserted so
    the elapsed-time truncation to int-ms is non-zero."""
    tts = MagicMock(spec=TTSPipeline)

    def _speak(text, amp_cb, stop_event=None):
        time.sleep(delay_s)
        amp_cb(peak)
        amp_cb(0.0)

    tts.speak_streaming.side_effect = _speak
    return tts


def _ptt_turn(*extra: dict) -> list[str]:
    msgs = [json.dumps({"type": "ptt_start"}), json.dumps({"type": "ptt_stop"})]
    for m in extra:
        msgs.append(json.dumps(m))
    return msgs


@pytest.fixture(autouse=True)
def _no_mic():
    with patch("app.server._record", return_value=DUMMY_AUDIO):
        yield


def _read_events(log_file: Path) -> list[dict]:
    return [json.loads(line) for line in log_file.read_text().splitlines() if line.strip()]


# ── Active level flows into telemetry ───────────────────────────────────────

class TestActiveLevelInTelemetry:
    async def test_set_level_reaches_turn_telemetry(self, base_config, tmp_path):
        base_config.child.level = "A"
        telemetry = TelemetrySession(tmp_path, "testkid")

        ws = MockWebSocket([
            json.dumps({"type": "set_level", "level": "C1"}),
            *_ptt_turn(),
        ])
        await _session(
            ws, base_config, _mock_stt(), _mock_llm(),
            _mock_tts_with_amplitude(), None, telemetry,
        )

        events = _read_events(telemetry.log_file)
        turns = [e for e in events if e["event"] == "turn"]
        assert turns, "expected at least one turn event"
        assert turns[0]["level"] == "C1", (
            f"level should reflect the UI's set_level, got {turns[0]['level']}"
        )


# ── first_audio_ms captured on first amplitude callback ────────────────────

class TestFirstAudioMs:
    async def test_first_audio_ms_recorded_when_tts_emits_amplitude(
        self, base_config, tmp_path
    ):
        telemetry = TelemetrySession(tmp_path, "testkid")

        ws = MockWebSocket(_ptt_turn())
        await _session(
            ws, base_config, _mock_stt(), _mock_llm(),
            _mock_tts_with_amplitude(peak=0.9),
            None, telemetry,
        )

        events = _read_events(telemetry.log_file)
        turn = next(e for e in events if e["event"] == "turn")
        assert "first_audio_ms" in turn
        assert turn["first_audio_ms"] > 0, (
            "first amplitude callback should have stamped first_audio_ms"
        )
        assert turn["first_audio_ms"] <= turn["total_ms"]

    async def test_first_audio_ms_zero_when_tts_silent(self, base_config, tmp_path):
        """If TTS never calls the amplitude callback, first_audio_ms is 0."""
        telemetry = TelemetrySession(tmp_path, "testkid")

        silent_tts = MagicMock(spec=TTSPipeline)
        silent_tts.speak_streaming.side_effect = lambda t, cb, stop=None: None

        ws = MockWebSocket(_ptt_turn())
        await _session(
            ws, base_config, _mock_stt(), _mock_llm(), silent_tts,
            None, telemetry,
        )

        events = _read_events(telemetry.log_file)
        turn = next(e for e in events if e["event"] == "turn")
        assert turn["first_audio_ms"] == 0


# ── Barge-in ────────────────────────────────────────────────────────────────

class TestBargeIn:
    async def test_stop_speak_aborts_playback_and_ends_turn(self, base_config):
        """A `stop_speak` message during the speaking phase aborts further
        sentence playback and returns the session to idle."""
        sentences_spoken: list[str] = []

        def _slow_speak(text, amp_cb, stop_event: threading.Event = None):
            for _ in range(20):   # up to ~200 ms, polling the stop event
                if stop_event is not None and stop_event.is_set():
                    return
                time.sleep(0.01)
            amp_cb(0.5)
            amp_cb(0.0)
            sentences_spoken.append(text)

        tts = MagicMock(spec=TTSPipeline)
        tts.speak_streaming.side_effect = _slow_speak

        ws = MockWebSocket(_ptt_turn({"type": "stop_speak"}))
        await _session(
            ws, base_config, _mock_stt(),
            _mock_llm(["Sentence one.", "Sentence two.", "Sentence three."]),
            tts,
        )

        assert len(sentences_spoken) < 3, (
            f"barge-in did not interrupt playback: spoken={sentences_spoken}"
        )
        assert ws.sent_states()[-1] == "idle"

    async def test_non_stop_message_during_speaking_is_not_swallowed(
        self, base_config
    ):
        """A `set_level` arriving while the avatar speaks must be buffered
        and processed by the main loop afterwards — not consumed by the
        barge-in watcher or misread as ptt_stop."""
        tts = _mock_tts_with_amplitude(delay_s=0.05)

        ws = MockWebSocket([
            *_ptt_turn({"type": "set_level", "level": "B"}),
            *_ptt_turn(),
        ])
        llm = _mock_llm()
        await _session(ws, base_config, _mock_stt(), llm, tts)

        # Both PTT turns completed (set_level wasn't eaten as a ptt_stop) …
        assert llm.chat.call_count == 2
        # … and the level change was actually applied.
        llm.set_level.assert_called_once_with("B")


# ── Profile switch drains in-flight extraction (no cross-child leak) ───────

class TestSwitchProfileDrainsPending:
    async def test_slow_extraction_cannot_leak_into_next_profile(
        self, base_config, tmp_path
    ):
        """A slow extraction task from child A must complete (or be
        abandoned) BEFORE child B's profile is loaded, so it can't reset
        the LLM's memory back to child A after the swap."""
        profiles_dir = tmp_path / "profiles"
        profiles_dir.mkdir()
        base_config.memory.profiles_dir = str(profiles_dir)

        mem_mgr = MemoryManager(profiles_dir, "lily")
        mem_mgr.save(ChildMemory(profile=ChildProfile(name="Lily")))
        MemoryManager(profiles_dir, "mia").save(
            ChildMemory(profile=ChildProfile(name="Mia", age=9))
        )

        from app.memory_extractor import ExtractionResult

        def _slow_extract(_t, _r):
            time.sleep(0.08)   # still in flight when switch_profile arrives
            return ExtractionResult(topic="dinosaurs", problem_raw=None, engaged=True)

        fake = MagicMock()
        fake.extract.side_effect = _slow_extract

        set_memory_names: list[str] = []
        llm = _mock_llm()
        llm.set_memory.side_effect = lambda m: set_memory_names.append(
            m.profile.name if m else None
        )

        with patch("app.server.MemoryExtractor", return_value=fake):
            ws = MockWebSocket([
                *_ptt_turn(),                                   # turn as Lily
                json.dumps({"type": "switch_profile", "slug": "mia"}),
            ])
            await _session(
                ws, base_config, _mock_stt(), llm,
                _mock_tts_with_amplitude(), mem_mgr,
            )

        # After Mia appears in set_memory calls, Lily must never reappear.
        assert "Mia" in set_memory_names
        mia_idx = set_memory_names.index("Mia")
        assert "Lily" not in set_memory_names[mia_idx + 1:], (
            f"stale extraction leaked Lily's memory after the switch: "
            f"{set_memory_names}"
        )
