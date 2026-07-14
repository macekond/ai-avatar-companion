"""Persistent memory for a child's profile, topics, and language challenges.

Files live in ~/.ai-avatar/profiles/{slug}.json — completely separate from
config.yaml. config.yaml's child.name is only a default profile selector
(a pointer), never a store for memory data.

One JSON file per child:
  profiles/lily.json   ← Lily's profile, topics, problems
  profiles/mia.json    ← Mia's separate profile

Usage:
    mgr = MemoryManager("~/.ai-avatar/profiles/", "lily")
    memory = mgr.load()          # None on first run
    if memory is None:
        memory = ChildMemory(profile=ChildProfile(name="Lily", age=8))
    mgr.update_topic(memory, "football")
    mgr.prune(memory)
    mgr.save(memory)
"""
from __future__ import annotations

import json
import re
from dataclasses import dataclass, field, asdict
from datetime import date, timedelta
from pathlib import Path
from typing import Optional


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def name_to_slug(name: str) -> str:
    """Convert a display name to a filesystem-safe slug.

    Examples:
        "Lily"       → "lily"
        "Mary Kate"  → "mary_kate"
        "Björn"      → "bjrn"   (non-ASCII stripped)
    """
    s = name.lower().strip()
    s = re.sub(r"\s+", "_", s)
    s = re.sub(r"[^a-z0-9_]", "", s)
    return s or "child"


def _today() -> str:
    return date.today().isoformat()


# ---------------------------------------------------------------------------
# Data model
# ---------------------------------------------------------------------------

@dataclass
class ChildProfile:
    name: str
    age: Optional[int] = None
    first_session_date: str = field(default_factory=_today)


@dataclass
class Topic:
    keyword: str
    mention_count: int = 1
    last_mentioned: str = field(default_factory=_today)


@dataclass
class Problem:
    """A recurring language difficulty observed during conversations."""
    type: str         # e.g. "past_tense", "article", "vocabulary", "modal"
    example: str      # what the child said, e.g. "goed"
    correction: str   # correct form, e.g. "went"
    times_seen: int = 1
    last_seen: str = field(default_factory=_today)
    resolved: bool = False


@dataclass
class ChildMemory:
    """Root memory object — one instance per child profile."""
    profile: ChildProfile
    topics: list[Topic] = field(default_factory=list)
    problems: list[Problem] = field(default_factory=list)
    last_updated: str = field(default_factory=_today)

    # ------------------------------------------------------------------
    # Serialization
    # ------------------------------------------------------------------

    def to_dict(self) -> dict:
        return asdict(self)

    @classmethod
    def from_dict(cls, data: dict) -> "ChildMemory":
        profile = ChildProfile(**data["profile"])
        topics = [Topic(**t) for t in data.get("topics", [])]
        problems = [Problem(**p) for p in data.get("problems", [])]
        return cls(
            profile=profile,
            topics=topics,
            problems=problems,
            last_updated=data.get("last_updated", _today()),
        )


# ---------------------------------------------------------------------------
# Memory manager
# ---------------------------------------------------------------------------

class MemoryManager:
    """Loads, saves, and maintains a single child's memory file.

    Args:
        profiles_dir: Directory where profile JSON files live.
        slug:         Profile slug (filename without .json).
        max_topics:   Maximum number of topics to keep after pruning.
        max_problems: Maximum number of problems to keep after pruning.
        topic_ttl_days:    Days before an un-mentioned topic expires.
        problem_ttl_days:  Days before an unresolved problem expires.
    """

    _RESOLVED_TTL_DAYS = 7   # resolved problems expire quickly

    def __init__(
        self,
        profiles_dir: str | Path,
        slug: str,
        max_topics: int = 20,
        max_problems: int = 15,
        topic_ttl_days: int = 14,
        problem_ttl_days: int = 30,
    ) -> None:
        self._dir = Path(profiles_dir).expanduser()
        self._slug = slug
        self._path = self._dir / f"{slug}.json"
        self._max_topics = max_topics
        self._max_problems = max_problems
        self._topic_ttl = topic_ttl_days
        self._problem_ttl = problem_ttl_days

    @property
    def slug(self) -> str:
        return self._slug

    # ------------------------------------------------------------------
    # Persistence
    # ------------------------------------------------------------------

    def load(self) -> Optional[ChildMemory]:
        """Return the stored ChildMemory, or None if no file exists."""
        if not self._path.exists():
            return None
        try:
            with open(self._path, encoding="utf-8") as f:
                return ChildMemory.from_dict(json.load(f))
        except Exception:
            return None   # corrupt file treated as missing

    def save(self, memory: ChildMemory) -> None:
        """Persist memory to disk, creating the directory if needed."""
        self._dir.mkdir(parents=True, exist_ok=True)
        memory.last_updated = _today()
        with open(self._path, "w", encoding="utf-8") as f:
            json.dump(memory.to_dict(), f, indent=2, ensure_ascii=False)

    # ------------------------------------------------------------------
    # Incremental updates
    # ------------------------------------------------------------------

    def update_topic(self, memory: ChildMemory, keyword: str) -> None:
        """Add or increment a topic mention."""
        kw = keyword.strip().lower()
        if not kw:
            return
        for topic in memory.topics:
            if topic.keyword == kw:
                topic.mention_count += 1
                topic.last_mentioned = _today()
                return
        memory.topics.append(Topic(keyword=kw))

    def update_problem(
        self,
        memory: ChildMemory,
        type: str,
        example: str,
        correction: str,
    ) -> None:
        """Add or increment a language problem. Re-activates resolved problems."""
        for prob in memory.problems:
            if prob.type == type and prob.example.lower() == example.lower():
                prob.times_seen += 1
                prob.last_seen = _today()
                prob.resolved = False   # re-activate if seen again
                return
        memory.problems.append(Problem(
            type=type,
            example=example,
            correction=correction,
        ))

    def mark_resolved(self, memory: ChildMemory, type: str, example: str) -> None:
        """Mark a problem as resolved (will expire after _RESOLVED_TTL_DAYS)."""
        for prob in memory.problems:
            if prob.type == type and prob.example.lower() == example.lower():
                prob.resolved = True
                return

    # ------------------------------------------------------------------
    # Pruning
    # ------------------------------------------------------------------

    def prune(self, memory: ChildMemory) -> None:
        """Remove expired entries and enforce count caps.

        Keeps the most-recently-mentioned topics and most-recently-seen
        problems when capping by count.
        """
        today = date.today()

        # Topics: remove entries beyond their TTL
        memory.topics = [
            t for t in memory.topics
            if (today - date.fromisoformat(t.last_mentioned)).days <= self._topic_ttl
        ]

        # Problems: resolved expire after short TTL; unresolved after long TTL
        memory.problems = [
            p for p in memory.problems
            if (today - date.fromisoformat(p.last_seen)).days <= (
                self._RESOLVED_TTL_DAYS if p.resolved else self._problem_ttl
            )
        ]

        # Cap counts — keep the most recently active entries
        memory.topics.sort(key=lambda t: t.last_mentioned, reverse=True)
        memory.topics = memory.topics[:self._max_topics]

        memory.problems.sort(key=lambda p: p.last_seen, reverse=True)
        memory.problems = memory.problems[:self._max_problems]

    # ------------------------------------------------------------------
    # Profile listing
    # ------------------------------------------------------------------

    def list_profiles(self) -> list[str]:
        """Return slugs for all profiles in the profiles directory."""
        if not self._dir.exists():
            return []
        return sorted(p.stem for p in self._dir.glob("*.json"))

    def delete_profile(self, slug: str) -> bool:
        """Delete the profile JSON for ``slug``.

        The slug is re-sanitised through ``name_to_slug`` so a crafted value
        can never escape the profiles directory (path traversal). Returns True
        if a file was removed, False if there was nothing to delete.
        """
        safe = name_to_slug(slug)
        if not safe:
            return False
        try:
            (self._dir / f"{safe}.json").unlink()
            return True
        except FileNotFoundError:
            return False
