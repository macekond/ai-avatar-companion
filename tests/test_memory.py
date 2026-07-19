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
    humanize_since,
    name_to_slug,
    today_context,
)


# ── Relative-time helpers ──────────────────────────────────────────────────

class TestHumanizeSince:
    TODAY = date(2026, 7, 14)  # a Tuesday

    def _ago(self, days: int) -> str:
        return humanize_since((self.TODAY - timedelta(days=days)).isoformat(),
                              today=self.TODAY)

    def test_today(self):
        assert self._ago(0) == "today"

    def test_future_date_treated_as_today(self):
        future = (self.TODAY + timedelta(days=3)).isoformat()
        assert humanize_since(future, today=self.TODAY) == "today"

    def test_yesterday(self):
        assert self._ago(1) == "yesterday"

    def test_days_ago(self):
        assert self._ago(2) == "2 days ago"
        assert self._ago(6) == "6 days ago"

    def test_last_week(self):
        assert self._ago(7) == "last week"
        assert self._ago(13) == "last week"

    def test_weeks_ago(self):
        assert self._ago(14) == "2 weeks ago"
        assert self._ago(21) == "3 weeks ago"

    def test_last_month(self):
        assert self._ago(28) == "last month"
        assert self._ago(59) == "last month"

    def test_months_ago(self):
        assert self._ago(60) == "2 months ago"

    def test_defaults_to_real_today(self):
        # No `today` arg → uses date.today(); a same-day date must read "today".
        assert humanize_since(date.today().isoformat()) == "today"


class TestTodayContext:
    def test_formats_weekday_and_date(self):
        assert today_context(date(2026, 7, 14)) == "Tuesday, 14 July 2026"

    def test_no_leading_zero_on_day(self):
        assert today_context(date(2026, 7, 4)) == "Saturday, 4 July 2026"

    def test_defaults_to_real_today(self):
        assert today_context().startswith(date.today().strftime("%A"))


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

    def test_custom_fallback_for_empty(self):
        assert name_to_slug("###", fallback="") == ""
        assert name_to_slug("", fallback="") == ""

    def test_fallback_not_used_for_valid_slug(self):
        assert name_to_slug("Mia", fallback="") == "mia"


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

    def test_new_profile_defaults_to_english_cefr(self):
        # A freshly-created profile is English at CEFR level "A" — the historical
        # single-language default — so existing behaviour is unchanged.
        p = ChildProfile(name="Mia")
        assert p.language == "en"
        assert p.level == "A"

    def test_legacy_profile_dict_loads_with_defaults(self):
        # Profiles written before language/level existed have neither key. They
        # must still load (not be swallowed as "corrupt" -> silent memory loss),
        # defaulting to English/"A".
        legacy = {
            "profile": {"name": "Lily", "age": 8, "first_session_date": "2026-01-01"},
            "topics": [],
            "problems": [],
            "last_updated": "2026-01-01",
        }
        restored = ChildMemory.from_dict(legacy)
        assert restored.profile.name == "Lily"
        assert restored.profile.language == "en"
        assert restored.profile.level == "A"

    def test_language_and_level_survive_round_trip(self):
        mem = ChildMemory(profile=ChildProfile(name="Yuki", language="ja", level="N5"))
        restored = ChildMemory.from_dict(mem.to_dict())
        assert restored.profile.language == "ja"
        assert restored.profile.level == "N5"

    def test_voice_defaults_empty_and_survives_round_trip(self):
        # Empty voice = "use the language default"; a chosen voice persists.
        assert ChildProfile(name="Mia").voice == ""
        mem = ChildMemory(profile=ChildProfile(name="Yuki", language="ja",
                                               level="N5", voice="jf_alpha"))
        restored = ChildMemory.from_dict(mem.to_dict())
        assert restored.profile.voice == "jf_alpha"

    def test_japanese_transcript_persists_unescaped(self, tmp_path):
        # A Japanese turn must round-trip through the transcript store; on disk
        # it should be human-readable UTF-8, not \uXXXX escapes.
        from app.transcript import TranscriptStore
        store = TranscriptStore(tmp_path, "yuki")
        store.append_turn(1, "ねこがすきです", "いいですね！")
        raw = (tmp_path / "yuki.jsonl").read_text(encoding="utf-8")
        assert "ねこがすきです" in raw
        loaded = store.load()
        assert loaded[0]["you"] == "ねこがすきです"
        assert loaded[0]["nova"] == "いいですね！"


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

    def test_junk_slug_does_not_collapse_to_child(self, tmp_path):
        # Junk that sanitises to nothing must NOT be treated as the "child"
        # fallback and delete an unrelated profile named "child".
        (tmp_path / "child.json").write_text("{}")
        mgr = MemoryManager(tmp_path, "child")
        assert mgr.delete_profile("###") is False
        assert (tmp_path / "child.json").exists()   # untouched
        assert mgr.delete_profile("") is False

    def test_late_save_cannot_resurrect_deleted_profile(self, tmp_path):
        # A background extraction task holds its own reference to the manager
        # and may outlive the drain timeout. Its save() must not recreate the
        # file the parent just deleted — "remove this child" has to stick.
        mgr = MemoryManager(tmp_path, "lily")
        memory = ChildMemory(profile=ChildProfile(name="Lily", age=8))
        mgr.save(memory)
        assert mgr.delete_profile("lily") is True

        mgr.save(memory)   # the late task, still running

        assert mgr.load() is None
        assert mgr.list_profiles() == []

    def test_deleting_another_profile_does_not_block_own_saves(self, tmp_path):
        # Only the deleted slug is tombstoned; the manager stays usable for
        # its own (still-live) profile.
        mgr = MemoryManager(tmp_path, "lily")
        memory = ChildMemory(profile=ChildProfile(name="Lily", age=8))
        mgr.save(memory)
        (tmp_path / "mia.json").write_text("{}")

        assert mgr.delete_profile("mia") is True
        mgr.save(memory)

        assert mgr.load() is not None
