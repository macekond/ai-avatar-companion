"""Tests for app/telemetry.py — session lifecycle, JSONL output, aggregates."""
from __future__ import annotations

import json
from datetime import date
from pathlib import Path

import pytest

from app.telemetry import TelemetrySession


def _make(tmp_path, slug="lily") -> TelemetrySession:
    return TelemetrySession(tmp_path, slug)


def _read_events(path: Path) -> list[dict]:
    return [json.loads(line) for line in path.read_text().splitlines() if line.strip()]


# ── File creation ──────────────────────────────────────────────────────────

class TestFileCreation:
    def test_start_creates_jsonl_file(self, tmp_path):
        s = _make(tmp_path)
        s.start()
        s.end()
        files = list(tmp_path.glob("*.jsonl"))
        assert len(files) == 1

    def test_filename_contains_date(self, tmp_path):
        s = _make(tmp_path)
        s.start()
        s.end()
        fname = list(tmp_path.glob("*.jsonl"))[0].name
        assert date.today().isoformat() in fname

    def test_filename_contains_slug(self, tmp_path):
        s = _make(tmp_path, slug="mia")
        s.start()
        s.end()
        fname = list(tmp_path.glob("*.jsonl"))[0].name
        assert "mia" in fname

    def test_log_file_property(self, tmp_path):
        s = _make(tmp_path)
        s.start()
        assert s.log_file is not None
        assert s.log_file.exists()
        s.end()

    def test_creates_directory_if_missing(self, tmp_path):
        nested = tmp_path / "a" / "b"
        s = TelemetrySession(nested, "lily")
        s.start()
        s.end()
        assert nested.exists()


# ── session_start event ────────────────────────────────────────────────────

class TestSessionStartEvent:
    def test_first_event_is_session_start(self, tmp_path):
        s = _make(tmp_path)
        s.start(level="B")
        s.end()
        events = _read_events(s.log_file)
        assert events[0]["event"] == "session_start"

    def test_session_start_contains_level(self, tmp_path):
        s = _make(tmp_path)
        s.start(level="C1")
        s.end()
        ev = _read_events(s.log_file)[0]
        assert ev["level"] == "C1"

    def test_session_start_contains_profile(self, tmp_path):
        s = _make(tmp_path, slug="lily")
        s.start()
        s.end()
        ev = _read_events(s.log_file)[0]
        assert ev["profile"] == "lily"

    def test_session_start_is_onboarding_flag(self, tmp_path):
        s = _make(tmp_path)
        s.start(is_onboarding=True)
        s.end()
        ev = _read_events(s.log_file)[0]
        assert ev["is_onboarding"] is True

    def test_session_id_is_present(self, tmp_path):
        s = _make(tmp_path)
        s.start()
        s.end()
        ev = _read_events(s.log_file)[0]
        assert "session_id" in ev
        assert len(ev["session_id"]) == 8


# ── turn events ────────────────────────────────────────────────────────────

class TestTurnEvent:
    def test_turn_event_written(self, tmp_path):
        s = _make(tmp_path)
        s.start()
        s.log_turn("I goed to school", "You went to school!",
                   stt_ms=300, llm_ttft_ms=600, total_ms=1500)
        s.end()
        events = _read_events(s.log_file)
        turn = next(e for e in events if e["event"] == "turn")
        assert turn is not None

    def test_turn_contains_all_required_fields(self, tmp_path):
        s = _make(tmp_path)
        s.start()
        s.log_turn("test", "reply",
                   stt_ms=100, llm_ttft_ms=200, total_ms=500,
                   level="A", topic="school", problem="past_tense: goed->went",
                   engaged=True, reengagement_fired=False)
        s.end()
        t = next(e for e in _read_events(s.log_file) if e["event"] == "turn")
        assert t["child_said"] == "test"
        assert t["avatar_said"] == "reply"
        assert t["stt_ms"] == 100
        assert t["llm_ttft_ms"] == 200
        assert t["total_ms"] == 500
        assert t["level"] == "A"
        assert t["topic"] == "school"
        assert t["problem"] == "past_tense: goed->went"
        assert t["engaged"] is True
        assert t["reengagement_fired"] is False
        assert t["word_count"] == 1
        assert t["turn_n"] == 1

    def test_turn_n_increments(self, tmp_path):
        s = _make(tmp_path)
        s.start()
        for _ in range(3):
            s.log_turn("hi", "hello", stt_ms=100, llm_ttft_ms=200, total_ms=400)
        s.end()
        turns = [e for e in _read_events(s.log_file) if e["event"] == "turn"]
        assert [t["turn_n"] for t in turns] == [1, 2, 3]

    def test_word_count_computed_correctly(self, tmp_path):
        s = _make(tmp_path)
        s.start()
        s.log_turn("I went to the park today",
                   "reply", stt_ms=100, llm_ttft_ms=200, total_ms=400)
        s.end()
        t = next(e for e in _read_events(s.log_file) if e["event"] == "turn")
        assert t["word_count"] == 6


# ── didnt_catch event ──────────────────────────────────────────────────────

class TestDidntCatchEvent:
    def test_didnt_catch_event_written(self, tmp_path):
        s = _make(tmp_path)
        s.start()
        s.log_didnt_catch()
        s.end()
        events = _read_events(s.log_file)
        dc = next((e for e in events if e["event"] == "didnt_catch"), None)
        assert dc is not None
        assert dc["profile"] == "lily"


# ── session_end aggregates ─────────────────────────────────────────────────

class TestSessionEndAggregates:
    def _run(self, tmp_path, turns):
        s = _make(tmp_path)
        s.start(level="A")
        for t in turns:
            s.log_turn(**t)
        s.end()
        events = _read_events(s.log_file)
        return next(e for e in events if e["event"] == "session_end")

    def test_turn_count(self, tmp_path):
        turns = [
            dict(transcript="hi", reply="r", stt_ms=100, llm_ttft_ms=200, total_ms=400),
            dict(transcript="bye", reply="r2", stt_ms=100, llm_ttft_ms=200, total_ms=400),
        ]
        end = self._run(tmp_path, turns)
        assert end["turns"] == 2

    def test_avg_word_count(self, tmp_path):
        turns = [
            dict(transcript="hello", reply="r", stt_ms=100, llm_ttft_ms=200, total_ms=400),
            dict(transcript="hello world", reply="r", stt_ms=100, llm_ttft_ms=200, total_ms=400),
            dict(transcript="one two three", reply="r", stt_ms=100, llm_ttft_ms=200, total_ms=400),
        ]
        end = self._run(tmp_path, turns)
        assert end["avg_word_count"] == 2.0   # (1+2+3)/3

    def test_engaged_ratio(self, tmp_path):
        turns = [
            dict(transcript="a", reply="r", stt_ms=100, llm_ttft_ms=200, total_ms=400, engaged=True),
            dict(transcript="a", reply="r", stt_ms=100, llm_ttft_ms=200, total_ms=400, engaged=False),
        ]
        end = self._run(tmp_path, turns)
        assert end["engaged_ratio"] == 0.5

    def test_topics_deduped(self, tmp_path):
        turns = [
            dict(transcript="a", reply="r", stt_ms=100, llm_ttft_ms=200, total_ms=400, topic="school"),
            dict(transcript="a", reply="r", stt_ms=100, llm_ttft_ms=200, total_ms=400, topic="school"),
            dict(transcript="a", reply="r", stt_ms=100, llm_ttft_ms=200, total_ms=400, topic="cats"),
        ]
        end = self._run(tmp_path, turns)
        assert end["topics"] == ["school", "cats"]

    def test_problems_listed(self, tmp_path):
        turns = [
            dict(transcript="a", reply="r", stt_ms=100, llm_ttft_ms=200, total_ms=400,
                 problem="past_tense: goed->went"),
            dict(transcript="a", reply="r", stt_ms=100, llm_ttft_ms=200, total_ms=400,
                 problem="article: missing a"),
        ]
        end = self._run(tmp_path, turns)
        assert "past_tense: goed->went" in end["problems"]

    def test_didnt_catch_count(self, tmp_path):
        s = _make(tmp_path)
        s.start()
        s.log_didnt_catch()
        s.log_didnt_catch()
        s.end()
        end = next(e for e in _read_events(s.log_file) if e["event"] == "session_end")
        assert end["didnt_catch_count"] == 2

    def test_duration_is_non_negative(self, tmp_path):
        s = _make(tmp_path)
        s.start()
        s.end()
        end = next(e for e in _read_events(s.log_file) if e["event"] == "session_end")
        assert end["duration_s"] >= 0


# ── File is valid JSONL ─────────────────────────────────────────────────────

class TestValidJSONL:
    def test_all_lines_are_valid_json(self, tmp_path):
        s = _make(tmp_path)
        s.start()
        s.log_turn("test", "reply", stt_ms=100, llm_ttft_ms=200, total_ms=400)
        s.log_didnt_catch()
        s.end()
        for line in s.log_file.read_text().splitlines():
            if line.strip():
                json.loads(line)   # must not raise

    def test_events_in_correct_order(self, tmp_path):
        s = _make(tmp_path)
        s.start()
        s.log_turn("test", "reply", stt_ms=100, llm_ttft_ms=200, total_ms=400)
        s.end()
        events = _read_events(s.log_file)
        assert events[0]["event"] == "session_start"
        assert events[1]["event"] == "turn"
        assert events[-1]["event"] == "session_end"
