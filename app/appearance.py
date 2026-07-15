"""Per-avatar appearance descriptions for self-referential Q&A.

The avatar can answer "what colour is your hair?" because a short description
is injected into its system prompt. Appearance is a property of the *avatar*
(shared across all child profiles), not of a child, so it lives here and not
in app.memory.

Resolution order (AppearanceStore.get):
    1. curated bundled description (_CURATED)
    2. cached auto-derived description (~/.ai-avatar/avatars/<key>.json)
    3. None  → the caller injects no appearance line (graceful)

derive_from_regions + nearest_colour_name implement the auto path from sampled
portrait colours. They are complete and tested, but the UI does not yet sample
or send region colours — that arrives with a future avatar-upload feature.
"""
from __future__ import annotations

import json
from dataclasses import dataclass, asdict
from datetime import date
from pathlib import Path
from typing import Optional

from app.memory import name_to_slug

# Matches ui/src/main.js MODEL_PATH basename.
DEFAULT_AVATAR_KEY = "VIPEHero_2707"


# ---------------------------------------------------------------------------
# Curated descriptions (bundled). Keyed by avatar key = VRM basename.
# Authored by rendering each avatar and describing what is on screen — see the
# implementation note in the plan. Second person, ~1-2 sentences, concrete
# visual facts a child asks about (hair, eyes, clothing, overall vibe).
# ---------------------------------------------------------------------------
_CURATED: dict[str, str] = {
    "VIPEHero_2707": (
        "You look like a playful, cool hero with a cheerful, spunky vibe. You have "
        "long pink hair with orange streaks, and you wear a blue-and-pink cat-ear "
        "headband and big purple sunglasses. You've got a white hoodie with mint-green "
        "sleeves and a little purple skull badge, plus a tiny fang and a small black "
        "'x' mark on your cheek. You come across as a friendly, energetic girl."
    ),
    "AvatarSample_A": (
        "You look like a sweet, gentle girl with a calm, kind vibe. You have short "
        "dark-brown hair in a soft bob and warm brown eyes, with a shy little smile. "
        "You wear a cream cardigan laced with blue ribbons over a black lace-trimmed "
        "top. You come across as quiet and friendly."
    ),
}


@dataclass
class AvatarAppearance:
    key: str
    description: str
    source: str          # "curated" | "auto"
    derived_at: str      # ISO date


# ---------------------------------------------------------------------------
# Colour naming
# ---------------------------------------------------------------------------
# Small named palette. hex → nearest by squared RGB distance.
_PALETTE: dict[str, tuple[int, int, int]] = {
    "black": (0, 0, 0),
    "white": (255, 255, 255),
    "grey": (128, 128, 128),
    "red": (200, 40, 40),
    "orange": (230, 140, 40),
    "yellow": (240, 220, 60),
    "blonde": (220, 200, 130),
    "green": (60, 170, 90),
    "blue": (50, 130, 220),
    "purple": (150, 70, 190),
    "pink": (235, 130, 180),
    "brown": (110, 70, 40),
}


def _hex_to_rgb(hex_colour: str) -> tuple[int, int, int]:
    h = hex_colour.lstrip("#")
    return int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16)


def nearest_colour_name(hex_colour: str) -> str:
    """Return the palette colour name nearest to *hex_colour* (e.g. '#6b4423' → 'brown')."""
    r, g, b = _hex_to_rgb(hex_colour)
    return min(
        _PALETTE.items(),
        key=lambda kv: (kv[1][0] - r) ** 2 + (kv[1][1] - g) ** 2 + (kv[1][2] - b) ** 2,
    )[0]


# ---------------------------------------------------------------------------
# Store
# ---------------------------------------------------------------------------

class AppearanceStore:
    """Resolves and caches per-avatar appearance descriptions."""

    def __init__(self, cache_dir: str | Path = "~/.ai-avatar/avatars/") -> None:
        self._dir = Path(cache_dir).expanduser()

    def get(self, key: str) -> Optional[AvatarAppearance]:
        if not key or not key.strip():
            return None
        if key in _CURATED:
            return AvatarAppearance(
                key=key,
                description=_CURATED[key],
                source="curated",
                derived_at=date.today().isoformat(),
            )
        path = self._dir / f"{name_to_slug(key)}.json"
        if not path.exists():
            return None
        try:
            with open(path, encoding="utf-8") as f:
                return AvatarAppearance(**json.load(f))
        except Exception:
            return None   # corrupt cache treated as missing

    def derive_from_regions(
        self, key: str, regions: dict[str, str]
    ) -> AvatarAppearance:
        """Build + cache a description from sampled portrait region colours.

        regions maps a body area to a hex colour, e.g.
        {"hair": "#6b4423", "clothing": "#c0392b"}.
        """
        parts = []
        if regions.get("hair"):
            parts.append(f"{nearest_colour_name(regions['hair'])} hair")
        if regions.get("clothing"):
            parts.append(f"{nearest_colour_name(regions['clothing'])} clothes")
        summary = " and ".join(parts) if parts else "a friendly look"
        description = f"You have {summary}."

        appearance = AvatarAppearance(
            key=key,
            description=description,
            source="auto",
            derived_at=date.today().isoformat(),
        )
        self._dir.mkdir(parents=True, exist_ok=True)
        with open(self._dir / f"{name_to_slug(key)}.json", "w", encoding="utf-8") as f:
            json.dump(asdict(appearance), f, indent=2, ensure_ascii=False)
        return appearance
