"""Unit tests for app/memory.py — data model, persistence, and pruning.

No mocks, no network. All I/O uses pytest's tmp_path fixture.
"""
from __future__ import annotations

import json
from datetime import date, timedelta
from pathlib import Path

import pytest

from app.memory import (
    ChildMemory,
    ChildProfile,
    MemoryManager,
    Problem,
    Topic,
    name_to_slug,
)


# ── Slug generation ────────────────────────────────────────────────────────

class TestNameToSlug:
    def test_simple_name(self):
        assert name_to_slug("Lily") == "lily"

    def test_spaces_become_underscores(self):
        assert name_to_slug("Mary Kate") == "mary_kate"

    def test_multiple_spaces(self):
        # Multiple spaces collapse to a single underscore
        assert name_to_slug("Anna  Marie") == "anna_marie"

    def test_all_caps(self):
        assert name_to_slug("LILY") == "lily"

    def test_non_ascii_stripped(self):
        result = name_to_slug("Björn")
        assert "b" in result and "j" in result
        assert "ö" not in result  # non-ASCII removed

    def test_special_chars_stripped(self):
        result = name_to_slug("O'Brien")
        assert "'" not in result
        assert "obrien" == result

    def test_empty_string_returns_child(self):
        assert name_to_slug("") == "child"

    def test_only_special_chars(self):
        assert name_to_slug("---") == "child"

    def test_numbers_preserved(self):
        assert name_to_slug("kid2") == "kid2"


# ── Data model ─────────────────────────────────────────────────────────────

class TestChildMemoryRoundTrip:
    def _make_memory(self):
        mem = ChildMemory(
            profile=ChildProfile(name="Lily", age=8, first_session_date="2026-01-01"),
            topics=[Topic("football", 3, "2026-07-01")],
            problems=[Problem("past_tense", "goed", "went", 2, "2026-07-01", False)],
            last_updated="2026-07-01",
        )
        return mem

    def test_to_dict_contains_all_fields(self):
        mem = self._make_memory()
        d = mem.to_dict()
        assert d["profile"]["name"] == "Lily"
        assert d["profile"]["age"] == 8
        assert len(d["topics"]) == 1
        assert d["topics"][0]["keyword"] == "football"
        assert len(d["problems"]) == 1
        assert d["problems"][0]["type"] == "past_tense"

    def test_from_dict_round_trip(self):
        mem = self._make_memory()
        restored = ChildMemory.from_dict(mem.to_dict())
        assert restored.profile.name == mem.profile.name
        assert restored.profile.age == mem.profile.age
        assert len(restored.topics) == 1
        assert restored.topics[0].keyword == "football"
        assert restored.topics[0].mention_count == 3
        assert restored.problems[0].type == "past_tense"
        assert restored.problems[0].resolved is False

    def test_from_dict_with_empty_lists(self):
        mem = ChildMemory(profile=ChildProfile(name="Mia"))
        restored = ChildMemory.from_dict(mem.to_dict())
        assert restored.topics == []
        assert restored.problems == []


# ── MemoryManager persistence ──────────────────────────────────────────────

class TestMemoryManagerPersistence:
    def _mgr(self, tmp_path, slug="lily"):
        return MemoryManager(tmp_path, slug)

    def test_load_returns_none_for_missing_file(self, tmp_path):
        mgr = self._mgr(tmp_path)
        assert mgr.load() is None

    def test_save_creates_file(self, tmp_path):
        mgr = self._mgr(tmp_path)
        mem = ChildMemory(profile=ChildProfile(name="Lily", age=8))
        mgr.save(mem)
        assert (tmp_path / "lily.json").exists()

    def test_save_load_round_trip(self, tmp_path):
        mgr = self._mgr(tmp_path)
        mem = ChildMemory(
            profile=ChildProfile(name="Lily", age=8),
            topics=[Topic("cats", 2, "2026-07-01")],
        )
        mgr.save(mem)
        loaded = mgr.load()
        assert loaded is not None
        assert loaded.profile.name == "Lily"
        assert loaded.profile.age == 8
        assert loaded.topics[0].keyword == "cats"

    def test_save_creates_directory(self, tmp_path):
        nested = tmp_path / "deeply" / "nested"
        mgr = MemoryManager(nested, "lily")
        mgr.save(ChildMemory(profile=ChildProfile(name="Lily")))
        assert (nested / "lily.json").exists()

    def test_load_returns_none_for_corrupt_file(self, tmp_path):
        (tmp_path / "lily.json").write_text("not valid json")
        mgr = self._mgr(tmp_path)
        assert mgr.load() is None

    def test_save_updates_last_updated(self, tmp_path):
        mgr = self._mgr(tmp_path)
        mem = ChildMemory(profile=ChildProfile(name="Lily"), last_updated="1990-01-01")
        mgr.save(mem)
        loaded = mgr.load()
        assert loaded.last_updated == date.today().isoformat()

    def test_slug_property(self, tmp_path):
        mgr = self._mgr(tmp_path, slug="mia")
        assert mgr.slug == "mia"


# ── update_topic ───────────────────────────────────────────────────────────

class TestUpdateTopic:
    def _mgr(self, tmp_path):
        return MemoryManager(tmp_path, "lily")

    def test_adds_new_topic(self, tmp_path):
        mgr = self._mgr(tmp_path)
        mem = ChildMemory(profile=ChildProfile(name="Lily"))
        mgr.update_topic(mem, "football")
        assert len(mem.topics) == 1
        assert mem.topics[0].keyword == "football"
        assert mem.topics[0].mention_count == 1

    def test_increments_existing_topic(self, tmp_path):
        mgr = self._mgr(tmp_path)
        mem = ChildMemory(profile=ChildProfile(name="Lily"))
        mgr.update_topic(mem, "football")
        mgr.update_topic(mem, "football")
        assert len(mem.topics) == 1
        assert mem.topics[0].mention_count == 2

    def test_topic_keyword_lowercased(self, tmp_path):
        mgr = self._mgr(tmp_path)
        mem = ChildMemory(profile=ChildProfile(name="Lily"))
        mgr.update_topic(mem, "Football")
        assert mem.topics[0].keyword == "football"

    def test_ignores_empty_keyword(self, tmp_path):
        mgr = self._mgr(tmp_path)
        mem = ChildMemory(profile=ChildProfile(name="Lily"))
        mgr.update_topic(mem, "  ")
        assert mem.topics == []

    def test_different_keywords_create_separate_entries(self, tmp_path):
        mgr = self._mgr(tmp_path)
        mem = ChildMemory(profile=ChildProfile(name="Lily"))
        mgr.update_topic(mem, "football")
        mgr.update_topic(mem, "cats")
        assert len(mem.topics) == 2


# ── update_problem ─────────────────────────────────────────────────────────

class TestUpdateProblem:
    def _mgr(self, tmp_path):
        return MemoryManager(tmp_path, "lily")

    def test_adds_new_problem(self, tmp_path):
        mgr = self._mgr(tmp_path)
        mem = ChildMemory(profile=ChildProfile(name="Lily"))
        mgr.update_problem(mem, "past_tense", "goed", "went")
        assert len(mem.problems) == 1
        assert mem.problems[0].type == "past_tense"
        assert mem.problems[0].example == "goed"
        assert mem.problems[0].correction == "went"
        assert mem.problems[0].times_seen == 1

    def test_increments_existing_problem(self, tmp_path):
        mgr = self._mgr(tmp_path)
        mem = ChildMemory(profile=ChildProfile(name="Lily"))
        mgr.update_problem(mem, "past_tense", "goed", "went")
        mgr.update_problem(mem, "past_tense", "goed", "went")
        assert len(mem.problems) == 1
        assert mem.problems[0].times_seen == 2

    def test_reactivates_resolved_problem(self, tmp_path):
        mgr = self._mgr(tmp_path)
        mem = ChildMemory(profile=ChildProfile(name="Lily"))
        mgr.update_problem(mem, "past_tense", "goed", "went")
        mem.problems[0].resolved = True
        mgr.update_problem(mem, "past_tense", "goed", "went")
        assert mem.problems[0].resolved is False
        assert mem.problems[0].times_seen == 2

    def test_example_match_is_case_insensitive(self, tmp_path):
        mgr = self._mgr(tmp_path)
        mem = ChildMemory(profile=ChildProfile(name="Lily"))
        mgr.update_problem(mem, "past_tense", "Goed", "went")
        mgr.update_problem(mem, "past_tense", "goed", "went")
        assert len(mem.problems) == 1
        assert mem.problems[0].times_seen == 2

    def test_mark_resolved(self, tmp_path):
        mgr = self._mgr(tmp_path)
        mem = ChildMemory(profile=ChildProfile(name="Lily"))
        mgr.update_problem(mem, "past_tense", "goed", "went")
        mgr.mark_resolved(mem, "past_tense", "goed")
        assert mem.problems[0].resolved is True


# ── prune ──────────────────────────────────────────────────────────────────

class TestPrune:
    def _mgr(self, tmp_path, **kwargs):
        return MemoryManager(tmp_path, "lily", **kwargs)

    def _old_date(self, days_ago: int) -> str:
        return (date.today() - timedelta(days=days_ago)).isoformat()

    def test_removes_expired_topics(self, tmp_path):
        mgr = self._mgr(tmp_path, topic_ttl_days=7)
        mem = ChildMemory(profile=ChildProfile(name="Lily"))
        mem.topics = [
            Topic("recent", 1, date.today().isoformat()),
            Topic("old", 1, self._old_date(10)),
        ]
        mgr.prune(mem)
        assert len(mem.topics) == 1
        assert mem.topics[0].keyword == "recent"

    def test_keeps_topics_within_ttl(self, tmp_path):
        mgr = self._mgr(tmp_path, topic_ttl_days=14)
        mem = ChildMemory(profile=ChildProfile(name="Lily"))
        mem.topics = [Topic("cats", 1, self._old_date(13))]
        mgr.prune(mem)
        assert len(mem.topics) == 1

    def test_removes_expired_unresolved_problems(self, tmp_path):
        mgr = self._mgr(tmp_path, problem_ttl_days=7)
        mem = ChildMemory(profile=ChildProfile(name="Lily"))
        mem.problems = [
            Problem("past_tense", "goed", "went", 1, self._old_date(10), False),
        ]
        mgr.prune(mem)
        assert mem.problems == []

    def test_resolved_problems_expire_faster(self, tmp_path):
        mgr = self._mgr(tmp_path, problem_ttl_days=30)
        mem = ChildMemory(profile=ChildProfile(name="Lily"))
        # Resolved 8 days ago — within normal TTL but beyond resolved TTL (7)
        mem.problems = [
            Problem("past_tense", "goed", "went", 1, self._old_date(8), True),
        ]
        mgr.prune(mem)
        assert mem.problems == []

    def test_caps_topics_at_max(self, tmp_path):
        mgr = self._mgr(tmp_path, max_topics=3)
        mem = ChildMemory(profile=ChildProfile(name="Lily"))
        today = date.today().isoformat()
        for i in range(5):
            mem.topics.append(Topic(f"topic{i}", 1, today))
        mgr.prune(mem)
        assert len(mem.topics) == 3

    def test_caps_problems_at_max(self, tmp_path):
        mgr = self._mgr(tmp_path, max_problems=2)
        mem = ChildMemory(profile=ChildProfile(name="Lily"))
        today = date.today().isoformat()
        for i in range(4):
            mem.problems.append(Problem(f"type{i}", f"ex{i}", f"fix{i}", 1, today, False))
        mgr.prune(mem)
        assert len(mem.problems) == 2

    def test_most_recent_kept_when_capping(self, tmp_path):
        mgr = self._mgr(tmp_path, max_topics=2)
        mem = ChildMemory(profile=ChildProfile(name="Lily"))
        mem.topics = [
            Topic("oldest", 1, self._old_date(5)),
            Topic("newest", 1, date.today().isoformat()),
            Topic("middle", 1, self._old_date(3)),
        ]
        mgr.prune(mem)
        keywords = [t.keyword for t in mem.topics]
        assert "newest" in keywords
        assert "middle" in keywords
        assert "oldest" not in keywords


# ── list_profiles ──────────────────────────────────────────────────────────

class TestListProfiles:
    def test_returns_empty_for_missing_dir(self, tmp_path):
        mgr = MemoryManager(tmp_path / "nonexistent", "lily")
        assert mgr.list_profiles() == []

    def test_returns_slugs_for_json_files(self, tmp_path):
        (tmp_path / "lily.json").write_text("{}")
        (tmp_path / "mia.json").write_text("{}")
        mgr = MemoryManager(tmp_path, "lily")
        profiles = mgr.list_profiles()
        assert "lily" in profiles
        assert "mia" in profiles

    def test_ignores_non_json_files(self, tmp_path):
        (tmp_path / "lily.json").write_text("{}")
        (tmp_path / "readme.txt").write_text("hello")
        mgr = MemoryManager(tmp_path, "lily")
        assert "readme" not in mgr.list_profiles()

    def test_sorted_alphabetically(self, tmp_path):
        for name in ["mia.json", "anna.json", "lily.json"]:
            (tmp_path / name).write_text("{}")
        mgr = MemoryManager(tmp_path, "lily")
        assert mgr.list_profiles() == ["anna", "lily", "mia"]


# ── delete_profile ──────────────────────────────────────────────────────────

class TestDeleteProfile:
    def test_deletes_existing_profile(self, tmp_path):
        (tmp_path / "lily.json").write_text("{}")
        (tmp_path / "mia.json").write_text("{}")
        mgr = MemoryManager(tmp_path, "lily")
        assert mgr.delete_profile("mia") is True
        assert mgr.list_profiles() == ["lily"]

    def test_missing_profile_returns_false(self, tmp_path):
        (tmp_path / "lily.json").write_text("{}")
        mgr = MemoryManager(tmp_path, "lily")
        assert mgr.delete_profile("ghost") is False

    def test_empty_slug_returns_false(self, tmp_path):
        mgr = MemoryManager(tmp_path, "lily")
        assert mgr.delete_profile("") is False

    def test_can_delete_own_active_profile(self, tmp_path):
        (tmp_path / "lily.json").write_text("{}")
        mgr = MemoryManager(tmp_path, "lily")
        assert mgr.delete_profile("lily") is True
        assert mgr.list_profiles() == []

    def test_slug_is_sanitised_no_path_traversal(self, tmp_path):
        # A crafted slug must never escape the profiles directory.
        victim = tmp_path.parent / "victim.json"
        victim.write_text("{}")
        (tmp_path / "lily.json").write_text("{}")
        mgr = MemoryManager(tmp_path, "lily")
        assert mgr.delete_profile("../victim") is False
        assert victim.exists()   # untouched
        victim.unlink()
