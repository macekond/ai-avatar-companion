# Avatar self-appearance awareness — design

**Date:** 2026-07-14
**Status:** Approved (pending spec review)
**Branch:** feat/tune-level-language (feature work will branch from here / main)

## Problem

The avatar (Nova) has no notion of what it looks like. A child naturally asks
things like *"what colour is your hair?"*, *"are you a boy?"*, *"what are you
wearing?"* — and today the model either refuses, hallucinates, or breaks
character. We want the avatar to answer appearance questions consistently and
in-character, grounded in what the rendered avatar actually looks like.

## Goals

- The avatar can answer appearance questions ("hair colour", "boy/girl",
  "clothing") consistently, in first person, staying in character.
- Works for the **default avatar** and the bundled sample out of the box, with
  zero manual setup by the user and **no new model download**.
- The appearance is a property of the *avatar* (shared across all child
  profiles), cached to disk, and cheap to inject.
- Degrades gracefully: if no description is available, the avatar simply
  doesn't volunteer its looks — nothing breaks.

## Non-goals (YAGNI)

- **No avatar-switching / upload UI.** The avatar is still the hardcoded VRM
  (`ui/src/main.js` `MODEL_PATH`). This feature only adds *appearance
  awareness*, not avatar management.
- **No dedicated vision model.** A local Ollama vision model (moondream ≈1.7 GB
  is the smallest mainstream option) is too heavy for a once-per-avatar task.
  Rejected in brainstorming.
- **No per-child appearance storage.** Appearance is per-avatar, not per-child;
  it lives in the system prompt, not in `ChildMemory`.
- **No full auto-derive pipeline this iteration.** The UI canvas colour-sampling
  is deferred (see "Auto-derive seam"), because there is no avatar-upload flow
  that could produce an un-curated avatar to trigger it.

## Decisions (from brainstorming)

| Decision | Choice |
|---|---|
| Scope | Appearance awareness only — no switcher UI |
| Derivation | Automatic, but **no dedicated vision model** |
| Storage / injection | Per-avatar metadata cached to disk → **system prompt** |
| Approach | **Curated descriptions** for bundled avatars + a **deferred auto-derive seam** (colour-sampling + deterministic template) for future avatars |
| Auto path this iteration | Build the store method + colour mapping (unit-tested); **do not** build UI colour-sampling yet |

## Resolution order

When the server needs an avatar's appearance for a given `key`:

```
1. curated description  (bundled dict, for known avatars)
2. cached auto-derived description  (~/.ai-avatar/avatars/<key>.json)
3. auto-derive from sampled portrait colours → cache   [seam only this iteration]
4. None  →  no appearance line in the prompt (graceful)
```

The **avatar key** is the VRM file basename without extension, e.g.
`VIPEHero_2707`, `AvatarSample_A`. It is re-sanitised through the existing
`name_to_slug()` guard before being used in a cache filename, so a crafted key
can never escape the cache directory (same path-traversal defence as
`MemoryManager.delete_profile`).

## Data flow

```
UI (VRM finished loading)
  └─ ws → { "type": "avatar_loaded", "key": "VIPEHero_2707" }
        (regions colours added later, only for the auto path)
Server dispatch loop
  └─ AppearanceStore.get(key)  →  AvatarAppearance | None
       └─ llm.set_appearance(description | None)   # mirrors set_memory / set_level
LLMPipeline._build_prompt
  └─ appearance block injected into the system prompt, before LANGUAGE_LOCK
```

The default avatar's curated appearance is also set **at connect time** (from
the known default key) so the avatar is appearance-aware from the first turn,
before the `avatar_loaded` message arrives. `avatar_loaded` then keeps it in
sync for any future avatar change.

## Components

### 1. `app/appearance.py` (new)

```python
@dataclass
class AvatarAppearance:
    key: str
    description: str
    source: str          # "curated" | "auto"
    derived_at: str      # ISO date

# Hand-authored, bundled. Keyed by avatar key (VRM basename).
_CURATED: dict[str, str] = {
    "VIPEHero_2707": "...",     # written by rendering the avatar
    "AvatarSample_A": "...",    # written by rendering the avatar
}

class AppearanceStore:
    def __init__(self, cache_dir: str | Path = "~/.ai-avatar/avatars/") -> None: ...

    def get(self, key: str) -> Optional[AvatarAppearance]:
        # curated  →  cached file  →  None
        ...

    def derive_from_regions(
        self, key: str, regions: dict[str, str]
    ) -> AvatarAppearance:
        # regions: {"hair": "#6b4423", "skin": "...", "clothing": "#c0392b"}
        # map each hex → nearest_colour_name → deterministic first-person
        # template, cache to <safe-key>.json, return AvatarAppearance(source="auto")
        # [seam this iteration: implemented + unit-tested, not yet called by the UI]
        ...
```

Plus a module-level helper:

```python
def nearest_colour_name(hex_colour: str) -> str:
    # small built-in palette table (black/white/grey/red/orange/yellow/green/
    # blue/purple/pink/brown/blonde...), nearest by RGB distance.
```

**Curated description content.** Written in the second person as the avatar's
self-knowledge — concrete visual facts a child would ask about (hair colour &
length, eye colour, clothing colours, overall vibe / apparent age & presented
gender stated softly). Kept to ~1–2 sentences. The two bundled descriptions
will be authored by rendering each avatar (`python run.py`) and describing what
is actually on screen — not guessed.

### 2. `app/pipeline/llm.py`

- New instance field `self._appearance: str | None = None`.
- `set_appearance(self, text: str | None) -> None` — stores the text and
  rebuilds the system prompt (same pattern as `set_memory`). Takes effect from
  the next turn.
- `_build_prompt(...)` gains an appearance section, inserted into the
  personality part of the prompt **before** `LANGUAGE_LOCK` (which must remain
  the final word). Wording:

  > About how you look — answer any questions about your appearance in first
  > person and stay in character: {description}

- Absent when `self._appearance` is `None` (no empty block).

### 3. `app/server.py`

- Header docstring: document the new inbound message
  `{"type": "avatar_loaded", "key": "..."}`.
- Construct one `AppearanceStore` at server startup (near config/mem_mgr).
- Define the **default avatar key** as a constant (`DEFAULT_AVATAR_KEY =
  "VIPEHero_2707"`, matching the UI's `MODEL_PATH`). At connect, resolve and
  `llm.set_appearance(...)` for the default so the avatar is immediately aware.
- In the main dispatch loop, handle `mtype == "avatar_loaded"`: look up
  `store.get(msg["key"])` and `llm.set_appearance(app.description if app else
  None)`. Unknown/blank key → `set_appearance(None)` (graceful).

### 4. `ui/src/main.js`

- After the VRM loads successfully (in the existing load callback), derive the
  key from `MODEL_PATH` basename and send
  `{ type: "avatar_loaded", key }` over the existing WebSocket.
- **No colour sampling this iteration** (deferred with the auto path).

## Auto-derive seam (deferred, but scaffolded)

To keep the door open without speculative UI code:

- `AppearanceStore.derive_from_regions` and `nearest_colour_name` **are** built
  and unit-tested this iteration — they are pure, testable functions.
- The UI does **not** yet sample or send `regions`. When an avatar-upload
  feature later exists, the UI adds canvas region-colour sampling and includes
  `regions` in `avatar_loaded`; the server calls `derive_from_regions` in
  resolution step 3. No server/UI protocol change needed beyond adding the
  optional `regions` field.
- Deterministic template (not an LLM call) keeps the auto path testable and
  free of nondeterminism / extra latency.

## Error handling & edge cases

- **Unknown avatar key** → `get` returns `None` → no appearance line. Avatar
  answers appearance questions gently without grounded facts (existing
  behaviour), nothing crashes.
- **Corrupt cache file** → treated as missing (same tolerance as
  `MemoryManager.load`).
- **Path traversal via key** → `name_to_slug` sanitisation before any filesystem
  use.
- **`set_appearance` mid-conversation** → safe; only affects the next turn's
  system prompt, exactly like `set_level` / `set_memory`.
- **Malformed `avatar_loaded` (missing key)** → treated as blank key →
  `set_appearance(None)`.

## Testing

New/updated tests (offline, no hardware — consistent with the existing suite):

- `tests/test_appearance.py` (new):
  - curated lookup returns the bundled description with `source="curated"`.
  - unknown key returns `None`.
  - `derive_from_regions` maps colours to a sensible first-person template and
    caches a JSON file; a second `get` reads it back with `source="auto"`.
  - cache key sanitisation blocks path traversal (`../../evil`).
  - corrupt cache file is tolerated (returns `None`, no raise).
  - `nearest_colour_name` maps representative hexes to expected names.
- `tests/test_pipeline_llm.py` (extend):
  - appearance block present after `set_appearance`, absent when `None`.
  - appearance appears **before** `LANGUAGE_LOCK` in the built prompt.
  - `set_appearance(None)` removes the block.
- Server: a focused test that an `avatar_loaded` message results in
  `llm.set_appearance` being called with the resolved description (using the
  existing server test harness / mocks).

## Rollout / docs

- Update `README.md` (Settings / How-it-works area) with a short note that the
  avatar knows what it looks like and can answer appearance questions.
- No new config keys, no new dependencies, no new model downloads.
