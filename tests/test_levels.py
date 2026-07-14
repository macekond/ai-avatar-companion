"""Tests for CEFR level definitions and per-level correction logic.

These are pure data tests — no network, no hardware, no mocking needed.
"""

import pytest
from app.levels import LEVELS, LEVEL_INSTRUCTIONS, instructions_for, _CORRECTION


# ── Level registry ─────────────────────────────────────────────────────────

class TestLevelRegistry:
    def test_five_levels_in_correct_order(self):
        assert LEVELS == ["Pre A", "A", "B", "C1", "C2"]

    def test_all_levels_have_instructions(self):
        for level in LEVELS:
            assert level in LEVEL_INSTRUCTIONS, f"Missing instructions for {level}"
            assert LEVEL_INSTRUCTIONS[level], f"Empty instructions for {level}"

    def test_instructions_for_known_level_is_non_empty(self):
        for level in LEVELS:
            result = instructions_for(level)
            assert isinstance(result, str)
            assert len(result) > 20, f"Instructions for {level} are suspiciously short"

    def test_instructions_for_unknown_level_returns_empty_string(self):
        assert instructions_for("D") == ""
        assert instructions_for("") == ""
        assert instructions_for("Z9") == ""
        assert instructions_for("pre a") == ""   # case-sensitive

    def test_each_instruction_contains_cefr_label(self):
        expected = {
            "Pre A": "Pre-A1",
            "A":     "A1/A2",
            "B":     "B1/B2",
            "C1":    "C1",
            "C2":    "C2",
        }
        for level, label in expected.items():
            instr = instructions_for(level)
            assert label in instr, f"Level {level} instruction missing CEFR label '{label}'"


# ── Correction guidance presence ──────────────────────────────────────────

class TestCorrectionGuidancePresence:
    def test_all_levels_embed_correction_guidance(self):
        """Every level instruction must include the correction stance."""
        for level in LEVELS:
            instr = instructions_for(level)
            assert "orrection" in instr, \
                f"Level '{level}' instruction missing correction guidance"

    def test_correction_dict_covers_all_levels(self):
        for level in LEVELS:
            assert level in _CORRECTION, f"No _CORRECTION entry for {level}"
            assert _CORRECTION[level], f"Empty _CORRECTION for {level}"


# ── Correction intensity escalation ──────────────────────────────────────

class TestCorrectionIntensityEscalation:
    """Pre A should be the most implicit; C2 should be the most explicit."""

    def test_pre_a_uses_silent_recasting(self):
        pre_a = instructions_for("Pre A")
        assert "silent" in pre_a.lower() or "never draw attention" in pre_a.lower(), \
            "Pre A should emphasise silent correction to protect confidence"

    def test_pre_a_prioritises_confidence(self):
        pre_a = instructions_for("Pre A")
        assert "confidence" in pre_a.lower()

    def test_level_a_requires_repetition_before_explicit_correction(self):
        """Level A should only correct after a mistake appears multiple times."""
        a = instructions_for("A")
        # Expects language around threshold (three or more times, not immediately)
        assert "three" in a.lower() or "3" in a or "repeat" in a.lower() \
               or "appeared" in a.lower()

    def test_level_b_addresses_patterns(self):
        b = instructions_for("B")
        assert "repeat" in b.lower() or "twice" in b.lower() or "pattern" in b.lower()

    def test_c2_allows_direct_correction(self):
        c2 = instructions_for("C2")
        assert "directly" in c2.lower() or "language partner" in c2.lower(), \
            "C2 should allow direct, explicit correction"

    def test_c2_mentions_subtle_errors(self):
        """C2 correction should go beyond grammar to vocabulary / register."""
        c2 = instructions_for("C2")
        has_advanced = any(
            word in c2.lower()
            for word in ("preposition", "register", "collocation", "subtle")
        )
        assert has_advanced, "C2 correction should cover nuanced language errors"

    def test_none_of_the_levels_use_negative_phrasing(self):
        """No level should tell the avatar to say 'that's wrong' or 'no'."""
        forbidden = ["that's wrong", "you are wrong", "incorrect", "don't say"]
        for level in LEVELS:
            instr = instructions_for(level).lower()
            for phrase in forbidden:
                assert phrase not in instr, \
                    f"Level {level} instruction contains forbidden phrase: '{phrase}'"


# ── Content spot-checks ────────────────────────────────────────────────────

class TestLevelContent:
    def test_pre_a_restricts_to_present_tense(self):
        assert "present tense" in instructions_for("Pre A").lower()

    def test_pre_a_limits_sentence_length(self):
        instr = instructions_for("Pre A")
        assert "3" in instr or "5" in instr or "words" in instr.lower()

    def test_a_covers_common_tenses(self):
        instr = instructions_for("A").lower()
        assert "past simple" in instr or "present simple" in instr

    def test_b_includes_modals(self):
        instr = instructions_for("B").lower()
        assert "modal" in instr or "could" in instr or "should" in instr

    def test_c1_covers_complex_grammar(self):
        instr = instructions_for("C1").lower()
        assert any(term in instr for term in
                   ("conditional", "passive", "perfect", "clause"))

    def test_c2_mentions_idioms(self):
        instr = instructions_for("C2").lower()
        assert "idiom" in instr or "collocation" in instr


# ── Level-fit strength (regression guards for the tuning change) ────────────

class TestLevelFitStrength:
    """The lower levels must forcefully override the generic base prompt and
    keep replies genuinely simple. These guard against drift back toward the
    'too complex at Pre A' behaviour."""

    def test_pre_a_and_a_override_general_guidance(self):
        """Pre A and A must state they take precedence over the base prompt."""
        for level in ("Pre A", "A"):
            assert "override" in instructions_for(level).lower(), \
                f"Level {level} should override the general guidance above it"

    def test_pre_a_enforces_single_short_sentence(self):
        instr = instructions_for("Pre A").lower()
        assert "one sentence" in instr, "Pre A should demand a single sentence"
        assert "never two sentences" in instr, \
            "Pre A should forbid multi-sentence replies"

    def test_pre_a_gives_a_hard_word_ceiling(self):
        """A concrete small word count, not just 'short', must be present."""
        instr = instructions_for("Pre A")
        assert "2–4 words" in instr or "5 words" in instr, \
            "Pre A should state an explicit low word ceiling"

    def test_pre_a_and_a_show_a_too_hard_counterexample(self):
        """Concrete 'too hard' examples give the model a ceiling to stay under."""
        for level in ("Pre A", "A"):
            assert "too hard" in instructions_for(level).lower(), \
                f"Level {level} should include a 'too hard' counter-example"

    def test_pre_a_forbids_non_present_tenses(self):
        instr = instructions_for("Pre A").lower()
        assert "no past tense" in instr or "present tense only" in instr

    def test_reply_length_grows_with_level(self):
        """Pre A is the tightest; each step up should not be stricter."""
        def cap(level):
            # Rough proxy: how many sentences the level permits.
            instr = instructions_for(level).lower()
            if "one sentence" in instr and "never two" in instr:
                return 1
            if "max two" in instr or "one short sentence" in instr:
                return 2
            if "two or three sentences" in instr:
                return 3
            return 99  # C1/C2 unbounded
        caps = [cap(l) for l in LEVELS]
        assert caps == sorted(caps), \
            f"Reply-length caps should be non-decreasing by level, got {caps}"
