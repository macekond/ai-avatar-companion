"""Per-session telemetry logging.

Writes one JSONL file per session to the configured log directory.
Each line is a JSON event (session_start, turn, didnt_catch, session_end).

File naming:
  ~/.ai-avatar/logs/2026-07-06_lily_143052.jsonl

Event types
-----------
session_start:
  ts, event, session_id, profile, level, is_onboarding

turn:
  ts, event, session_id, profile, turn_n, level
  child_said, avatar_said, word_count
  stt_ms, llm_ttft_ms, total_ms
  topic, problem, engaged, reengagement_fired

didnt_catch:
  ts, event, session_id, profile, turn_n

session_end:
  ts, event, session_id, profile, duration_s
  turns, didnt_catch_count, reengagement_count
  avg_word_count, avg_total_ms, avg_stt_ms, avg_llm_ttft_ms
  engaged_turns, engaged_ratio
  topics, problems

Usage:
    session = TelemetrySession(config.telemetry.log_dir, slug)
    session.start(level="A", is_onboarding=False)
    session.log_turn(
        transcript="I goed to school",
        reply="Oh, you went to school!",
        stt_ms=380, llm_ttft_ms=710, total_ms=2940,
        level="A", topic="school",
        problem="past_tense: goed -> went",
        engaged=True, reengagement_fired=False,
    )
    session.log_didnt_catch()
    session.end()
"""
from __future__ import annotations

import json
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional


def _now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


class TelemetrySession:
    """Records all events for one child session to a JSONL file."""

    def __init__(self, log_dir: str | Path, slug: str) -> None:
        self._dir = Path(log_dir).expanduser()
        self._slug = slug
        self._session_id = str(uuid.uuid4())[:8]
        self._file: Optional[Path] = None
        self._fh = None

        # Aggregation state
        self._start_ts: Optional[datetime] = None
        self._turn_n = 0
        self._didnt_catch_count = 0
        self._reengagement_count = 0
        self._word_counts: list[int] = []
        self._total_ms_list: list[int] = []
        self._stt_ms_list: list[int] = []
        self._llm_ttft_ms_list: list[int] = []
        self._engaged_turns = 0
        self._topics: list[str] = []
        self._problems: list[str] = []
        self._level = "A"

    # ------------------------------------------------------------------
    # Lifecycle
    # ------------------------------------------------------------------

    def start(self, level: str = "A", is_onboarding: bool = False) -> None:
        """Open the log file and write the session_start event."""
        self._dir.mkdir(parents=True, exist_ok=True)
        now = datetime.now()
        filename = f"{now.strftime('%Y-%m-%d')}_{self._slug}_{now.strftime('%H%M%S')}.jsonl"
        self._file = self._dir / filename
        self._fh = open(self._file, "a", encoding="utf-8")
        self._start_ts = datetime.now(timezone.utc)
        self._level = level
        self._write({
            "ts": _now(),
            "event": "session_start",
            "session_id": self._session_id,
            "profile": self._slug,
            "level": level,
            "is_onboarding": is_onboarding,
        })

    def end(self) -> None:
        """Write the session_end summary event and close the file."""
        if self._fh is None:
            return

        duration_s = 0
        if self._start_ts:
            duration_s = int(
                (datetime.now(timezone.utc) - self._start_ts).total_seconds()
            )

        def avg(lst: list[int]) -> Optional[float]:
            return round(sum(lst) / len(lst), 1) if lst else None

        self._write({
            "ts": _now(),
            "event": "session_end",
            "session_id": self._session_id,
            "profile": self._slug,
            "duration_s": duration_s,
            "turns": self._turn_n,
            "didnt_catch_count": self._didnt_catch_count,
            "reengagement_count": self._reengagement_count,
            "avg_word_count": avg(self._word_counts),
            "avg_total_ms": avg(self._total_ms_list),
            "avg_stt_ms": avg(self._stt_ms_list),
            "avg_llm_ttft_ms": avg(self._llm_ttft_ms_list),
            "engaged_turns": self._engaged_turns,
            "engaged_ratio": (
                round(self._engaged_turns / self._turn_n, 2)
                if self._turn_n else None
            ),
            "topics": list(dict.fromkeys(self._topics)),    # ordered, deduped
            "problems": list(dict.fromkeys(self._problems)),
        })
        self._fh.close()
        self._fh = None

    # ------------------------------------------------------------------
    # Event logging
    # ------------------------------------------------------------------

    def log_turn(
        self,
        transcript: str,
        reply: str,
        *,
        stt_ms: int,
        llm_ttft_ms: int,
        total_ms: int,
        level: str = "A",
        topic: Optional[str] = None,
        problem: Optional[str] = None,
        engaged: bool = True,
        reengagement_fired: bool = False,
    ) -> None:
        """Log one complete child→avatar exchange."""
        self._turn_n += 1
        wc = len(transcript.split()) if transcript else 0

        # Aggregate
        self._word_counts.append(wc)
        self._total_ms_list.append(total_ms)
        self._stt_ms_list.append(stt_ms)
        self._llm_ttft_ms_list.append(llm_ttft_ms)
        if engaged:
            self._engaged_turns += 1
        if reengagement_fired:
            self._reengagement_count += 1
        if topic:
            self._topics.append(topic)
        if problem:
            self._problems.append(problem)

        self._write({
            "ts": _now(),
            "event": "turn",
            "session_id": self._session_id,
            "profile": self._slug,
            "turn_n": self._turn_n,
            "level": level,
            "child_said": transcript,
            "avatar_said": reply,
            "word_count": wc,
            "stt_ms": stt_ms,
            "llm_ttft_ms": llm_ttft_ms,
            "total_ms": total_ms,
            "topic": topic,
            "problem": problem,
            "engaged": engaged,
            "reengagement_fired": reengagement_fired,
        })

    def log_didnt_catch(self) -> None:
        """Log an STT failure (no usable transcript)."""
        self._didnt_catch_count += 1
        self._write({
            "ts": _now(),
            "event": "didnt_catch",
            "session_id": self._session_id,
            "profile": self._slug,
            "turn_n": self._turn_n,
        })

    # ------------------------------------------------------------------
    # Internal
    # ------------------------------------------------------------------

    def _write(self, event: dict) -> None:
        if self._fh:
            self._fh.write(json.dumps(event, ensure_ascii=False) + "\n")
            self._fh.flush()

    @property
    def session_id(self) -> str:
        return self._session_id

    @property
    def log_file(self) -> Optional[Path]:
        return self._file
