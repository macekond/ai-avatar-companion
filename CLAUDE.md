# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```bash
make test                 # .venv/bin/python -m pytest -q — the whole suite, offline
make dev                  # .venv/bin/python run.py — server + Vite + browser
make bundle               # packaging/build.sh → Nova.app + DMG (macOS, Apple Silicon)

.venv/bin/python -m pytest tests/test_memory.py::TestDeleteProfile -q          # one class
.venv/bin/python -m pytest tests/test_memory.py::TestDeleteProfile::test_x -q  # one test
.venv/bin/python -m pytest -q --tb=short                                       # short tracebacks

python main.py            # CLI text mode — fastest loop for prompt tuning (no mic/TTS)
python main.py --voice    # CLI voice mode — full pipeline, no browser
npm --prefix ui run dev   # frontend alone (expects the Python server on :8765)

gh workflow run tests.yml --ref <branch>   # CI on demand (also runs on every PR to main)
```

Use `.venv/bin/python`, not the system `python3` — pytest is only installed in the venv.

The suite is fully offline: no Ollama, mic, speakers, or network. Anything requiring hardware is
deliberately untested (see TESTING.md) and validated by hand via `make dev` / `python main.py --voice`.

## Testing

TDD is encouraged, and the payoff here is concrete: this codebase's real bugs are ordering and
lifetime bugs that look fine when read. Write the failing test first, watch it fail for the reason
you expect, then fix.

**Verify a test discriminates.** Mocks in this suite can mask the bug you're targeting — mocked STT
returns a transcript regardless of the audio handed to it, and a fast fake extractor finishes inside
the drain timeout that the real one would blow through. A test that passes before the fix is applied
proves nothing. Temporarily defeat the fix and confirm the test goes red.

Key harness pieces in `tests/conftest.py`: `base_config` (in-memory `Config`, skips `config.yaml`)
and `MockWebSocket` (queues client→server messages upfront; `recv()` raises `asyncio.TimeoutError`
when exhausted, which is how a session ends in tests). `pytest.ini` sets `asyncio_mode = auto`, so
`async def` tests just run. Server tests call `await _session(...)` directly.

Passing `mem_mgr=None` to `_session` skips onboarding entirely — convenient, but it means such a test
does not cover the first-run path.

## Architecture

Voice loop: `Space held → mic → faster-whisper (STT) → Ollama (LLM) → Piper (TTS) → avatar`. The LLM
streams *sentences* to TTS as they generate, which is what keeps time-to-first-word ~1–1.5s; preserve
that streaming boundary when touching `app/pipeline/llm.py` or `tts.py`.

`app/server.py` is the spine — an asyncio WebSocket server on :8765 bridging the Python pipeline to
the browser. Its module docstring is the authoritative message protocol in both directions; keep it
and `ui/src/main.js` in sync when adding a message type. `run.py` orchestrates server + Vite + browser
for dev; `main.py` is the CLI.

### Invariants that span files

**One reader on the socket.** Everything reads through `_next_raw()`, which drains `buffered_msgs`
before touching `ws.recv()`. Phases that need a specific message (onboarding, the listening phase,
the barge-in watcher) must use `_await_ptt(...)` and stash anything unrelated back for the main loop.
Calling `ws.recv()` directly reintroduces a nasty class of bug: a swallowed message shifts every later
read by one, so a `ptt_start` gets consumed as the `ptt_stop` ending a recording that captured
nothing. Onboarding's stash must be a local list, never `buffered_msgs` itself — stashing into the
list the reader pops from re-serves the same message forever.

**Prompt assembly order is load-bearing** (`LLMPipeline._build_prompt`): base personality → level
instructions → memory block → appearance → `LANGUAGE_LOCK` **last**, because the small local model
treats the final block as the last word. Tests pin this ordering; if you append to the prompt, append
before the lock, not after.

**No unsanitized slug reaches `MemoryManager`** — from config, CLI, or a WebSocket message. Everything
goes through `name_to_slug()`. It strips non-ASCII, so `Björn`→`bjrn`; a name with *no* ASCII
letters/digits (`李明`) sanitises to empty. Callers that must not conflate junk with a real profile
pass `fallback=""` and reject the empty result — the default `fallback="child"` would silently collapse
distinct children onto one shared profile and leak memory between them.

**Deletion must stick.** Background extraction tasks are fire-and-forget and hold their own
`MemoryManager` reference. Abandoning a task at `DRAIN_TIMEOUT_S` does not stop its thread, so
`delete_profile` tombstones the slug and `save()` no-ops for it. Drain-before-unlink is the first line
of defence, not the only one — a cold Ollama model routinely outlives the drain.

**Profile hot-swap** (`_swap_profile`) rebuilds the `MemoryManager`, reloads memory, and clears LLM
history — a stale extraction callback landing after a swap would otherwise leak one child's context
into another's. `_apply_extracted_memory` gates on object identity to make late callbacks no-ops.

### State that lives outside the repo

`~/.ai-avatar/` holds `profiles/<slug>.json` (one file per child), `settings.json`, `logs/`, and — in
the packaged app — `config.yaml`. Settings-panel values (voice, level) are persisted there and applied
**over** `config.yaml` defaults at startup, so `config.yaml` is not the last word at runtime.
`config.yaml`'s `child.name` is only a default profile *selector*, never a memory store.

### Logging

Server logs go through stdlib `logging`. `app.logging_setup.configure_logging` attaches a rotating
plain-text `nova.log` beside the telemetry files, because the packaged app's stderr goes nowhere.
Conventions: standard levels; machine-relevant diagnostic events use logfmt `event key=value`
(`client_disconnect code=1001`, `capture_empty cause=no_frames`) with snake_case names matching the
telemetry `event` vocabulary; and — non-negotiable — never log transcript text or child speech to it.
The app promises audio never leaves the device; telemetry storing transcripts is the one deliberate,
separate exception.

### Constraints worth knowing before you write code

`window.prompt()` and `confirm()` are **no-ops in the Tauri WKWebView** — they return null without
showing anything. Use the in-app modal in `ui/src/main.js`. This already caused one shipped bug.

The WebSocket has an Origin allow-list. `null` is deliberately rejected while a missing Origin header
is allowed — see the comment in `app/server.py`; don't "simplify" it.

This project is GPL-3.0 (because bundled Piper TTS is GPL-3.0-or-later), which means bundled assets
must permit redistribution *for a fee*. Only permissively-licensed voices and avatars ship — verify a
VRM's own embedded `licenseName` metadata rather than trusting a listing page. A research-only voice
(`en_US-lessac`) and a mislabelled avatar have both been removed on these grounds.

The UI avatar layer (three.js/VRM) is intentionally not unit-tested; verify visual changes by running
the app.

## Docs

`ai-avatar-companion-design.md` is a **historical snapshot** — good for *why* a decision was made,
unreliable for *how* things work now (its avatar sections describe a stack that was replaced; see
`ui/README.md` for that history). Current truth lives next to the code: the protocol in
`app/server.py`'s docstring, the pipeline in the README, invariants here, test strategy in TESTING.md.

Prose that restates what code already says rots — a stale count or diagram costs more trust than it
ever bought. Prefer facts a reader can't silently contradict: put them in a docstring beside the code,
or pin them with a test. Don't add test tallies to docs; `make test` prints the real number.
