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
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from app.config import Config

from app.levels import instructions_for

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

class LLMPipeline:
    """Wraps Ollama streaming to yield reply sentences one at a time.

    The rolling conversation history is kept in memory for the lifetime of
    this object. Call clear_history() to start a fresh session without
    reloading the config.
    """

    def __init__(self, config: Config) -> None:
        self._config = config
        self._base_prompt = config.format_system_prompt()
        self._system_prompt = self._build_prompt(config.child.level)
        self._history: list[dict[str, str]] = []

    def _build_prompt(self, level: str) -> str:
        instruction = instructions_for(level)
        if instruction:
            return f"{self._base_prompt}\n\n{instruction}"
        return self._base_prompt

    def set_level(self, level: str) -> None:
        """Switch the CEFR level. Takes effect from the next turn."""
        self._system_prompt = self._build_prompt(level)

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

        messages = [
            {"role": "system", "content": self._system_prompt},
            *self._history,
        ]

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
