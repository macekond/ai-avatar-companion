"""Tests for app/memory_extractor.py.

Ollama is mocked — no network calls needed.
"""
from __future__ import annotations

from unittest.mock import MagicMock, patch

import pytest

from app.memory_extractor import ExtractionResult, MemoryExtractor


# ── ExtractionResult.parse_problem ────────────────────────────────────────

class TestParseProblem:
    def test_arrow_separator(self):
        r = ExtractionResult(problem_raw="past_tense: goed -> went")
        p = r.parse_problem()
        assert p == ("past_tense", "goed", "went")

    def test_unicode_arrow_separator(self):
        r = ExtractionResult(problem_raw="past_tense: goed → went")
        p = r.parse_problem()
        assert p == ("past_tense", "goed", "went")

    def test_strips_quotes_from_example(self):
        r = ExtractionResult(problem_raw="vocabulary: 'excited' -> excited")
        p = r.parse_problem()
        assert p[1] == "excited"

    def test_none_problem_returns_none(self):
        assert ExtractionResult().parse_problem() is None

    def test_missing_colon_returns_none(self):
        assert ExtractionResult(problem_raw="goed went").parse_problem() is None

    def test_missing_arrow_returns_none(self):
        assert ExtractionResult(problem_raw="past_tense: goed").parse_problem() is None

    def test_strips_whitespace(self):
        r = ExtractionResult(problem_raw="  past_tense :  goed  ->  went  ")
        p = r.parse_problem()
        assert p is not None
        assert p[1] == "goed"
        assert p[2] == "went"


# ── MemoryExtractor._parse ─────────────────────────────────────────────────

class TestParse:
    def _p(self, text: str) -> ExtractionResult:
        return MemoryExtractor._parse(text)

    def test_full_valid_response(self):
        r = self._p("TOPIC: football\nPROBLEM: past_tense: goed -> went\nENGAGED: yes")
        assert r.topic == "football"
        assert r.problem_raw == "past_tense: goed -> went"
        assert r.engaged is True

    def test_none_values(self):
        r = self._p("TOPIC: none\nPROBLEM: none\nENGAGED: yes")
        assert r.topic is None
        assert r.problem_raw is None
        assert r.engaged is True

    def test_disengaged(self):
        r = self._p("TOPIC: none\nPROBLEM: none\nENGAGED: no")
        assert r.engaged is False

    def test_topic_lowercased(self):
        r = self._p("TOPIC: Football Club\nPROBLEM: none\nENGAGED: yes")
        assert r.topic == "football club"

    def test_empty_text_returns_defaults(self):
        r = self._p("")
        assert r.topic is None
        assert r.problem_raw is None
        assert r.engaged is True

    def test_malformed_text_returns_defaults(self):
        r = self._p("I don't know how to answer this.")
        assert r.topic is None
        assert r.problem_raw is None
        assert r.engaged is True

    def test_partial_response_safe(self):
        r = self._p("TOPIC: animals")
        assert r.topic == "animals"
        assert r.problem_raw is None
        assert r.engaged is True


# ── MemoryExtractor.extract (mocked Ollama) ────────────────────────────────

def _mock_response(content: str) -> MagicMock:
    m = MagicMock()
    m.message.content = content
    return m


class TestExtract:
    def _ex(self):
        return MemoryExtractor("llama3.2:3b")

    def test_returns_topic_when_found(self):
        with patch("ollama.chat", return_value=_mock_response(
            "TOPIC: football\nPROBLEM: none\nENGAGED: yes"
        )):
            r = self._ex().extract("I played football", "That sounds fun!")
        assert r.topic == "football"

    def test_returns_problem_when_found(self):
        with patch("ollama.chat", return_value=_mock_response(
            "TOPIC: none\nPROBLEM: past_tense: goed -> went\nENGAGED: yes"
        )):
            r = self._ex().extract("I goed to school", "Oh, you went to school!")
        assert r.problem_raw is not None
        assert r.parse_problem() == ("past_tense", "goed", "went")

    def test_returns_safe_defaults_on_ollama_error(self):
        with patch("ollama.chat", side_effect=Exception("connection refused")):
            r = self._ex().extract("hi", "hello")
        assert r.topic is None
        assert r.problem_raw is None
        assert r.engaged is True  # default to engaged on error

    def test_returns_safe_defaults_on_empty_response(self):
        with patch("ollama.chat", return_value=_mock_response("")):
            r = self._ex().extract("hi", "hello")
        assert r.topic is None
        assert r.engaged is True


# ── Integration: extractor result applied to memory manager ───────────────

class TestExtractorAppliedToMemory:
    def test_update_topic_called_when_topic_found(self, tmp_path):
        from app.memory import ChildMemory, ChildProfile, MemoryManager
        mem = ChildMemory(profile=ChildProfile(name="Lily"))
        mgr = MemoryManager(tmp_path, "lily")

        result = ExtractionResult(topic="cats")
        if result.topic:
            mgr.update_topic(mem, result.topic)

        assert len(mem.topics) == 1
        assert mem.topics[0].keyword == "cats"

    def test_update_problem_called_when_problem_found(self, tmp_path):
        from app.memory import ChildMemory, ChildProfile, MemoryManager
        mem = ChildMemory(profile=ChildProfile(name="Lily"))
        mgr = MemoryManager(tmp_path, "lily")

        result = ExtractionResult(problem_raw="past_tense: goed -> went")
        parsed = result.parse_problem()
        if parsed:
            mgr.update_problem(mem, *parsed)

        assert len(mem.problems) == 1
        assert mem.problems[0].type == "past_tense"

    def test_no_update_when_topic_is_none(self, tmp_path):
        from app.memory import ChildMemory, ChildProfile, MemoryManager
        mem = ChildMemory(profile=ChildProfile(name="Lily"))
        mgr = MemoryManager(tmp_path, "lily")

        result = ExtractionResult(topic=None)
        if result.topic:
            mgr.update_topic(mem, result.topic)

        assert mem.topics == []
