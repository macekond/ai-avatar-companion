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
  `app/server.py`'s `_send_settings`), `set_voice`/`preview_voice` (validated against a
  single-entry-per-language voice catalog — this app has exactly one voice per language, no
  multi-voice download infrastructure yet), barge-in (`stop_speak`), and post-turn memory extraction
  (`MemoryExtractor.swift` — a small focused LlamaEngine call after each reply pulls a topic
  keyword and any grammar problem into the profile's saved memory, guarded by `GenerationGuard`
  against a mid-extraction profile swap; port of `app/memory_extractor.py`, scoped down to not
  yet track partial-speech-before-barge-in), a rolling in-session conversation history
  (`ConversationHistory`, NovaCore — port of `LLMPipeline`'s `_history`: prior exchanges this
  session are formatted into every reply's prompt so Nova can refer back to what was just said,
  not just what's in `ChildMemory`'s cross-session topics/problems; trimmed to the last 6
  exchanges, cleared on every profile swap), a display/disk conversation-history panel
  (`TranscriptStore` — replayed as `conversation_turn`/`conversation_correction` on every
  connect/profile-switch, reset via `conversation_reset`, deleted alongside a deleted profile),
  appearance (`AppearanceStore` —
  refreshed by `avatar_loaded`'s `key`, fed into every reply's prompt so Nova can answer "what do
  you look like?" in character), and the spoken greeting itself (`sendGreeting`, port of
  `_send_greeting` — "Welcome back!", naming the most recently-discussed topic if any; fires once
  per profile-session on `start`, matching `has_greeted`).
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
- **A Development Team — only if you're archiving for a real device or TestFlight.** `project.yml`
  deliberately carries no signing config at all (no `DEVELOPMENT_TEAM`/`CODE_SIGN_STYLE`) — this
  is a public repo, and an earlier attempt at baking in an env-var placeholder for this turned out
  to break Xcode's own IDE build (Xcode resolves signing before it'll build for *anything*,
  Simulator included, unlike a headless `xcodebuild` invocation, which doesn't and made the
  breakage easy to miss). Simulator builds need no signing config at all — Xcode always falls back
  to its local "Sign to Run Locally" identity. For a real-device/TestFlight archive, set your
  Development Team once in Xcode's Signing & Capabilities tab for the `Nova` target (find your
  Team ID at [developer.apple.com/account](https://developer.apple.com/account) under Membership),
  or pass it as a one-off `xcodebuild` override —
  `DEVELOPMENT_TEAM=<team ID> CODE_SIGN_STYLE=Automatic` — so nothing team-specific ever needs to
  live in `project.yml`. Either way, re-running `xcodegen generate` regenerates the project from
  scratch and drops any signing config not present in `project.yml`, so redo it after regenerating.

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
  espeak-ng/                     vendored plain source (upstream master, v1.53.0) — CMake-based
                                  cross-compile; see 03-tts-piper/README.md
  open_jtalk/                    vendored plain source, extracted from pyopenjtalk's sdist (not
                                  a submodule — see its own VENDORED.md); see
                                  04-tts-kokoro-openjtalk/README.md
  onnxruntime/                   only fetch-onnxruntime.sh + .gitignore; the xcframework itself
                                  is downloaded, not vendored — see ios/scripts/fetch-onnxruntime.sh
```

All four native libraries are now vendored and cross-compile cleanly to iOS — see each spike's
README for the concrete build steps and verification evidence. Only the compiled build products
(`build-apple/*.xcframework`, dictionary/voice data) are gitignored; the library sources and
build scripts are committed.

## After cloning

```
git submodule update --init --recursive
brew install xcodegen
cd ios && xcodegen generate
```

## Build and run

Easiest: `open ios/Nova.xcodeproj`, pick the `Nova` scheme + a simulator (or a plugged-in
iPhone), hit ⌘R — normal Xcode debugging (breakpoints, console) works as usual.

For a scripted build/install/launch without opening Xcode (useful for a quick verify loop, or
for scripting a WebSocket test client against a freshly launched app):

```
ios/scripts/run-simulator.sh                              # boots the default simulator, builds, installs, launches
ios/scripts/run-simulator.sh "iPhone 17"                  # pick a specific simulator by name
ios/scripts/run-simulator.sh "iPhone 17" --screenshot out.png
```

This assumes the native XCFrameworks under `NativeCores/*/build-apple/` already exist — see
`ios/scripts/build-*.sh` and each spike's README if they're missing. STT/LLM/TTS engines stay
inert until their model files land in the app's Application Support directory (Phase 9's
on-demand download); the script prints the simulator app container path so you can inspect or
seed that directory directly instead of waiting on a real download.
