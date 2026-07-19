"""Tests for Japanese furigana annotation.

Pure-function unit tests. Some assertions gate on pyopenjtalk being importable:
the offline CI environment doesn't install the Japanese TTS chain, so those
tests skip cleanly. The graceful-degradation tests (missing dependency →
plain text) always run.
"""
import pytest

from app.furigana import (
    annotate,
    annotate_for,
    contains_kanji,
    katakana_to_hiragana,
)


# ── Pure helpers ────────────────────────────────────────────────

class TestContainsKanji:
    def test_hiragana_only_is_not_kanji(self):
        assert not contains_kanji("こんにちは")

    def test_katakana_only_is_not_kanji(self):
        assert not contains_kanji("コンニチハ")

    def test_ascii_is_not_kanji(self):
        assert not contains_kanji("hello 123")

    def test_kanji_detected(self):
        assert contains_kanji("私")
        assert contains_kanji("日本語")

    def test_mixed_string_with_kanji(self):
        assert contains_kanji("私は元気")


class TestKatakanaToHiragana:
    def test_basic_shift(self):
        assert katakana_to_hiragana("ワタシ") == "わたし"

    def test_leaves_hiragana_alone(self):
        assert katakana_to_hiragana("こんにちは") == "こんにちは"

    def test_leaves_kanji_alone(self):
        assert katakana_to_hiragana("日本") == "日本"

    def test_mixed_string(self):
        # Only katakana chars shift; kanji and punctuation stay.
        assert katakana_to_hiragana("私はワタシ。") == "私はわたし。"

    def test_katakana_edge_of_range(self):
        # ァ (U+30A1) → ぁ (U+3041), ヶ (U+30F6) → ゖ (U+3096) — extremes of the
        # shift range. Pins that we don't off-by-one either end.
        assert katakana_to_hiragana("ァヶ") == "ぁゖ"


# ── annotate() — behaviour independent of pyopenjtalk ────────────

class TestAnnotateGracefulDegradation:
    def test_empty_returns_empty(self):
        assert annotate("") == ""

    def test_missing_pyopenjtalk_falls_back_to_plain_text(self, monkeypatch):
        # Simulate the frozen-app-without-dict / dev-without-JP-deps case.
        # We inject a broken pyopenjtalk into sys.modules so `import
        # pyopenjtalk` inside annotate() succeeds but run_frontend() raises.
        import sys, types
        fake = types.ModuleType("pyopenjtalk")
        fake.run_frontend = lambda text: (_ for _ in ()).throw(RuntimeError("no dict"))
        monkeypatch.setitem(sys.modules, "pyopenjtalk", fake)
        # Must NOT crash — Japanese must keep displaying, just as plain text.
        # HTML escaping is required so the fallback stays safe if the reply
        # ever contains angle brackets from the LLM.
        assert annotate("こんにちは") == "こんにちは"
        assert annotate("a<b") == "a&lt;b"

    def test_never_leaks_raw_html_in_fallback(self, monkeypatch):
        # Same graceful-degradation path, this time proving the escape is
        # applied to arbitrary content, not just the ASCII case above.
        import sys, types
        fake = types.ModuleType("pyopenjtalk")
        fake.run_frontend = lambda text: (_ for _ in ()).throw(RuntimeError())
        monkeypatch.setitem(sys.modules, "pyopenjtalk", fake)
        assert "<script>" not in annotate("<script>alert(1)</script>")


class TestAnnotateFor:
    def test_english_returns_none(self):
        assert annotate_for("hello", "en") is None

    def test_empty_text_returns_none_regardless_of_language(self):
        assert annotate_for("", "ja") is None
        assert annotate_for("", "en") is None

    def test_japanese_delegates_to_annotate(self):
        # Even without pyopenjtalk running, JP + non-empty text → returns a
        # string (possibly the fallback), never None.
        result = annotate_for("こんにちは", "ja")
        assert result is not None
        assert isinstance(result, str)


# ── annotate() — real pyopenjtalk (skipped when unavailable) ─────

pyopenjtalk = pytest.importorskip("pyopenjtalk")


def _pyopenjtalk_ready():
    """OpenJTalk needs its dict on disk; a fresh install downloads it. The
    dict fetch happens implicitly on first run_frontend() call, but the CI
    box may not have network — skip the live tests if so.
    """
    try:
        pyopenjtalk.run_frontend("試験")
        return True
    except Exception:
        return False


live = pytest.mark.skipif(not _pyopenjtalk_ready(),
                          reason="pyopenjtalk dict not available")


@live
class TestAnnotateLive:
    def test_pure_hiragana_returns_unchanged(self):
        # No kanji in the input → no <ruby> tags anywhere.
        out = annotate("こんにちは")
        assert "<ruby>" not in out
        assert "こんにちは" in out

    def test_kanji_wrapped_in_ruby_with_hiragana_reading(self):
        out = annotate("私")
        # <ruby>私<rt>わたし</rt></ruby> — reading is hiragana, not katakana.
        assert "<ruby>私<rt>" in out
        assert "</rt></ruby>" in out
        # Reading is hiragana (has わ), not the pyopenjtalk katakana (ワ).
        assert "わ" in out
        assert "ワ" not in out

    def test_mixed_sentence_keeps_kana_between_ruby(self):
        out = annotate("私は日本語を話します")
        # Kanji tokens are wrapped: 私, 日本語, and the 話 half of 話し.
        # OpenJTalk tokenises 話します as 話し|ます (inflection glued onto the
        # kanji, the -ます ending is its own morpheme), so we expect the
        # reading to include the trailing kana: 話し → はなし.
        assert "<ruby>私<rt>わたし</rt></ruby>" in out
        assert "<ruby>日本語<rt>にほんご</rt></ruby>" in out
        assert "<ruby>話し<rt>はなし</rt></ruby>" in out
        # Particles + verb ending are plain (は, を, ます).
        assert "は" in out and "を" in out and "ます" in out
