"""Tests for TranscriptStore — per-profile conversation history on disk.

Conversation turns used to live only in the browser tab, so a relaunch (or a
crash) lost the whole history. TranscriptStore persists each turn as it happens
and replays it on the next connect. One append-only file per child, mirroring
the one-file-per-child layout of MemoryManager.
"""
from __future__ import annotations

import pytest

from app.transcript import TranscriptStore


class TestLoad:
    def test_missing_file_returns_empty(self, tmp_path):
        store = TranscriptStore(tmp_path, "lily")
        assert store.load() == []

    def test_append_then_load_roundtrips(self, tmp_path):
        store = TranscriptStore(tmp_path, "lily")
        store.append_turn(1, "I played football", "That sounds fun!")
        turns = store.load()
        assert turns == [
            {"id": 1, "you": "I played football",
             "nova": "That sounds fun!", "corrections": []}
        ]

    def test_order_preserved_across_turns(self, tmp_path):
        store = TranscriptStore(tmp_path, "lily")
        store.append_turn(1, "one", "reply one")
        store.append_turn(2, "two", "reply two")
        assert [t["id"] for t in store.load()] == [1, 2]

    def test_correction_attaches_to_its_turn(self, tmp_path):
        store = TranscriptStore(tmp_path, "lily")
        store.append_turn(1, "I goed to school", "You went to school!")
        store.append_correction(1, "past_tense", "goed", "went")
        turn = store.load()[0]
        assert turn["corrections"] == [
            {"kind": "past_tense", "wrong": "goed", "right": "went"}
        ]

    def test_corrupt_line_is_skipped(self, tmp_path):
        store = TranscriptStore(tmp_path, "lily")
        store.append_turn(1, "hello", "hi")
        with open(tmp_path / "lily.jsonl", "a", encoding="utf-8") as f:
            f.write("{ not valid json\n")
        store.append_turn(2, "again", "yes")
        assert [t["id"] for t in store.load()] == [1, 2]

    def test_profiles_do_not_share_history(self, tmp_path):
        TranscriptStore(tmp_path, "lily").append_turn(1, "lily line", "r")
        assert TranscriptStore(tmp_path, "mia").load() == []


class TestLastId:
    def test_zero_when_empty(self, tmp_path):
        assert TranscriptStore(tmp_path, "lily").last_id() == 0

    def test_returns_highest_id(self, tmp_path):
        store = TranscriptStore(tmp_path, "lily")
        store.append_turn(1, "a", "b")
        store.append_turn(2, "c", "d")
        assert store.last_id() == 2


class TestDelete:
    def test_delete_removes_history(self, tmp_path):
        store = TranscriptStore(tmp_path, "lily")
        store.append_turn(1, "a", "b")
        store.delete()
        assert store.load() == []

    def test_delete_missing_file_is_noop(self, tmp_path):
        TranscriptStore(tmp_path, "lily").delete()   # must not raise

    def test_append_after_delete_does_not_resurrect_file(self, tmp_path):
        # A late background correction (extraction task that outlived the drain)
        # holds this exact instance. Once the profile is deleted, its appends
        # must no-op — otherwise the deleted child's history comes back and a
        # reused slug can inherit a stale correction. Mirrors MemoryManager's
        # deleted-slug tombstone.
        store = TranscriptStore(tmp_path, "lily")
        store.append_turn(1, "a", "b")
        store.delete()
        store.append_correction(1, "past_tense", "goed", "went")
        store.append_turn(2, "c", "d")
        assert not (tmp_path / "lily.jsonl").exists()
        assert store.load() == []
