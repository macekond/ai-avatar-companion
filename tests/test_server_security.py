"""Regression tests for the security-hardening fixes.

Covers:
  - Server-side slug sanitization (path traversal via `switch_profile`)
  - WebSocket Origin allow-list (cross-origin pages must be rejected)
  - Pending extraction tasks drained before session teardown
"""
from __future__ import annotations

import json
from pathlib import Path
from unittest.mock import MagicMock, patch

import numpy as np
import pytest
import websockets

from app.memory import MemoryManager, ChildMemory, ChildProfile
from app.pipeline.llm import LLMPipeline
from app.pipeline.stt import STTPipeline
from app.pipeline.tts import TTSPipeline
from app.server import _session, ALLOWED_ORIGINS
from app.telemetry import TelemetrySession
from tests.conftest import MockWebSocket, make_fake_recorder


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


def _mock_tts() -> MagicMock:
    tts = MagicMock(spec=TTSPipeline)

    def _speak(text, amp_cb, stop_event=None):
        amp_cb(0.5)
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
    with patch("app.server._MicRecorder",
               return_value=make_fake_recorder(DUMMY_AUDIO)):
        yield


def _read_events(log_file: Path) -> list[dict]:
    return [json.loads(line) for line in log_file.read_text().splitlines() if line.strip()]


# ── Slug sanitization (path traversal via switch_profile) ──────────────────

class TestSlugSanitization:
    """A client-supplied slug must not escape the profiles directory."""

    async def test_traversal_slug_stays_inside_profiles_dir(
        self, base_config, tmp_path
    ):
        profiles_dir = tmp_path / "profiles"
        profiles_dir.mkdir()
        base_config.memory.profiles_dir = str(profiles_dir)

        mem_mgr = MemoryManager(profiles_dir, "lily")
        mem_mgr.save(ChildMemory(profile=ChildProfile(name="Lily")))

        evil = "../../../pwned"
        ws = MockWebSocket([json.dumps({"type": "switch_profile", "slug": evil})])
        await _session(
            ws, base_config, _mock_stt(), _mock_llm(), _mock_tts(), mem_mgr,
        )

        # Nothing must exist above the profiles directory.
        outside = list(tmp_path.glob("pwned*")) + list(tmp_path.parent.glob("pwned*"))
        assert not outside, f"traversal escaped: {outside}"

        # And every JSON file that DID land somewhere is inside profiles_dir.
        for p in tmp_path.rglob("*.json"):
            assert profiles_dir in p.parents or p.parent == profiles_dir

    async def test_traversal_slug_treated_as_flat_name(
        self, base_config, tmp_path
    ):
        profiles_dir = tmp_path / "profiles"
        profiles_dir.mkdir()
        base_config.memory.profiles_dir = str(profiles_dir)

        mem_mgr = MemoryManager(profiles_dir, "lily")
        mem_mgr.save(ChildMemory(profile=ChildProfile(name="Lily")))

        ws = MockWebSocket([json.dumps({"type": "switch_profile", "slug": "../foo"})])
        await _session(
            ws, base_config, _mock_stt(), _mock_llm(), _mock_tts(), mem_mgr,
        )

        # The active profile reported to the client must not contain path chars.
        profile_msgs = ws.sent_of_type("profiles")
        actives = [m.get("active") for m in profile_msgs]
        for a in actives:
            assert a is not None
            assert "/" not in a and ".." not in a

    async def test_non_string_slug_ignored(self, base_config, tmp_path):
        """A malformed slug payload (list, dict, int) must not crash the session."""
        profiles_dir = tmp_path / "profiles"
        profiles_dir.mkdir()
        base_config.memory.profiles_dir = str(profiles_dir)

        mem_mgr = MemoryManager(profiles_dir, "lily")
        mem_mgr.save(ChildMemory(profile=ChildProfile(name="Lily")))

        ws = MockWebSocket([
            json.dumps({"type": "switch_profile", "slug": ["../x"]}),
            json.dumps({"type": "switch_profile", "slug": 42}),
        ])
        await _session(
            ws, base_config, _mock_stt(), _mock_llm(), _mock_tts(), mem_mgr,
        )
        # Session completed without crashing; still exactly one profiles msg
        # (the on-connect one — both switches were ignored).
        assert len(ws.sent_of_type("profiles")) == 1


# ── Origin allow-list ───────────────────────────────────────────────────────

class TestOriginAllowList:
    """The WebSocket server must reject browser connections from
    non-allow-listed origins, including the forgeable `Origin: null`."""

    @pytest.fixture
    async def echo_server(self):
        async def _handler(ws):
            async for msg in ws:
                await ws.send(msg)

        server = await websockets.serve(
            _handler, "localhost", 0, origins=ALLOWED_ORIGINS,
        )
        port = server.sockets[0].getsockname()[1]
        try:
            yield f"ws://localhost:{port}"
        finally:
            server.close()
            await server.wait_closed()

    async def test_allowed_origin_connects(self, echo_server):
        async with websockets.connect(
            echo_server, origin="http://localhost:5173",
        ) as ws:
            await ws.send("ping")
            assert await ws.recv() == "ping"

    async def test_no_origin_connects(self, echo_server):
        """Non-browser clients send no Origin header and are allowed."""
        async with websockets.connect(echo_server) as ws:
            await ws.send("ping")
            assert await ws.recv() == "ping"

    async def test_null_origin_rejected(self, echo_server):
        """`Origin: null` is what sandboxed iframes on arbitrary websites
        send — it must be rejected, not allow-listed."""
        with pytest.raises(websockets.exceptions.InvalidStatus) as exc_info:
            await websockets.connect(echo_server, origin="null")
        assert exc_info.value.response.status_code == 403

    async def test_cross_origin_rejected(self, echo_server):
        with pytest.raises(websockets.exceptions.InvalidStatus) as exc_info:
            await websockets.connect(echo_server, origin="https://evil.example")
        assert exc_info.value.response.status_code == 403

    def test_null_not_in_allow_list(self):
        """Belt-and-braces: the literal string 'null' must never be added."""
        assert "null" not in ALLOWED_ORIGINS


# ── Pending extraction tasks drained before teardown ───────────────────────

class TestPendingTasksAwaited:
    async def test_last_turn_telemetry_survives_session_end(
        self, base_config, tmp_path
    ):
        """The last turn's telemetry.log_turn happens inside a background
        extraction task. If pending tasks aren't awaited before
        telemetry.end(), the turn's entry is silently dropped."""
        profiles_dir = tmp_path / "profiles"
        profiles_dir.mkdir()
        base_config.memory.profiles_dir = str(profiles_dir)

        mem_mgr = MemoryManager(profiles_dir, "lily")
        mem_mgr.save(ChildMemory(profile=ChildProfile(name="Lily")))
        telemetry = TelemetrySession(tmp_path / "logs", "lily")

        from app.memory_extractor import ExtractionResult

        def _fake_extract(_transcript, _reply):
            import time
            time.sleep(0.05)   # keep the task in flight past session end
            return ExtractionResult(topic="park", problem_raw=None, engaged=True)

        fake_extractor = MagicMock()
        fake_extractor.extract.side_effect = _fake_extract

        with patch("app.server.MemoryExtractor", return_value=fake_extractor):
            ws = MockWebSocket(_ptt_turn())
            await _session(
                ws, base_config, _mock_stt(), _mock_llm(), _mock_tts(),
                mem_mgr, telemetry,
            )

        events = _read_events(telemetry.log_file)
        turns = [e for e in events if e["event"] == "turn"]
        assert turns, (
            "turn event missing — pending extraction task was not awaited "
            "before telemetry.end()"
        )
        assert turns[0]["topic"] == "park"

    async def test_session_end_aggregates_include_last_turn(
        self, base_config, tmp_path
    ):
        profiles_dir = tmp_path / "profiles"
        profiles_dir.mkdir()
        base_config.memory.profiles_dir = str(profiles_dir)

        mem_mgr = MemoryManager(profiles_dir, "lily")
        mem_mgr.save(ChildMemory(profile=ChildProfile(name="Lily")))
        telemetry = TelemetrySession(tmp_path / "logs", "lily")

        from app.memory_extractor import ExtractionResult

        def _fake_extract(_t, _r):
            import time
            time.sleep(0.03)
            return ExtractionResult(topic=None, problem_raw=None, engaged=True)

        fake = MagicMock()
        fake.extract.side_effect = _fake_extract

        with patch("app.server.MemoryExtractor", return_value=fake):
            ws = MockWebSocket(_ptt_turn())
            await _session(
                ws, base_config, _mock_stt(), _mock_llm(), _mock_tts(),
                mem_mgr, telemetry,
            )

        events = _read_events(telemetry.log_file)
        end = next(e for e in events if e["event"] == "session_end")
        assert end["turns"] == 1
