"""Post-turn memory extractor.

After each full exchange (child transcript + avatar reply), runs a tiny
focused Ollama call to extract:
  - Main topic keyword (1-3 words or "none")
  - Grammar problem observed (type: example → correction, or "none")
  - Whether the child seemed engaged (yes/no)

The call is non-streaming, uses temperature=0 for deterministic output,
and is capped at 40 tokens — it completes in < 300 ms and runs after TTS
finishes, so it never appears on the latency-critical path.

Usage:
    extractor = MemoryExtractor("llama3.2:3b")
    result = extractor.extract(transcript, reply)
    if result.topic:
        manager.update_topic(memory, result.topic)
    parsed = result.parse_problem()
    if parsed:
        type_, example, correction = parsed
        manager.update_problem(memory, type_, example, correction)
"""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import Optional


_EXTRACTION_PROMPT = """\
Analyze this English learning conversation turn.

Child said: "{transcript}"
Avatar replied: "{reply}"

Reply in EXACTLY this format (3 lines, nothing else):
TOPIC: <main topic keyword 1-3 words, or none>
PROBLEM: <error_type: child_said -> correction, or none>
ENGAGED: <yes or no>

Examples:
TOPIC: football
PROBLEM: past_tense: goed -> went
ENGAGED: yes

TOPIC: none
PROBLEM: none
ENGAGED: no"""


# ---------------------------------------------------------------------------
# Result dataclass
# ---------------------------------------------------------------------------

@dataclass
class ExtractionResult:
    """Parsed result from a post-turn extraction call."""
    topic: Optional[str] = None          # lowercased keyword, or None
    problem_raw: Optional[str] = None    # "type: example -> correction", or None
    engaged: bool = True

    def parse_problem(self) -> Optional[tuple[str, str, str]]:
        """Return (type, example, correction) parsed from problem_raw, or None.

        Accepts both "→" and "->" as separator.
        """
        if not self.problem_raw:
            return None
        raw = self.problem_raw
        if ":" not in raw:
            return None

        type_part, rest = raw.split(":", 1)
        rest = rest.strip()

        # Accept both → and ->
        if "→" in rest:
            parts = rest.split("→", 1)
        elif "->" in rest:
            parts = rest.split("->", 1)
        else:
            return None

        if len(parts) != 2:
            return None

        return (
            type_part.strip(),
            parts[0].strip().strip("'\"`"),
            parts[1].strip().strip("'\"`"),
        )


# ---------------------------------------------------------------------------
# Extractor
# ---------------------------------------------------------------------------

class MemoryExtractor:
    """Runs a focused Ollama call to extract topics and grammar problems."""

    def __init__(self, model: str, temperature: float = 0.0) -> None:
        self._model = model
        self._temperature = temperature

    def extract(self, transcript: str, reply: str) -> ExtractionResult:
        """Extract a topic and any grammar problem from one conversation turn.

        Returns safe defaults (no topic, no problem, engaged=True) on any
        error so failures are silent and never block the conversation.
        """
        import ollama

        prompt = _EXTRACTION_PROMPT.format(
            transcript=transcript.strip(),
            reply=reply.strip(),
        )
        try:
            response = ollama.chat(
                model=self._model,
                messages=[{"role": "user", "content": prompt}],
                stream=False,
                options={
                    "temperature": self._temperature,
                    "num_predict": 40,
                },
            )
            text = self._get_content(response)
            return self._parse(text)
        except Exception:
            return ExtractionResult()   # silent failure → safe defaults

    # ------------------------------------------------------------------
    # Internals
    # ------------------------------------------------------------------

    @staticmethod
    def _get_content(response) -> str:
        try:
            return response.message.content or ""
        except AttributeError:
            return (response.get("message") or {}).get("content") or ""

    @staticmethod
    def _parse(text: str) -> ExtractionResult:
        result = ExtractionResult()
        for line in text.strip().splitlines():
            line = line.strip()
            upper = line.upper()
            if upper.startswith("TOPIC:"):
                val = line[6:].strip().lower()
                if val and val != "none":
                    result.topic = val
            elif upper.startswith("PROBLEM:"):
                val = line[8:].strip().lower()
                if val and val != "none":
                    result.problem_raw = val
            elif upper.startswith("ENGAGED:"):
                val = line[8:].strip().lower()
                result.engaged = not val.startswith("n")
        return result
