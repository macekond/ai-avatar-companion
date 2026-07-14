"""LLM pipeline stage: streams sentences from Ollama.

This module is the backbone of the full pipeline. Even in the Phase 1
text-only prototype, chat() yields *sentences* (not tokens), so the caller
can feed each sentence to TTS as soon as it is ready — without waiting for
the full reply. The same interface will be used unchanged in later phases.

Usage:
    pipeline = LLMPipeline(config)
    for sentence in pipeline.chat("What's your favourite animal?"):
        print(sentence)          # or: tts.speak(sentence)
"""
from __future__ import annotations

import re
from collections.abc import Iterator
from datetime import date
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from app.config import Config

from app.levels import LANGUAGE_LOCK, instructions_for
from app.memory import humanize_since, today_context

# ---------------------------------------------------------------------------
# Sentence boundary detection
# ---------------------------------------------------------------------------
# Splits on ". ", "! ", "? " and their variants with closing punctuation.
# Phase 1 limitation: abbreviations (Mr., Dr.) and ellipsis (...) will cause
# incorrect splits. A spaCy/NLTK sentencizer is the Phase 3+ upgrade path.
_SENTENCE_END = re.compile(r'(?<=[.!?])["\')»]?\s+')


def _extract_sentences(buffer: str) -> tuple[list[str], str]:
    """Split *buffer* at sentence boundaries.

    Returns (complete_sentences, remaining_fragment).
    The fragment has no terminating punctuation yet and should be held
    until more tokens arrive (or the stream ends).
    """
    parts = _SENTENCE_END.split(buffer)
    if len(parts) > 1:
        return parts[:-1], parts[-1]
    return [], buffer


# ---------------------------------------------------------------------------
# Pipeline
# ---------------------------------------------------------------------------

# Inject a pattern-review hint to the LLM every N conversation turns.
# This costs nothing extra — it’s just one more system message in the
# messages list. The LLM uses its own conversation history to decide
# whether any mistake has actually repeated.
_PATTERN_REVIEW_INTERVAL = 5
_PATTERN_REVIEW_HINT = (
    "Before replying, silently review the conversation history. "
    "If the child has made the same grammatical mistake two or more times, "
    "address it once in your reply — warmly, briefly, as a friendly tip. "
    "If no pattern stands out, simply continue the conversation naturally."
)


class LLMPipeline:
    """Wraps Ollama streaming to yield reply sentences one at a time.

    The rolling conversation history is kept in memory for the lifetime of
    this object. Call clear_history() to start a fresh session without
    reloading the config.
    """

    def __init__(self, config: Config) -> None:
        self._config = config
        self._base_prompt = config.format_system_prompt()
        self._memory = None
        self._system_prompt = self._build_prompt(config.child.level)
        self._history: list[dict[str, str]] = []
        self._pending_hint: str | None = None   # one-shot extra system message

    def _build_prompt(self, level: str, memory=None) -> str:
        parts = [self._base_prompt]
        instruction = instructions_for(level)
        if instruction:
            parts.append(instruction)
        if memory is not None:
            parts.append(self._format_memory_block(memory))
        # Always last: the non-negotiable "reply only in English" rule. Placed
        # after everything else so the model treats it as the final word.
        parts.append(LANGUAGE_LOCK)
        return "\n\n".join(parts)

    def set_level(self, level: str) -> None:
        """Switch the CEFR level. Takes effect from the next turn."""
        self._system_prompt = self._build_prompt(level, self._memory)

    def set_hint(self, hint: str | None) -> None:
        """Set a one-shot system hint injected into the next chat() call then cleared."""
        self._pending_hint = hint

    def set_memory(self, memory) -> None:
        """Inject (or clear) the child's memory context in the system prompt.

        Pass a ChildMemory instance to add a personalised memory block.
        Pass None to remove it (base prompt + level only).
        Takes effect from the next turn.
        """
        self._memory = memory
        self._system_prompt = self._build_prompt(self._config.child.level, memory)

    @staticmethod
    def _format_memory_block(memory) -> str:
        """Render a concise memory context block for the system prompt.

        Each remembered topic/challenge is tagged with how long ago it came
        up (relative to today), and the block opens with today's date. This
        gives the model the temporal awareness kids enjoy — "today is
        Saturday", "yesterday we talked about football".
        """
        profile = memory.profile
        age_str = f" (age {profile.age})" if profile.age else ""
        lines = [
            f"Today is {today_context()}.",
            f"Memory about {profile.name}{age_str}:",
        ]

        if memory.topics:
            recent = sorted(
                memory.topics,
                key=lambda t: t.last_mentioned,
                reverse=True,
            )[:5]
            lines.append("- Recent topics of interest: " + ", ".join(
                f"{t.keyword} ({humanize_since(t.last_mentioned)})"
                for t in recent
            ))

        unresolved = [p for p in memory.problems if not p.resolved]
        if unresolved:
            top = sorted(unresolved, key=lambda p: p.times_seen, reverse=True)[:3]
            details = "; ".join(
                f"{p.type} (e.g. '{p.example}' → '{p.correction}', "
                f"came up {humanize_since(p.last_seen)})"
                for p in top
            )
            lines.append(f"- Known language challenges: {details}")

        # Only prompt the model to reference *when* things came up if there is
        # actually remembered history. Emitting this for a freshly onboarded
        # child (no topics, no challenges) primes it to invent a shared past
        # ("yesterday you told me about…") on the very first conversation.
        if memory.topics or unresolved:
            lines.append(
                "- You know when each of these came up, so refer to it naturally "
                "when it fits (e.g. \"yesterday you told me about...\", \"happy "
                f"{date.today().strftime('%A')}!\") — kids love talking about today, "
                "yesterday and what's coming up."
            )

        hints = []
        if memory.topics:
            newest = sorted(
                memory.topics, key=lambda t: t.last_mentioned, reverse=True
            )[0]
            hints.append(f"ask about {newest.keyword}")
        if unresolved:
            worst = sorted(unresolved, key=lambda p: p.times_seen, reverse=True)[0]
            hints.append(f"practise {worst.type} with a fun example")
        if hints:
            lines.append(
                f"- If {profile.name} is quiet, you can: " + ", or ".join(hints) + "."
            )

        return "\n".join(lines)

    # ------------------------------------------------------------------
    # Public API
    # ------------------------------------------------------------------

    def chat(self, user_message: str) -> Iterator[str]:
        """Yield reply sentences as they stream from the LLM.

        The first sentence is yielded as soon as Ollama produces enough
        tokens to complete it — the caller does not have to wait for the
        full reply. Subsequent sentences follow as generation continues.

        Raises RuntimeError on connection failure or model error so the
        caller can show a friendly "brain is napping" state.
        """
        import ollama  # imported lazily so the module loads without Ollama installed

        self._history.append({"role": "user", "content": user_message})

        # Periodically inject a pattern-review hint so the LLM actively
        # checks whether any grammatical mistake has been repeated.
        turn = len(self._history) // 2  # complete exchanges so far
        messages: list[dict[str, str]] = [{"role": "system", "content": self._system_prompt}]
        if turn > 0 and turn % _PATTERN_REVIEW_INTERVAL == 0:
            messages.append({"role": "system", "content": _PATTERN_REVIEW_HINT})
        if self._pending_hint:
            messages.append({"role": "system", "content": self._pending_hint})
            self._pending_hint = None  # consume after first use
        messages.extend(self._history)

        buffer = ""
        full_response = ""

        try:
            stream = ollama.chat(
                model=self._config.models.llm.model,
                messages=messages,
                stream=True,
                options={
                    "temperature": self._config.models.llm.temperature,
                    "num_predict": self._config.models.llm.max_response_tokens,
                },
            )

            for chunk in stream:
                token = self._token(chunk)
                if not token:
                    continue
                buffer += token
                full_response += token

                sentences, buffer = _extract_sentences(buffer)
                yield from sentences

        except Exception as exc:
            # Roll back the user turn we already appended so history stays consistent
            self._history.pop()
            raise RuntimeError(str(exc)) from exc

        # Emit whatever is left in the buffer (final fragment, no trailing punctuation)
        remainder = buffer.strip()
        if remainder:
            yield remainder

        self._history.append({"role": "assistant", "content": full_response.strip()})
        self._trim_history()

    def clear_history(self) -> None:
        """Wipe the conversation buffer (start a new session)."""
        self._history.clear()

    # ------------------------------------------------------------------
    # Internals
    # ------------------------------------------------------------------

    def _trim_history(self) -> None:
        """Keep only the last N exchange pairs (user + assistant)."""
        max_turns = self._config.models.llm.conversation_buffer_exchanges * 2
        if len(self._history) > max_turns:
            self._history = self._history[-max_turns:]

    @staticmethod
    def _token(chunk) -> str:
        """Extract the text token from a streaming chunk.

        Handles both the object-style API (ollama ≥ 0.3) and the older
        dict-style API, so the code works across library versions.
        """
        try:
            return chunk.message.content or ""
        except AttributeError:
            return (chunk.get("message") or {}).get("content") or ""
