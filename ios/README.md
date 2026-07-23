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
  one-reader-on-socket invariant (`MessageStash.swift`), the stale-callback guard
  (`GenerationGuard.swift`), and the full WebSocket wire protocol (`ProtocolMessages.swift`).
  Run `swift test` inside `ios/NovaCore/` — no simulator or device needed.
- `Nova` app target: a SwiftUI shell hosting the **real, unmodified** `ui/dist` build in a
  `WKWebView`, served over a custom URL scheme (`NovaSchemeHandler.swift`) rather than `file://`
  — `file://` origins are CORS-opaque in WKWebView, and Vite's `<script type="module"
  crossorigin>` output can never satisfy that, so the frontend's JS silently never ran until
  this was fixed. An in-process WebSocket server (`NovaWebSocketServer.swift`, built on
  `Network.framework`) implements the real protocol end-to-end: onboarding, profile
  switch/delete, PTT → `WhisperEngine` (whisper.cpp) → `LlamaEngine` (llama.cpp + Metal) →
  per-sentence TTS with live amplitude streaming, furigana annotation via
  `OpenJTalkMorphemeAnalyzer`, and barge-in (`stop_speak`). TTS is dispatched by language: `en`
  always goes through `SystemTTSEngine` (`AVSpeechSynthesizer`, since Piper remains blocked —
  see `ios/spikes/03-tts-piper`); `ja` goes through open_jtalk → `JapanesePhonemizer` →
  `KokoroEngine`/`KokoroPlayer` when a Kokoro model, voices file, and dictionary are all present
  on disk, falling back to `SystemTTSEngine` otherwise (mirrors the desktop app's "never
  hard-fail" TTS guarantee). All of STT/LLM/TTS engines are **inert until their model files
  exist** (Phase 9: on-demand download to Application Support, via `ModelDownloader` — nothing
  is bundled in the IPA).

**Not done yet**: Piper's espeak-ng autotools cross-compile (English TTS relies on the
`AVSpeechSynthesizer` fallback until this lands); a production-ready model CDN (interim
`modelSpecs` point straight at HuggingFace/GitHub, not a CDN the app controls); a per-profile
voice picker for Kokoro (hardcoded to `af_alloy`). Nothing has been measured on a **physical**
iPhone; simulator numbers for latency, memory, and thermal behavior are not representative of
the real thing, so Phase 0's actual go/no-go question (can whisper.cpp + llama.cpp +
Kokoro/open_jtalk coexist fast enough on real hardware) is still open. `ios/spikes/` holds the
per-component spike write-ups with the real-model/real-device verification status for each
engine.

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
