"""User-adjustable settings persisted across sessions.

Kept separate from config.yaml (which is authored, commented, and seeded
once) so runtime changes from the settings panel — voice, level — don't
clobber the user's hand-edited YAML. Stored as a small JSON file in the
same ~/.ai-avatar directory as profiles and logs.
"""
from __future__ import annotations

import json
from pathlib import Path
from typing import Any

_SETTINGS_PATH = Path.home() / ".ai-avatar" / "settings.json"


def load_settings() -> dict[str, Any]:
    """Return the saved settings, or an empty dict if none/corrupt."""
    try:
        with open(_SETTINGS_PATH, encoding="utf-8") as f:
            data = json.load(f)
            return data if isinstance(data, dict) else {}
    except (FileNotFoundError, ValueError, OSError):
        return {}


def save_setting(key: str, value: Any) -> None:
    """Merge a single key into the settings file (create dir if needed)."""
    data = load_settings()
    data[key] = value
    _SETTINGS_PATH.parent.mkdir(parents=True, exist_ok=True)
    with open(_SETTINGS_PATH, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2)
