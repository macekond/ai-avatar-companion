# Nova iOS port

Scaffolding for a from-scratch, fully on-device iOS build of Nova. The desktop app's brain
(faster-whisper STT, Ollama LLM, Piper/Kokoro TTS, pyopenjtalk phonemization — see the root
`CLAUDE.md`) is a Python process with no iOS equivalent, so this is a native Swift/C++
reimplementation of the same protocol and pipeline behaviors, hosting the existing
`ui/` (three.js/VRM) frontend in a `WKWebView`.

## Status

**Working today, verified on iOS Simulator:**
- `NovaCore` (Swift package): TDD port of the mechanical, device-independent logic —
  CEFR/JLPT level tables + `LANGUAGE_LOCK` (`Levels.swift`), the sentence-boundary streaming
  splitter (`SentenceSegmenter.swift`), `ChildProfile`/`ChildMemory`/`MemoryManager` including
  `name_to_slug` and the delete-tombstone pattern (`Memory.swift`), prompt assembly
  (`PromptBuilder.swift`), furigana annotation behind a swappable analyzer protocol
  (`Furigana.swift`), the 5-state session machine (`SessionStateMachine.swift`), the
  one-reader-on-socket invariant (`MessageStash.swift` — not actually needed by this app's
  push-based `Network.framework` receive loop, see below), the stale-callback guard
  (`GenerationGuard.swift`, wired into `replyAndContinue`), post-turn memory-extraction parsing
  (`MemoryExtraction.swift`, ported from `app/memory_extractor.py`), and the full WebSocket wire
  protocol (`ProtocolMessages.swift`). Run `swift test` inside `ios/NovaCore/` — no simulator or
  device needed.
- `Nova` app target: a SwiftUI shell hosting the **real, unmodified** `ui/dist` build in a
  `WKWebView`, served over a custom URL scheme (`NovaSchemeHandler.swift`) rather than `file://`
  — `file://` origins are CORS-opaque in WKWebView, and Vite's `<script type="module"
  crossorigin>` output can never satisfy that, so the frontend's JS silently never ran until
  this was fixed. An in-process WebSocket server (`NovaWebSocketServer.swift`, built on
  `Network.framework`) implements the real protocol end-to-end: onboarding, profile
  switch/delete, PTT → `WhisperEngine` (whisper.cpp) → `LlamaEngine` (llama.cpp + Metal) →
  per-sentence TTS with live amplitude streaming, furigana annotation via
  `OpenJTalkMorphemeAnalyzer`, `replay` (re-speak a stored line), `set_level`/`set_language`
  (validated against `Levels`, with a `settings` resend on language change per
  `app/server.py`'s `_send_settings`), barge-in (`stop_speak`), and post-turn memory extraction
  (`MemoryExtractor.swift` — a small focused LlamaEngine call after each reply pulls a topic
  keyword and any grammar problem into the profile's saved memory, guarded by `GenerationGuard`
  against a mid-extraction profile swap; port of `app/memory_extractor.py`, scoped down to not
  yet track partial-speech-before-barge-in), conversation history (`TranscriptStore` — replayed
  as `conversation_turn`/`conversation_correction` on every connect/profile-switch, reset via
  `conversation_reset`, deleted alongside a deleted profile), and appearance (`AppearanceStore` —
  refreshed by `avatar_loaded`'s `key`, fed into every reply's prompt so Nova can answer "what do
  you look like?" in character).
  TTS is dispatched by language: `en` goes through `EspeakPhonemizer` (espeak-ng) →
  `PiperPhonemeIds` → `PiperEngine`; `ja` goes through open_jtalk → `JapanesePhonemizer` →
  `KokoroEngine`/`KokoroPlayer`. Both fall back to `SystemTTSEngine` (`AVSpeechSynthesizer`) when
  their model/data files aren't loaded yet or synthesis throws (mirrors the desktop app's "never
  hard-fail" TTS guarantee). All of STT/LLM/TTS engines are **inert until their model files
  exist** (Phase 9: on-demand download to Application Support, via `ModelDownloader` — nothing
  is bundled in the IPA). Piper's real synthesis + barge-in were verified end-to-end against a
  real cached voice model and real compiled espeak-ng dictionary data in a running Simulator app
  (not just unit tests) — see `ios/spikes/03-tts-piper/README.md`.

**Not done yet**: a production-ready model CDN (interim `modelSpecs` point straight at
HuggingFace/GitHub, not a CDN the app controls); a per-profile voice picker (Piper hardcoded to
`en_US-ljspeech-medium`, Kokoro to `af_alloy` — both checked for license lineage, see
`ios/spikes/03-tts-piper/README.md`).
Nothing has been measured on a **physical** iPhone; simulator numbers for latency, memory, and
thermal behavior are not representative of the real thing, so Phase 0's actual go/no-go question
(can whisper.cpp + llama.cpp + Kokoro/Piper/open_jtalk coexist fast enough on real hardware) is
still open. `ios/spikes/` holds the per-component spike write-ups with the real-model/real-device
verification status for each engine. `ios/PHYSICAL_DEVICE_VALIDATION.md` is a one-command
checklist for that last step: `DiagnosticsLogging.swift` instruments exactly the latency/memory
numbers Phase 0's thresholds need, at exactly the points that matter (STT latency, LLM
first-token + tokens/sec, TTS latency per engine, cumulative memory as each engine loads) —
verified firing correctly in Simulator, so a physical-device run is build, do one conversation
turn, read the log against the checklist's thresholds, not open-ended investigation.

## Environment requirements

- **Full Xcode** (not just Command Line Tools) — needed for the iOS SDK, Metal shader
  compilation, and device provisioning.
- **[XcodeGen](https://github.com/yonaskolb/XcodeGen)** (`brew install xcodegen`) generates
  `Nova.xcodeproj` from `project.yml`, which is the checked-in source of truth — the
  `.xcodeproj` itself is gitignored. After cloning or editing `project.yml`, run:
  ```
  cd ios && xcodegen generate
  ```
- **A physical iPhone** for anything performance-related. The simulator (no Metal GPU passthrough
  in the way a device has it, no real thermal/jetsam behavior) is enough to verify the app
  actually renders and the protocol wiring works, which is what's been done so far — not enough
  to answer Phase 0's real questions.

## Layout

```
ios/
  project.yml                    XcodeGen spec — source of truth for Nova.xcodeproj
  Nova/
    Sources/                     NovaApp.swift, ContentView.swift (WKWebView host),
                                  NovaSchemeHandler.swift, NovaWebSocketServer.swift
    Resources/www/               ui/dist, copied in by an Xcode prebuild script (gitignored;
                                  regenerated every build via `npm run build -- --base=./`)
  NovaCore/                      Swift package — the TDD-tested mechanical logic (see Status)
  NovaTests/                     app-level test target (thin; NovaCore's own tests do the work)
  spikes/
    01-stt-whisper/              whisper.cpp (or WhisperKit) standalone STT spike
    02-llm-llama/                llama.cpp + Metal standalone LLM spike
    03-tts-piper/                Piper (espeak-ng phonemization + onnxruntime-mobile) spike
    04-tts-kokoro-openjtalk/      Kokoro-82M + open_jtalk spike (highest risk — see its README)
NativeCores/
  whisper.cpp/                   vendored as a git submodule (github.com/ggml-org/whisper.cpp)
  llama.cpp/                     vendored as a git submodule (github.com/ggml-org/llama.cpp)
  piper-phonemize/                not yet vendored — see 03-tts-piper/README.md
  openjtalk/                     not yet vendored — see 04-tts-kokoro-openjtalk/README.md
```

`whisper.cpp` and `llama.cpp` are vendored now because the target libraries are already decided.
`piper-phonemize` and `open_jtalk` are intentionally left empty: whether an existing iOS port
exists, and which fork/version to build against, is itself part of what Spikes 3 and 4 need to
investigate first — vendoring a guess would just be noise.

## After cloning

```
git submodule update --init --recursive
brew install xcodegen
cd ios && xcodegen generate
```
