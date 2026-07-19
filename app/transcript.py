"""Persistent conversation history for a child's profile.

Conversation turns (child line + avatar reply, plus any gentle correction) used
to live only in the browser tab, so a relaunch or crash lost the whole history.
TranscriptStore writes each turn to disk as it happens and replays it on the
next connect, so the transcript panel survives restarts.

One append-only JSONL file per child — mirroring MemoryManager's one-file-per-
child layout, but kept separate because it grows per turn and is display-only
(never fed back into the prompt):

  transcripts/lily.jsonl
  transcripts/mia.jsonl

Records are line-delimited JSON, one of:
  {"kind": "turn", "id": 1, "you": "...", "nova": "..."}
  {"kind": "correction", "id": 1, "correction_kind": "past_tense",
   "wrong": "goed", "right": "went"}

Usage:
    store = TranscriptStore("~/.ai-avatar/transcripts/", "lily")
    store.append_turn(1, "I goed to school", "You went to school!")
    store.append_correction(1, "past_tense", "goed", "went")
    turns = store.load()   # [{"id": 1, "you": ..., "nova": ..., "corrections": [...]}]
"""
from __future__ import annotations

import json
import logging
from pathlib import Path

log = logging.getLogger(__name__)


class TranscriptStore:
    """Append-only per-child conversation history on disk."""

    def __init__(self, transcripts_dir: str | Path, slug: str) -> None:
        self._dir = Path(transcripts_dir).expanduser()
        self._slug = slug
        self._path = self._dir / f"{slug}.jsonl"
        # Set by delete(): a fire-and-forget extraction task can outlive the
        # drain and still hold this instance, so a late append_correction must
        # not recreate a file the parent just removed (cf. MemoryManager's
        # deleted-slug tombstone — "deletion must stick").
        self._deleted = False

    # ------------------------------------------------------------------
    # Writing
    # ------------------------------------------------------------------

    def append_turn(self, turn_id: int, you: str, nova: str) -> None:
        self._append({"kind": "turn", "id": turn_id, "you": you, "nova": nova})

    def append_correction(
        self, turn_id: int, correction_kind: str, wrong: str, right: str
    ) -> None:
        self._append({
            "kind": "correction", "id": turn_id,
            "correction_kind": correction_kind, "wrong": wrong, "right": right,
        })

    def _append(self, record: dict) -> None:
        if self._deleted:
            return   # profile removed — a straggling write must not resurrect it
        try:
            self._dir.mkdir(parents=True, exist_ok=True)
            with open(self._path, "a", encoding="utf-8") as f:
                # ensure_ascii=False keeps Japanese (and other non-ASCII) text
                # readable on disk instead of \uXXXX escapes, matching
                # MemoryManager.save(). Round-trips identically either way.
                f.write(json.dumps(record, ensure_ascii=False) + "\n")
        except Exception as exc:
            # History is a nicety, never worth crashing a turn over.
            log.debug("Transcript append failed (non-fatal): %s", exc)

    # ------------------------------------------------------------------
    # Reading
    # ------------------------------------------------------------------

    def load(self) -> list[dict]:
        """Return ordered turns with their corrections applied.

        Each entry: {"id", "you", "nova", "corrections": [{"kind","wrong","right"}]}.
        A missing file yields []; malformed or unknown lines are skipped.
        """
        if not self._path.exists():
            return []
        turns: dict[int, dict] = {}
        order: list[int] = []
        try:
            with open(self._path, encoding="utf-8") as f:
                for line in f:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        rec = json.loads(line)
                    except ValueError:
                        continue
                    self._apply(rec, turns, order)
        except Exception as exc:
            log.debug("Transcript load failed (non-fatal): %s", exc)
            return []
        return [turns[i] for i in order]

    @staticmethod
    def _apply(rec: dict, turns: dict[int, dict], order: list[int]) -> None:
        tid = rec.get("id")
        if not isinstance(tid, int):
            return
        if rec.get("kind") == "turn":
            if tid not in turns:
                order.append(tid)
            turns[tid] = {
                "id": tid,
                "you": rec.get("you", ""),
                "nova": rec.get("nova", ""),
                "corrections": turns.get(tid, {}).get("corrections", []),
            }
        elif rec.get("kind") == "correction":
            entry = turns.get(tid)
            if entry is None:
                return   # correction for an unknown turn — ignore
            entry["corrections"].append({
                "kind": rec.get("correction_kind", ""),
                "wrong": rec.get("wrong", ""),
                "right": rec.get("right", ""),
            })

    def last_id(self) -> int:
        """Highest turn id on record, or 0 when there's no history."""
        return max((t["id"] for t in self.load()), default=0)

    # ------------------------------------------------------------------
    # Removal
    # ------------------------------------------------------------------

    def delete(self) -> None:
        """Remove this child's history and tombstone the instance.

        Tombstoning matters because a late extraction task may still hold this
        instance: after delete() its appends no-op, so the removed file can't
        come back (and a reused slug can't inherit a stale correction).
        """
        self._deleted = True
        try:
            self._path.unlink(missing_ok=True)
        except Exception as exc:
            log.debug("Transcript delete failed (non-fatal): %s", exc)
