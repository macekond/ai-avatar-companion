# Testing Strategy

## Running the tests

```bash
source .venv/bin/activate
pytest tests/ -v           # verbose — shows every test name
pytest tests/ -q           # quiet — summary only
pytest tests/ --tb=short   # on failure: short traceback
```

All 137 tests run offline. No Ollama, mic, or speakers required.

---

## Guiding principle

The pipeline is split into three clearly bounded stages — STT, LLM, TTS — each with a stable interface. The test strategy mirrors this:

- **Unit tests** validate a single module in isolation, mocking any external dependency.
- **Integration tests** verify that two or more components wire together correctly.
- **Hardware-dependent code** (TTS playback, mic recording) is intentionally excluded from automated tests; it is validated manually via `python main.py --voice` and `python run.py`.

The goal is a suite that runs fast (< 2 s), requires no credentials or hardware setup, and catches regressions in the logic that is hardest to verify by eye — config parsing, sentence streaming, state machine transitions, correction logic, amplitude wiring.

---

## Test files

| File | Type | Tests | What it covers |
|---|---|---|---|
| `test_levels.py` | Unit | 20 | CEFR level definitions, correction intensity escalation, forbidden phrasing, CEFR labels, grammar content per level |
| `test_config.py` | Unit | 22 | `_filter()` helper, dataclass defaults, `Config.load()` from YAML, `format_system_prompt()` placeholder substitution |
| `test_pipeline_llm.py` | Unit | 31 | `_extract_sentences()` edge cases, prompt building for all 5 levels, `set_level()`, history trimming with recency, pattern-review injection timing, `chat()` via mocked Ollama |
| `test_pipeline_stt.py` | Unit | 17 | Sample-rate constant, length guard, `no_speech_prob` boundary conditions (at/above/below threshold), `avg_logprob` floor, multi-segment joining and filtering |
| `test_pipeline_integration.py` | Integration | 24 | LLM→TTS per-sentence handoff, amplitude callback wiring, stop-event pre-emption and mid-stream halt, level→prompt content, STT confidence threshold gating |
| `test_server_integration.py` | Integration | 23 | WebSocket session handler (`_session`): on-connect greeting, full PTT state sequence, transcript forwarding, empty-transcript `didnt_catch` path, `set_level` routing, unknown messages, two-turn conversations |

---

## Mocking strategy

**External services that must not be called in tests:**

| Dependency | What is mocked | How |
|---|---|---|
| Ollama (LLM) | `ollama.chat()` | `unittest.mock.patch('ollama.chat', return_value=fake_stream(...))` |
| Microphone | `app.server._record()` | `@pytest.fixture(autouse=True)` with `patch('app.server._record', ...)` in the server integration file |
| Whisper model | `WhisperModel` constructor + `transcribe()` | `STTPipeline.__new__()` bypasses `__init__`; `stt._model` is set to a `MagicMock` directly |
| WebSocket connection | Full protocol | `MockWebSocket` (in `tests/conftest.py`) queues messages upfront; both `async for ws:` and `await ws.recv()` consume from the same ordered list |

**Shared fixtures** live in `tests/conftest.py`:
- `base_config` — in-memory `Config` object that skips `config.yaml` entirely.
- `MockWebSocket` — fake WebSocket used in every server integration test.

---

## Async tests

Server integration tests call `async def _session(...)` directly. `pytest-asyncio` is required:

```ini
# pytest.ini
[pytest]
asyncio_mode = auto   # all async test functions run automatically
```

Install dev dependencies:
```bash
pip install -r requirements-dev.txt
```

---

## What is intentionally not tested

| Component | Reason | How to validate manually |
|---|---|---|
| `TTSPipeline.speak_streaming()` playback | Requires audio output device | `python main.py --voice` |
| `STTPipeline.record()` | Requires microphone | `python main.py --voice` |
| `app/server.py` WebSocket bind/accept | Infrastructure, not logic | `python run.py` |
| Live2D rendering | Browser WebGL, no headless driver | `python run.py` + visual inspection |
| Full voice loop latency | Hardware-dependent | Phase 2 exit criterion: release Space → first audio ≤ 1.5 s |

The Phase 2 exit criteria from the design document serve as the manual test specification for hardware-dependent behaviour.

---

## Adding new tests

Follow the existing pattern for the appropriate tier:

**Pure logic (new function/module):** add a class to the relevant `test_*.py` file. No fixtures needed if there are no external dependencies.

**New pipeline stage:** add `tests/test_pipeline_<name>.py`. Use `__new__()` to bypass model-loading in `__init__`, then set `._model` to a `MagicMock`.

**New server message type:** add a test class to `test_server_integration.py`. Use `MockWebSocket([...])` with the message JSON and assert on `ws.sent_states()` or `ws.sent_sentences()`.

**New feature touching the system prompt:** add to `test_pipeline_llm.py::TestPromptBuilding` or `test_levels.py`. The correction feature is a good template — test both that the instruction text is present and that the behaviour differs meaningfully across relevant levels.
