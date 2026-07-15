"""Tests for per-avatar appearance descriptions.

Pure Python — no Ollama, no hardware. Curated lookups never touch disk;
derive/cache round-trips use a tmp_path cache dir.
"""
import json
from pathlib import Path

import pytest

from app.appearance import (
    AppearanceStore,
    AvatarAppearance,
    DEFAULT_AVATAR_KEY,
    nearest_colour_name,
)


# ── Curated lookups ─────────────────────────────────────────────────────────

def test_default_avatar_key_matches_bundled_vrm():
    assert DEFAULT_AVATAR_KEY == "VIPEHero_2707"


def test_curated_lookup_returns_bundled_description(tmp_path):
    store = AppearanceStore(tmp_path)
    got = store.get(DEFAULT_AVATAR_KEY)
    assert got is not None
    assert got.source == "curated"
    assert got.description.strip()          # non-empty
    assert got.key == DEFAULT_AVATAR_KEY


def test_curated_lookup_for_sample_avatar(tmp_path):
    store = AppearanceStore(tmp_path)
    got = store.get("AvatarSample_A")
    assert got is not None
    assert got.source == "curated"
    assert got.description.strip()


def test_unknown_key_returns_none(tmp_path):
    store = AppearanceStore(tmp_path)
    assert store.get("no_such_avatar") is None


# ── Colour mapping ──────────────────────────────────────────────────────────

@pytest.mark.parametrize("hex_colour,expected", [
    ("#000000", "black"),
    ("#ffffff", "white"),
    ("#c0392b", "red"),
    ("#2e86de", "blue"),
    ("#6b4423", "brown"),
])
def test_nearest_colour_name(hex_colour, expected):
    assert nearest_colour_name(hex_colour) == expected


# ── Auto-derive + cache round-trip ──────────────────────────────────────────

def test_derive_from_regions_builds_and_caches(tmp_path):
    store = AppearanceStore(tmp_path)
    regions = {"hair": "#6b4423", "clothing": "#c0392b"}
    got = store.derive_from_regions("custom_bot", regions)

    assert got.source == "auto"
    assert "brown" in got.description.lower()
    assert "red" in got.description.lower()

    # Cached to disk and re-read as source="auto"
    cache_file = tmp_path / "custom_bot.json"
    assert cache_file.exists()
    again = store.get("custom_bot")
    assert again is not None
    assert again.source == "auto"
    assert again.description == got.description


def test_derive_key_sanitised_against_traversal(tmp_path):
    store = AppearanceStore(tmp_path)
    store.derive_from_regions("../../evil", {"hair": "#000000"})
    # Nothing written outside the cache dir
    assert not (tmp_path.parent / "evil.json").exists()
    # A sanitised file lives inside the cache dir
    assert list(tmp_path.glob("*.json"))


def test_corrupt_cache_file_treated_as_missing(tmp_path):
    store = AppearanceStore(tmp_path)
    (tmp_path / "broken.json").write_text("{ not json")
    assert store.get("broken") is None
