"""Tests for the LLM pipeline logic.

No Ollama server required — the chat() method is tested via mocking.
All other logic is pure Python and needs no mocking.
"""

from datetime import date, timedelta

import pytest
from unittest.mock import MagicMock, patch

from app.config import Config, ChildConfig, PersonalityConfig, LLMConfig
from app.levels import LANGUAGE_LOCK
from app.pipeline.llm import (
    LLMPipeline,
    _extract_sentences,
    _PATTERN_REVIEW_INTERVAL,
    _PATTERN_REVIEW_HINT,
)


# ── Helpers ────────────────────────────────────────────────────────────────

def make_config(level: str = "A", child: str = "Lily") -> Config:
    config = Config()
    config.child = ChildConfig(name=child, level=level)
    config.personality = PersonalityConfig(
        avatar_name="Nova",
        system_prompt="You are {child_name}'s friend, {avatar_name}.",
    )
    config.models.llm = LLMConfig(
        conversation_buffer_exchanges=6,
        max_response_tokens=120,
        temperature=0.7,
    )
    return config


def make_pipeline(level: str = "A") -> LLMPipeline:
    return LLMPipeline(make_config(level=level))


def fake_stream(*text: str):
    """Build a fake Ollama streaming response from a text string."""
    full = " ".join(text)
    chunks = []
    for char in full:
        m = MagicMock()
        m.message.content = char
        chunks.append(m)
    return iter(chunks)


# ── Sentence extraction ────────────────────────────────────────────────────

class TestExtractSentences:
    def test_empty_buffer(self):
        sentences, remainder = _extract_sentences("")
        assert sentences == []
        assert remainder == ""

    def test_single_complete_sentence(self):
        sentences, remainder = _extract_sentences("Hello. ")
        assert sentences == ["Hello."]
        assert remainder == ""

    def test_fragment_with_no_boundary(self):
        sentences, remainder = _extract_sentences("Hello there")
        assert sentences == []
        assert remainder == "Hello there"

    def test_multiple_sentences(self):
        sentences, remainder = _extract_sentences("Hi! How are you? I am fine. ")
        assert sentences == ["Hi!", "How are you?", "I am fine."]
        assert remainder == ""

    def test_partial_last_sentence_kept_as_remainder(self):
        sentences, remainder = _extract_sentences("Hello. How are")
        assert sentences == ["Hello."]
        assert remainder == "How are"

    def test_exclamation_mark(self):
        sentences, _ = _extract_sentences("Wow! ")
        assert sentences == ["Wow!"]

    def test_question_mark(self):
        sentences, _ = _extract_sentences("Really? ")
        assert sentences == ["Really?"]

    def test_closing_quote_after_period(self):
        sentences, _ = _extract_sentences('He said "ok." Next sentence. ')
        assert len(sentences) >= 1


# ── Prompt building ────────────────────────────────────────────────────────

class TestPromptBuilding:
    def test_prompt_contains_child_name(self):
        llm = make_pipeline()
        assert "Lily" in llm._system_prompt

    def test_prompt_contains_avatar_name(self):
        llm = make_pipeline()
        assert "Nova" in llm._system_prompt

    def test_level_instruction_appended_for_all_levels(self):
        for level in ["Pre A", "A", "B", "C1", "C2"]:
            llm = make_pipeline(level=level)
            assert "English level:" in llm._system_prompt, \
                f"Level instruction missing for '{level}'"

    def test_correction_guidance_present_for_all_levels(self):
        for level in ["Pre A", "A", "B", "C1", "C2"]:
            llm = make_pipeline(level=level)
            assert "orrection" in llm._system_prompt, \
                f"No correction guidance in prompt for level '{level}'"

    def test_set_level_changes_prompt(self):
        llm = make_pipeline(level="A")
        before = llm._system_prompt
        llm.set_level("C2")
        assert llm._system_prompt != before

    def test_set_level_preserves_base_content(self):
        llm = make_pipeline(level="A")
        llm.set_level("C1")
        assert "Lily" in llm._system_prompt
        assert "Nova" in llm._system_prompt

    def test_set_level_pre_a_is_gentle(self):
        llm = make_pipeline()
        llm.set_level("Pre A")
        assert "silent" in llm._system_prompt.lower() or \
               "never draw attention" in llm._system_prompt.lower()

    def test_set_level_c2_allows_directness(self):
        llm = make_pipeline()
        llm.set_level("C2")
        assert "directly" in llm._system_prompt.lower() or \
               "language partner" in llm._system_prompt.lower()

    def test_unknown_level_falls_back_to_base_prompt(self):
        llm = make_pipeline(level="A")
        llm.set_level("INVALID")
        # Base content still present, no crash
        assert "Lily" in llm._system_prompt


# ── Language lock ─────────────────────────────────────────────────────────

class TestLanguageLock:
    def test_language_lock_present_for_all_levels(self):
        from app.levels import LEVELS
        for level in LEVELS:
            llm = make_pipeline(level=level)
            assert "reply only in English" in llm._system_prompt, \
                f"language lock missing for level {level}"

    def test_language_lock_present_even_for_unknown_level(self):
        llm = make_pipeline(level="A")
        llm.set_level("INVALID")
        assert "reply only in English" in llm._system_prompt

    def test_language_lock_survives_memory_injection(self):
        from app.memory import ChildMemory, ChildProfile
        llm = make_pipeline()
        llm.set_memory(ChildMemory(profile=ChildProfile(name="Lily", age=8)))
        assert "reply only in English" in llm._system_prompt

    def test_language_lock_is_last_in_prompt(self):
        # Placed last so the small local model treats it as the final word.
        from app.levels import LANGUAGE_LOCK
        llm = make_pipeline()
        assert llm._system_prompt.rstrip().endswith(LANGUAGE_LOCK.rstrip())

    def test_language_lock_names_disguised_requests(self):
        # The lock should explicitly anticipate reframing tricks, not just ban
        # "speak Czech" — otherwise a small model rationalises the exceptions.
        from app.levels import LANGUAGE_LOCK
        low = LANGUAGE_LOCK.lower()
        assert "explain" in low and "just this once" in low


# ── set_memory ──────────────────────────────────────────────────────────

class TestSetMemory:
    def _memory_with_topics(self):
        from app.memory import ChildMemory, ChildProfile, Topic
        mem = ChildMemory(profile=ChildProfile(name="Lily", age=8))
        mem.topics = [Topic("football", 3, "2026-07-01"),
                      Topic("cats", 1, "2026-07-02")]
        return mem

    def _memory_with_problems(self):
        from app.memory import ChildMemory, ChildProfile, Problem
        mem = ChildMemory(profile=ChildProfile(name="Lily", age=8))
        mem.problems = [Problem("past_tense", "goed", "went", 2, "2026-07-01", False)]
        return mem

    def test_set_memory_none_leaves_prompt_unchanged(self):
        llm = make_pipeline()
        prompt_before = llm._system_prompt
        llm.set_memory(None)
        assert llm._system_prompt == prompt_before

    def test_set_memory_adds_name_to_prompt(self):
        llm = make_pipeline()
        from app.memory import ChildMemory, ChildProfile
        mem = ChildMemory(profile=ChildProfile(name="Lily", age=8))
        llm.set_memory(mem)
        assert "Lily" in llm._system_prompt

    def test_set_memory_adds_age_to_prompt(self):
        llm = make_pipeline()
        from app.memory import ChildMemory, ChildProfile
        mem = ChildMemory(profile=ChildProfile(name="Lily", age=8))
        llm.set_memory(mem)
        assert "8" in llm._system_prompt

    def test_set_memory_adds_topics_to_prompt(self):
        llm = make_pipeline()
        llm.set_memory(self._memory_with_topics())
        assert "football" in llm._system_prompt
        assert "cats" in llm._system_prompt

    def test_set_memory_adds_problems_to_prompt(self):
        llm = make_pipeline()
        llm.set_memory(self._memory_with_problems())
        assert "past_tense" in llm._system_prompt
        assert "goed" in llm._system_prompt
        assert "went" in llm._system_prompt

    def test_set_memory_then_set_level_both_present(self):
        llm = make_pipeline(level="B")
        from app.memory import ChildMemory, ChildProfile
        mem = ChildMemory(profile=ChildProfile(name="Lily"))
        llm.set_memory(mem)
        llm.set_level("C1")
        assert "C1" in llm._system_prompt
        assert "Lily" in llm._system_prompt

    def test_set_memory_rebuilds_on_second_call(self):
        llm = make_pipeline()
        from app.memory import ChildMemory, ChildProfile
        mem1 = ChildMemory(profile=ChildProfile(name="Lily"))
        mem2 = ChildMemory(profile=ChildProfile(name="Mia"))
        llm.set_memory(mem1)
        assert "Lily" in llm._system_prompt
        llm.set_memory(mem2)
        assert "Mia" in llm._system_prompt

    def test_set_memory_none_clears_memory_block(self):
        llm = make_pipeline()
        from app.memory import ChildMemory, ChildProfile, Topic
        mem = ChildMemory(profile=ChildProfile(name="Lily"))
        mem.topics = [Topic("football", 1, "2026-07-01")]
        llm.set_memory(mem)
        assert "football" in llm._system_prompt
        llm.set_memory(None)
        assert "football" not in llm._system_prompt


# ── Temporal memory context ────────────────────────────────────────────────

class TestMemoryTemporal:
    """The memory block must anchor 'today' and tag mentions with relative time
    so the model can naturally say things like 'yesterday we talked about...'."""

    def _mem(self):
        from app.memory import ChildMemory, ChildProfile, Topic, Problem
        today = date.today()
        mem = ChildMemory(profile=ChildProfile(name="Lily", age=8))
        mem.topics = [
            Topic("football", 3, (today - timedelta(days=1)).isoformat()),
            Topic("cats", 1, (today - timedelta(days=5)).isoformat()),
        ]
        mem.problems = [
            Problem("past_tense", "goed", "went", 2,
                    (today - timedelta(days=1)).isoformat(), False),
        ]
        return mem

    def test_prompt_includes_today_anchor(self):
        llm = make_pipeline()
        llm.set_memory(self._mem())
        assert "Today is" in llm._system_prompt
        assert date.today().strftime("%A") in llm._system_prompt

    def test_topic_tagged_with_relative_time(self):
        llm = make_pipeline()
        llm.set_memory(self._mem())
        # football was mentioned yesterday
        assert "yesterday" in llm._system_prompt.lower()

    def test_topic_keyword_still_present(self):
        llm = make_pipeline()
        llm.set_memory(self._mem())
        assert "football" in llm._system_prompt
        assert "cats" in llm._system_prompt

    def test_challenge_tagged_with_relative_time(self):
        llm = make_pipeline()
        llm.set_memory(self._mem())
        # problem last seen yesterday → the relative tag appears near the challenge
        block = llm._system_prompt
        assert "past_tense" in block
        assert "yesterday" in block.lower()

    def test_guidance_encourages_temporal_reference(self):
        llm = make_pipeline()
        llm.set_memory(self._mem())
        low = llm._system_prompt.lower()
        assert "yesterday" in low  # example phrasing offered to the model
        assert "when" in low or "ago" in low

    def test_no_anchor_when_memory_absent(self):
        llm = make_pipeline()
        assert "Today is" not in llm._system_prompt


# ── Conversation history ───────────────────────────────────────────────────

class TestHistory:
    def test_history_is_empty_on_init(self):
        llm = make_pipeline()
        assert llm._history == []

    def test_clear_history_empties_list(self):
        llm = make_pipeline()
        llm._history = [{"role": "user", "content": "hi"}]
        llm.clear_history()
        assert llm._history == []

    def test_trim_keeps_last_n_exchanges(self):
        llm = make_pipeline()
        limit = llm._config.models.llm.conversation_buffer_exchanges  # 6
        for i in range(10):
            llm._history.append({"role": "user",      "content": f"u{i}"})
            llm._history.append({"role": "assistant",  "content": f"a{i}"})
        llm._trim_history()
        assert len(llm._history) == limit * 2

    def test_trim_preserves_most_recent_exchange(self):
        llm = make_pipeline()
        for i in range(10):
            llm._history.append({"role": "user",      "content": f"u{i}"})
            llm._history.append({"role": "assistant",  "content": f"a{i}"})
        llm._trim_history()
        # Last exchange must be u9/a9
        assert llm._history[-2]["content"] == "u9"
        assert llm._history[-1]["content"] == "a9"


# ── Pattern-review injection ───────────────────────────────────────────────

class TestPatternReviewInjection:
    """The hint must appear every N turns, never before turn 1."""

    def _build_messages(self, llm: LLMPipeline, turns: int) -> list[dict]:
        """Reproduce the message-building logic from chat() at a given turn count."""
        llm._history.clear()
        for i in range(turns):
            llm._history.append({"role": "user",      "content": f"u{i}"})
            llm._history.append({"role": "assistant",  "content": f"a{i}"})
        turn = len(llm._history) // 2
        messages = [{"role": "system", "content": llm._system_prompt}]
        if turn > 0 and turn % _PATTERN_REVIEW_INTERVAL == 0:
            messages.append({"role": "system", "content": _PATTERN_REVIEW_HINT})
        messages.extend(llm._history)
        return messages

    def _hint_present(self, messages: list) -> bool:
        return any(
            m["role"] == "system" and _PATTERN_REVIEW_HINT in m.get("content", "")
            for m in messages
        )

    def test_hint_absent_at_turn_zero(self):
        llm = make_pipeline()
        assert not self._hint_present(self._build_messages(llm, 0))

    def test_hint_absent_before_first_interval(self):
        llm = make_pipeline()
        for t in range(1, _PATTERN_REVIEW_INTERVAL):
            assert not self._hint_present(self._build_messages(llm, t)), \
                f"Hint wrongly present at turn {t}"

    def test_hint_present_at_first_interval(self):
        llm = make_pipeline()
        msgs = self._build_messages(llm, _PATTERN_REVIEW_INTERVAL)
        assert self._hint_present(msgs)

    def test_hint_present_at_second_interval(self):
        llm = make_pipeline()
        msgs = self._build_messages(llm, _PATTERN_REVIEW_INTERVAL * 2)
        assert self._hint_present(msgs)

    def test_hint_content_mentions_warmth(self):
        assert "warmly" in _PATTERN_REVIEW_HINT.lower()

    def test_hint_does_not_demand_correction_always(self):
        """Hint should allow the LLM to skip correction if no pattern found."""
        assert "naturally" in _PATTERN_REVIEW_HINT.lower() or \
               "if no" in _PATTERN_REVIEW_HINT.lower() or \
               "if not" in _PATTERN_REVIEW_HINT.lower()


# ── Chat method (mocked Ollama) ────────────────────────────────────────────

class TestChatMocked:
    def test_yields_sentences_from_stream(self):
        llm = make_pipeline()
        with patch("ollama.chat", return_value=fake_stream("Hello there.", "How are you?")):
            result = list(llm.chat("Hi"))
        assert any("Hello" in s for s in result)

    def test_appends_user_and_assistant_to_history(self):
        llm = make_pipeline()
        with patch("ollama.chat", return_value=fake_stream("Good!")):
            list(llm.chat("Hi"))
        assert len(llm._history) == 2
        assert llm._history[0] == {"role": "user", "content": "Hi"}
        assert llm._history[1]["role"] == "assistant"

    def test_rolls_back_history_on_error(self):
        llm = make_pipeline()
        with patch("ollama.chat", side_effect=Exception("connection refused")):
            with pytest.raises(RuntimeError, match="connection refused"):
                list(llm.chat("Hello"))
        assert llm._history == []

    def test_second_turn_grows_history(self):
        llm = make_pipeline()
        with patch("ollama.chat", return_value=fake_stream("Good!")):
            list(llm.chat("Hi"))
        with patch("ollama.chat", return_value=fake_stream("Nice!")):
            list(llm.chat("How are you?"))
        assert len(llm._history) == 4


# ── Appearance injection ──────────────────────────────────────────────────────

class TestAppearanceInjection:
    def test_no_appearance_block_by_default(self):
        pipe = make_pipeline()
        assert "how you look" not in pipe._system_prompt.lower()

    def test_set_appearance_adds_block_before_language_lock(self):
        pipe = make_pipeline()
        pipe.set_appearance("You have brown hair and a red top.")
        prompt = pipe._system_prompt
        assert "You have brown hair and a red top." in prompt
        # Appearance must come before the non-negotiable language lock.
        assert prompt.index("brown hair") < prompt.index(LANGUAGE_LOCK)

    def test_set_appearance_none_removes_block(self):
        pipe = make_pipeline()
        pipe.set_appearance("You have brown hair and a red top.")
        pipe.set_appearance(None)
        assert "brown hair" not in pipe._system_prompt

    def test_appearance_survives_level_change(self):
        pipe = make_pipeline()
        pipe.set_appearance("You have brown hair.")
        pipe.set_level("B")
        assert "brown hair" in pipe._system_prompt

    def test_appearance_survives_memory_change(self):
        pipe = make_pipeline()
        pipe.set_appearance("You have brown hair.")
        from app.memory import ChildMemory, ChildProfile
        mem = ChildMemory(profile=ChildProfile(name="Lily", age=8))
        pipe.set_memory(mem)
        assert "brown hair" in pipe._system_prompt
