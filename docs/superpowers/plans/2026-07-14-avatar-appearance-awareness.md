# Avatar Self-Appearance Awareness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the avatar a per-avatar appearance description, injected into its system prompt, so it can answer "what colour is your hair?" / "are you a boy?" in character.

**Architecture:** A new `AppearanceStore` resolves a per-avatar description (curated bundled dict → cached auto-derived file → `None`). The server sets it on the shared `LLMPipeline` via a new `set_appearance` method — at connect (default avatar) and on a new `avatar_loaded` WebSocket message. The auto-derive path (`derive_from_regions` + `nearest_colour_name`) is built and unit-tested but not yet driven by the UI.

**Tech Stack:** Python 3.11+ (dataclasses, pathlib, json), pytest (offline, mock-based), vanilla JS WebSocket client.

## Global Constraints

- No new runtime dependencies; no new model downloads. (README: "no telemetry leaves the device"; local-first.)
- Tests run offline with no hardware and no Ollama server (mock-based), consistent with the existing 271-test suite.
- The `LANGUAGE_LOCK` string must remain the final block of the system prompt — appearance goes **before** it.
- Any avatar key used in a filesystem path must be sanitised via `app.memory.name_to_slug` (path-traversal guard), matching `MemoryManager.delete_profile`.
- Avatar **key** = VRM file basename without extension. Default avatar key = `VIPEHero_2707` (matches `ui/src/main.js` `MODEL_PATH = '/avatar/VIPEHero_2707.vrm'`).

---

## File Structure

- **Create** `app/appearance.py` — `AvatarAppearance` dataclass, `_CURATED` dict, `nearest_colour_name`, `AppearanceStore` (get / derive_from_regions), `DEFAULT_AVATAR_KEY`.
- **Create** `tests/test_appearance.py` — unit tests for the store, colour mapping, caching, traversal guard.
- **Modify** `app/pipeline/llm.py` — `self._appearance`, `set_appearance`, appearance block in `_build_prompt`.
- **Modify** `tests/test_pipeline_llm.py` — appearance-injection tests.
- **Modify** `app/server.py` — construct store, set default appearance at connect, handle `avatar_loaded`, document the message.
- **Modify** `tests/test_server_features.py` — test `avatar_loaded` → `set_appearance`.
- **Modify** `ui/src/main.js` — send `avatar_loaded` after VRM load.
- **Modify** `README.md` — one-line note about appearance awareness.

---

## Task 1: Appearance store, curated descriptions, colour mapping

**Files:**
- Create: `app/appearance.py`
- Test: `tests/test_appearance.py`

**Interfaces:**
- Consumes: `app.memory.name_to_slug` (existing).
- Produces:
  - `DEFAULT_AVATAR_KEY: str` (`"VIPEHero_2707"`).
  - `@dataclass AvatarAppearance(key: str, description: str, source: str, derived_at: str)`.
  - `nearest_colour_name(hex_colour: str) -> str`.
  - `AppearanceStore(cache_dir: str | Path = "~/.ai-avatar/avatars/")` with:
    - `get(key: str) -> Optional[AvatarAppearance]`
    - `derive_from_regions(key: str, regions: dict[str, str]) -> AvatarAppearance`

- [ ] **Step 1: Write the failing tests**

Create `tests/test_appearance.py`:

```python
"""Tests for per-avatar appearance descriptions.

Pure Python — no Ollama, no hardware. Curated lookups never touch disk;
derive/cache round-trips use a tmp_path cache dir.
"""
import json
from pathlib import Path

import pytest

from app.appearance import (
    AppearanceStore,
    AvatarAppearance,
    DEFAULT_AVATAR_KEY,
    nearest_colour_name,
)


# ── Curated lookups ─────────────────────────────────────────────────────────

def test_default_avatar_key_matches_bundled_vrm():
    assert DEFAULT_AVATAR_KEY == "VIPEHero_2707"


def test_curated_lookup_returns_bundled_description(tmp_path):
    store = AppearanceStore(tmp_path)
    got = store.get(DEFAULT_AVATAR_KEY)
    assert got is not None
    assert got.source == "curated"
    assert got.description.strip()          # non-empty
    assert got.key == DEFAULT_AVATAR_KEY


def test_curated_lookup_for_sample_avatar(tmp_path):
    store = AppearanceStore(tmp_path)
    got = store.get("AvatarSample_A")
    assert got is not None
    assert got.source == "curated"
    assert got.description.strip()


def test_unknown_key_returns_none(tmp_path):
    store = AppearanceStore(tmp_path)
    assert store.get("no_such_avatar") is None


# ── Colour mapping ──────────────────────────────────────────────────────────

@pytest.mark.parametrize("hex_colour,expected", [
    ("#000000", "black"),
    ("#ffffff", "white"),
    ("#c0392b", "red"),
    ("#2e86de", "blue"),
    ("#6b4423", "brown"),
])
def test_nearest_colour_name(hex_colour, expected):
    assert nearest_colour_name(hex_colour) == expected


# ── Auto-derive + cache round-trip ──────────────────────────────────────────

def test_derive_from_regions_builds_and_caches(tmp_path):
    store = AppearanceStore(tmp_path)
    regions = {"hair": "#6b4423", "clothing": "#c0392b"}
    got = store.derive_from_regions("custom_bot", regions)

    assert got.source == "auto"
    assert "brown" in got.description.lower()
    assert "red" in got.description.lower()

    # Cached to disk and re-read as source="auto"
    cache_file = tmp_path / "custom_bot.json"
    assert cache_file.exists()
    again = store.get("custom_bot")
    assert again is not None
    assert again.source == "auto"
    assert again.description == got.description


def test_derive_key_sanitised_against_traversal(tmp_path):
    store = AppearanceStore(tmp_path)
    store.derive_from_regions("../../evil", {"hair": "#000000"})
    # Nothing written outside the cache dir
    assert not (tmp_path.parent / "evil.json").exists()
    # A sanitised file lives inside the cache dir
    assert list(tmp_path.glob("*.json"))


def test_corrupt_cache_file_treated_as_missing(tmp_path):
    store = AppearanceStore(tmp_path)
    (tmp_path / "broken.json").write_text("{ not json")
    assert store.get("broken") is None
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `.venv/bin/python -m pytest tests/test_appearance.py -q`
Expected: FAIL — `ModuleNotFoundError: No module named 'app.appearance'`.

- [ ] **Step 3: Implement `app/appearance.py`**

```python
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
        "PLACEHOLDER — replace with a description written by rendering "
        "VIPEHero_2707.vrm."
    ),
    "AvatarSample_A": (
        "PLACEHOLDER — replace with a description written by rendering "
        "AvatarSample_A.vrm."
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `.venv/bin/python -m pytest tests/test_appearance.py -q`
Expected: PASS (all). Note: the two curated tests only assert non-empty content, so they pass with the PLACEHOLDER strings — the real descriptions are authored in Step 5.

- [ ] **Step 5: Author the real curated descriptions**

Render each avatar and describe what is actually on screen (do not guess):

Run: `.venv/bin/python run.py` (opens `http://localhost:5173`). Observe the default avatar. To view the sample, temporarily point `ui/src/main.js` `MODEL_PATH` at `/avatar/AvatarSample_A.vrm`, reload, observe, then revert `MODEL_PATH`.

Then replace both `_CURATED` PLACEHOLDER strings in `app/appearance.py` with ~1–2 sentence second-person descriptions covering hair colour & length, eye colour, clothing colours, and overall vibe (apparent age / presented gender stated softly, e.g. "You look like a cheerful girl…"). Example shape (content must match the real render):

```python
    "VIPEHero_2707": (
        "You look like a brave young hero. You have <hair>, <eyes>, and wear "
        "<clothing>. You come across as <vibe>."
    ),
```

Re-run: `.venv/bin/python -m pytest tests/test_appearance.py -q` → still PASS.

- [ ] **Step 6: Commit**

```bash
git add app/appearance.py tests/test_appearance.py
git commit -m "feat: per-avatar appearance store with curated descriptions

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 2: Inject appearance into the system prompt

**Files:**
- Modify: `app/pipeline/llm.py` (`__init__`, `_build_prompt`, new `set_appearance`)
- Test: `tests/test_pipeline_llm.py`

**Interfaces:**
- Consumes: nothing from Task 1 directly (server passes the string).
- Produces: `LLMPipeline.set_appearance(self, text: str | None) -> None`; appearance text rendered in `self._system_prompt` before `LANGUAGE_LOCK`.

- [ ] **Step 1: Write the failing tests**

Append to `tests/test_pipeline_llm.py` (uses existing `make_pipeline` / imports `LANGUAGE_LOCK`):

```python
from app.levels import LANGUAGE_LOCK


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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `.venv/bin/python -m pytest tests/test_pipeline_llm.py -k Appearance -q`
Expected: FAIL — `AttributeError: 'LLMPipeline' object has no attribute 'set_appearance'`.

- [ ] **Step 3: Implement the changes in `app/pipeline/llm.py`**

Add a module-level constant near `_PATTERN_REVIEW_HINT`:

```python
_APPEARANCE_TEMPLATE = (
    "About how you look — if asked about your appearance, answer in first "
    "person and stay in character: {description}"
)
```

In `__init__`, set `self._appearance` **before** the first `_build_prompt` call:

```python
    def __init__(self, config: Config) -> None:
        self._config = config
        self._base_prompt = config.format_system_prompt()
        self._memory = None
        self._appearance: str | None = None
        self._system_prompt = self._build_prompt(config.child.level)
        self._history: list[dict[str, str]] = []
        self._pending_hint: str | None = None   # one-shot extra system message
```

In `_build_prompt`, insert the appearance block after the memory block and before `LANGUAGE_LOCK` (reads `self._appearance`, so `set_level`/`set_memory` preserve it automatically):

```python
    def _build_prompt(self, level: str, memory=None) -> str:
        parts = [self._base_prompt]
        instruction = instructions_for(level)
        if instruction:
            parts.append(instruction)
        if memory is not None:
            parts.append(self._format_memory_block(memory))
        if self._appearance:
            parts.append(_APPEARANCE_TEMPLATE.format(description=self._appearance))
        # Always last: the non-negotiable "reply only in English" rule.
        parts.append(LANGUAGE_LOCK)
        return "\n\n".join(parts)
```

Add the setter (near `set_memory`):

```python
    def set_appearance(self, text: str | None) -> None:
        """Set (or clear) the avatar's appearance description in the system prompt.

        Pass a description string so the avatar can answer "what do you look
        like?" in character. Pass None to remove it. Takes effect next turn.
        """
        self._appearance = text
        self._system_prompt = self._build_prompt(self._config.child.level, self._memory)
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `.venv/bin/python -m pytest tests/test_pipeline_llm.py -q`
Expected: PASS (new appearance tests + all existing pipeline tests).

- [ ] **Step 5: Commit**

```bash
git add app/pipeline/llm.py tests/test_pipeline_llm.py
git commit -m "feat: inject avatar appearance into the system prompt

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 3: Wire appearance into the server

**Files:**
- Modify: `app/server.py` (header docstring, `_session`: construct store, set default appearance at connect, handle `avatar_loaded`)
- Test: `tests/test_server_features.py`

**Interfaces:**
- Consumes: `AppearanceStore`, `DEFAULT_AVATAR_KEY` from Task 1; `LLMPipeline.set_appearance` from Task 2.
- Produces: inbound message `{"type": "avatar_loaded", "key": "<avatar-key>"}` handled in `_session`.

- [ ] **Step 1: Write the failing test**

Append to `tests/test_server_features.py` (reuses `_mock_stt`, `_mock_llm`, `_mock_tts_with_amplitude`, `MockWebSocket`, `base_config`):

```python
class TestAvatarAppearance:
    async def test_default_appearance_set_at_connect(self, base_config):
        llm = _mock_llm()
        ws = MockWebSocket([])   # no messages; just connect + disconnect
        await _session(
            ws, base_config, _mock_stt(), llm, _mock_tts_with_amplitude(),
            None, None,
        )
        # Default avatar's curated description pushed to the pipeline at connect.
        assert llm.set_appearance.called
        first_arg = llm.set_appearance.call_args_list[0].args[0]
        assert isinstance(first_arg, str) and first_arg.strip()

    async def test_avatar_loaded_sets_matching_appearance(self, base_config):
        llm = _mock_llm()
        ws = MockWebSocket([
            json.dumps({"type": "avatar_loaded", "key": "AvatarSample_A"}),
        ])
        await _session(
            ws, base_config, _mock_stt(), llm, _mock_tts_with_amplitude(),
            None, None,
        )
        # The most recent set_appearance reflects the loaded avatar (non-empty curated string).
        last_arg = llm.set_appearance.call_args_list[-1].args[0]
        assert isinstance(last_arg, str) and last_arg.strip()

    async def test_unknown_avatar_clears_appearance(self, base_config):
        llm = _mock_llm()
        ws = MockWebSocket([
            json.dumps({"type": "avatar_loaded", "key": "does_not_exist"}),
        ])
        await _session(
            ws, base_config, _mock_stt(), llm, _mock_tts_with_amplitude(),
            None, None,
        )
        assert llm.set_appearance.call_args_list[-1].args[0] is None
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `.venv/bin/python -m pytest tests/test_server_features.py -k Appearance -q`
Expected: FAIL — `set_appearance` never called (or the handler doesn't exist yet).

- [ ] **Step 3: Implement the wiring in `app/server.py`**

Add the import near the other `app.*` imports (top of file, by `from app.pipeline.llm import LLMPipeline`):

```python
from app.appearance import AppearanceStore, DEFAULT_AVATAR_KEY
```

In the header docstring's inbound-message list (near `{"type": "set_level", ...}`), add:

```
  {"type": "avatar_loaded", "key": "VIPEHero_2707"}   # avatar changed → refresh appearance
```

In `_session`, after `llm.clear_history()` (around line 361), construct the store and set the default avatar's appearance at connect:

```python
    # Appearance: the avatar can answer "what do you look like?" from a curated
    # (or cached auto-derived) description. Set the default avatar now; the UI's
    # 'avatar_loaded' message refreshes it if a different avatar is shown.
    appearance_store = AppearanceStore(
        Path(config.memory.profiles_dir).expanduser().parent / "avatars"
    )

    def _apply_appearance(key: str) -> None:
        found = appearance_store.get(key)
        llm.set_appearance(found.description if found else None)

    _apply_appearance(DEFAULT_AVATAR_KEY)
```

In the main dispatch loop, alongside the other `if mtype == ...` handlers (after the `set_level` block, ~line 486), add:

```python
            # ── Avatar changed: refresh appearance description ───────────
            if mtype == "avatar_loaded":
                _apply_appearance(msg.get("key", ""))
                continue
```

Note: `Path` is **not** currently imported in `server.py` — add `from pathlib import Path` to the imports. `config.memory.profiles_dir` defaults to `~/.ai-avatar/profiles/`, so the cache dir resolves to `~/.ai-avatar/avatars/`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `.venv/bin/python -m pytest tests/test_server_features.py -q`
Expected: PASS (new appearance tests + all existing feature tests).

- [ ] **Step 5: Run the full server test suite (no regressions)**

Run: `.venv/bin/python -m pytest tests/test_server_features.py tests/test_server_security.py tests/test_server_settings.py tests/test_server_transcript.py tests/test_server_integration.py -q`
Expected: PASS. (The mock LLM has `spec=LLMPipeline`, so `set_appearance` now exists on the spec and the connect-time call is harmless.)

- [ ] **Step 6: Commit**

```bash
git add app/server.py tests/test_server_features.py
git commit -m "feat: set avatar appearance at connect and on avatar_loaded

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 4: UI sends `avatar_loaded`; README note

**Files:**
- Modify: `ui/src/main.js` (connection-established handler)
- Modify: `README.md`

**Interfaces:**
- Consumes: the server `avatar_loaded` handler from Task 3.
- Produces: nothing consumed by later tasks.

The UI layer is intentionally not unit-tested (browser WebGL) — verify manually.

Timing note: the outbound helper is `wsSend(data)` (`ui/src/main.js:395`), which **silently drops** the message unless `ws.readyState === OPEN`. The VRM can finish loading before the socket opens, so do **not** send from the VRM load callback. The avatar key is derived from the static `MODEL_PATH` constant and does not need the model to finish loading — so send it once the connection is established.

- [ ] **Step 1: Send `avatar_loaded` when the connection is established**

In `ui/src/main.js`, find where the client handles the server `init` message (or the `ws.onopen` handler) — the same place other startup sends happen. Send the avatar key there:

```javascript
  // Tell the server which avatar is on screen so it can load the matching
  // appearance description ("what colour is your hair?"). Key is the VRM
  // basename; derived from the static MODEL_PATH, so it needs no model load.
  const avatarKey = MODEL_PATH.split('/').pop().replace(/\.vrm$/i, '')
  wsSend({ type: 'avatar_loaded', key: avatarKey })
```

Place this call where the socket is guaranteed `OPEN` (init handler / onopen), matching how `set_level` is sent via `wsSend` (`ui/src/main.js:527`).

- [ ] **Step 2: Manual verification**

Run: `.venv/bin/python run.py`
- Confirm no console/network errors and the `avatar_loaded` frame is sent (browser devtools → WS).
- Ask the avatar (type or speak): "what colour is your hair?" and "are you a boy or a girl?" — replies should match the curated description and stay in character.

- [ ] **Step 3: README note**

In `README.md`, add a short line in the Settings/behaviour area, e.g. under the transcript paragraph (~line 164):

```markdown
Nova also knows what she looks like — ask "what colour is your hair?" or
"are you a boy?" and she answers in character, grounded in the avatar on screen.
```

- [ ] **Step 4: Commit**

```bash
git add ui/src/main.js README.md
git commit -m "feat: UI announces loaded avatar; document appearance awareness

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 5: Full suite + final verification

**Files:** none (verification only).

- [ ] **Step 1: Run the whole test suite**

Run: `.venv/bin/python -m pytest -q`
Expected: PASS (existing 271 + the new appearance/prompt/server tests).

- [ ] **Step 2: End-to-end sanity**

Run: `.venv/bin/python run.py`, hold Space, ask "what do you look like?" — confirm a grounded, in-character answer. Switch child profile (Settings → Kid) and re-ask — the same appearance answer should hold (appearance is per-avatar, not per-child).

---

## Self-Review

**Spec coverage:**
- Resolution order (curated → cached → derive → None) → Task 1 (`AppearanceStore.get` + `derive_from_regions`). ✓
- Per-avatar storage + system-prompt injection → Task 2. ✓
- Server wiring + `avatar_loaded` + connect-time default → Task 3. ✓
- UI announces avatar → Task 4. ✓
- Auto-derive seam built + tested, UI sampling deferred → Task 1 (`derive_from_regions`, `nearest_colour_name` tested); UI sends key-only in Task 4. ✓
- Path-traversal guard, corrupt-cache tolerance → Task 1 tests. ✓
- Graceful "no appearance line" for unknown key → Task 3 `test_unknown_avatar_clears_appearance`. ✓
- README note → Task 4. ✓
- No new deps / downloads → nothing added to `requirements.txt`. ✓

**Placeholder scan:** The only `PLACEHOLDER` strings are the two `_CURATED` values, authored in Task 1 Step 5 by rendering the avatars (deliberate, with an explicit authoring step). No other TODO/TBD.

**Type consistency:** `AppearanceStore.get` → `Optional[AvatarAppearance]`; `.description` (str) used everywhere; `set_appearance(str | None)`; `_apply_appearance(key)` passes `found.description if found else None`. Consistent across Tasks 1–3.
