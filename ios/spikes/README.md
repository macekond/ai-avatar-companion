# Phase 0 — feasibility spikes

Four independent, disposable Xcode projects (not architected for reuse — throw them away once
they've answered their question). Each must run on a **real iPhone**, not the simulator.
Do not start the full app build (protocol port, state machine, memory storage, etc.) until all
four have real go/no-go numbers.

Recommended target device: the oldest iPhone the product wants to still support (a reasonable
2026 floor is an iPhone 12/13-class device), since that's the actual memory/thermal constraint —
not whatever's newest and fastest.

| Spike | Component | Directory | Risk |
|---|---|---|---|
| 1 | STT — whisper.cpp / WhisperKit | `01-stt-whisper/` | Low — mature Swift path exists |
| 2 | LLM — llama.cpp + Metal | `02-llm-llama/` | Medium — memory budget is tight |
| 3 | TTS — Piper (espeak-ng + onnxruntime-mobile) | `03-tts-piper/` | Medium — no confirmed iOS package |
| 4 | TTS — Kokoro-82M + open_jtalk | `04-tts-kokoro-openjtalk/` | **High — no known iOS port of open_jtalk** |

## Exit criteria (write this up before touching Phase 1)

For each spike, record: measured latency, peak memory, thermal behavior after repeated use,
and an explicit go/no-go. Spike 4 is very likely the critical path — if it fails within a fixed
time-box, that's a decision point for the user (degraded JA phonemizer vs. a real schedule
slip), not something to silently work around.
