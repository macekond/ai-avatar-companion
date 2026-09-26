# Nova iOS port

A from-scratch, fully on-device iOS build of Nova. The desktop app's brain (faster-whisper STT,
Ollama LLM, Piper/Kokoro TTS, pyopenjtalk phonemization — see the root `CLAUDE.md`) is a Python
process with no iOS equivalent, so this is a native Swift/C++ reimplementation of the same
protocol and pipeline behaviors, hosting the existing `ui/` (three.js/VRM) frontend in a
`WKWebView`.

## Status

**Working today, verified in the iOS Simulator against real models/data:**
- `NovaCore` (Swift package): TDD-ported, device-independent logic — levels/CEFR/JLPT + the
  `LANGUAGE_LOCK` (`Levels.swift`), the sentence-boundary streaming splitter
  (`SentenceSegmenter.swift`), `ChildProfile`/`ChildMemory`/`MemoryManager` including
  `name_to_slug` and the delete-tombstone pattern (`Memory.swift`), prompt assembly
  (`PromptBuilder.swift`), furigana annotation behind a swappable analyzer protocol
  (`Furigana.swift`), the session state machine (`SessionStateMachine.swift`, including
  `completeOnboarding()` — regression-tested after a real bug where onboarding sent a stale
  "listening" state and froze every later push-to-talk press), the stale-callback guard
  (`GenerationGuard.swift`), post-turn memory-extraction parsing (`MemoryExtraction.swift`), the
  Japanese kana→IPA phonemizer (`JapanesePhonemizer.swift`, ported from `misaki.ja`), Kokoro's
  tokenizer + voice-store (real ZIP64 `.npz` parsing), Piper's phoneme-id mapping, on-demand
  model-download progress tracking (`ModelDownload.swift` — byte/percent math, TDD'd), and the
  full WebSocket wire protocol (`ProtocolMessages.swift`). Run `swift test` inside
  `ios/NovaCore/` — no simulator or device needed. 222 tests.
- `Nova` app target: a SwiftUI shell hosting the **real, unmodified** `ui/dist` build in a
  `WKWebView`, served over a custom URL scheme (`NovaSchemeHandler.swift`, with a path-escape
  check) rather than `file://` — `file://` origins are CORS-opaque in WKWebView, breaking Vite's
  ES module output. An in-process WebSocket server (`NovaWebSocketServer.swift`, built on
  `Network.framework`) implements the real protocol end-to-end: onboarding (name + age, spoken),
  profile switch/delete (slug-sanitized against path traversal on every filesystem-touching call),
  PTT → `WhisperEngine` (whisper.cpp) → `LlamaEngine` (llama.cpp + Metal, with the model's own
  hallucinated-continuation turns detected and cut off) → per-sentence TTS with live amplitude
  streaming, furigana via `OpenJTalkMorphemeAnalyzer` (correctly off the main actor — a earlier
  bug ran open_jtalk's blocking call on the UI thread despite a `Task.detached` wrapper),
  `replay`, `set_level`/`set_language`, `set_voice`/`preview_voice` (single-entry-per-language
  catalog — see "Not done yet"), barge-in (`stop_speak`), post-turn memory extraction
  (`MemoryExtractor.swift`), rolling in-session conversation history (`ConversationHistory`), a
  disk-backed conversation transcript panel (`TranscriptStore`), appearance (`AppearanceStore`),
  and the spoken greeting (`sendGreeting`). TTS is dispatched by language: `en` goes through
  `EspeakPhonemizer` (espeak-ng) → `PiperPhonemeIds` → `PiperEngine`; `ja` goes through
  open_jtalk → `JapanesePhonemizer` → `KokoroEngine`/`KokoroPlayer`. Both fall back to
  `SystemTTSEngine` (`AVSpeechSynthesizer`) when their model files aren't loaded yet or synthesis
  throws. The shared `AVAudioSession` runs in `.playAndRecord`/`.default` (not `.measurement`,
  which silently suppressed TTS output loudness — a real bug fixed after it shipped).
- **Model downloads** (`ModelDownloader.swift`): on-demand to Application Support on first
  launch (~1 GB total — nothing is bundled in the IPA). Retries each file up to 3 times with real
  timeouts (no more indefinite hangs on a stalled connection), reports live progress as
  `NN% · received / expected MB` (shown in the setup overlay, not just a bare spinner), and
  surfaces a real `download_failed` UI state with an actionable message if every retry fails —
  previously silent failures left a permanently-broken engine behind a UI that claimed "ready".
- **App icon**: a placeholder (`Assets.xcassets/AppIcon.appiconset`, single-size 1024×1024,
  matching the app's warm palette) — functional for App Store submission, not final artwork.
- **iOS-native UI touches**: a touch push-to-talk button (`#ptt-btn` in `ui/index.html`/`style.css`,
  scoped to `body.ios-native` so the desktop Tauri build is untouched) replacing the
  desktop-only "hold Space to talk" affordance, with pointer capture and a 20s client-side
  watchdog so it can't get stuck; and a settings panel reskinned to the iOS grouped-table-view
  convention instead of the desktop pill-chip style.

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
numbers Phase 0's thresholds need — verified firing correctly in Simulator, so a physical-device
run is build, do one conversation turn, read the log against the checklist's thresholds, not
open-ended investigation.

`NovaWebSocketServer.swift` and the rest of the `Nova` app target still have **no automated test
coverage** — everything above touching that file was verified by reproducing it live against a
running app (real WebSocket messages, real logs), not by a test that would catch a regression
automatically. Where a bug's root cause was expressible as pure `NovaCore` logic (the onboarding
freeze, the download-progress math), it's been retrofitted into a tested method; most of the app
target still isn't reachable that way without real integration-test infrastructure this project
doesn't have yet.

## Environment requirements

- **Full Xcode** (not just Command Line Tools) — needed for the iOS SDK, Metal shader
  compilation, and device provisioning.
- **[XcodeGen](https://github.com/yonaskolb/XcodeGen)** (`brew install xcodegen`) generates
  `Nova.xcodeproj` from `project.yml`, which is the checked-in source of truth — the
  `.xcodeproj` itself is gitignored and gets **fully rewritten** (not merged) on every
  `xcodegen generate`, so run it only after cloning or editing `project.yml`, not before every
  ordinary rebuild:
  ```
  cd ios && xcodegen generate
  ```
- **A physical iPhone** for anything performance-related. The simulator (no Metal GPU passthrough
  in the way a device has it, no real thermal/jetsam behavior) is enough to verify the app
  actually renders and the protocol wiring works, which is what's been done so far — not enough
  to answer Phase 0's real questions.
- **A `DEVELOPMENT_TEAM` env var, exported PERMANENTLY — only if you're archiving for a real
  device or TestFlight.** `project.yml` reads it as `${DEVELOPMENT_TEAM}` (XcodeGen's env-var
  substitution) rather than committing a literal team ID to this public repo. Add this to your
  shell profile (`~/.zshrc` on a default macOS shell), not just a one-off `export` in a terminal
  tab:
  ```
  echo 'export DEVELOPMENT_TEAM=<your team ID>' >> ~/.zshrc
  ```
  Find your Team ID at [developer.apple.com/account](https://developer.apple.com/account) under
  Membership. This has to be permanent, not session-scoped: since `xcodegen generate` fully
  rewrites the project every time, any team you'd set by hand in Xcode's Signing & Capabilities
  tab is discarded on the next regeneration — the env var is what survives that. If it's unset
  when you run `xcodegen generate`, the literal string `${DEVELOPMENT_TEAM}` gets written into
  the project instead, which breaks Xcode's own build entirely (not just archiving — Xcode
  resolves signing before building for *anything*, Simulator included, unlike a headless
  `xcodebuild` invocation, which doesn't and makes the breakage easy to miss). Simulator builds
  don't need this at all — Xcode always falls back to its local "Sign to Run Locally" identity
  regardless of what's in this variable.

## Layout

```
ios/
  project.yml                    XcodeGen spec — source of truth for Nova.xcodeproj
  Nova/
    Sources/                     NovaApp.swift, ContentView.swift (WKWebView host),
                                  NovaSchemeHandler.swift, NovaWebSocketServer.swift,
                                  ModelDownloader.swift, MicRecorder.swift, engine wrappers
    Resources/
      www/                       ui/dist, copied in by an Xcode prebuild script (gitignored;
                                  regenerated every build via `npm run build -- --base=./`)
      Assets.xcassets/           App icon (placeholder — see Status)
  NovaCore/                      Swift package — the TDD-tested mechanical logic (see Status)
  NovaTests/                     app-level test target (thin; NovaCore's own tests do the work)
  scripts/
    run-simulator.sh             scripted build/install/launch (see "Build and run")
    build-espeak-ng-ios.sh       cross-compiles espeak-ng.xcframework (+ dSYMs)
    build-llama-ios-only.sh      trimmed llama.cpp xcframework build (iOS device+sim only)
    fetch-onnxruntime.sh         downloads the official prebuilt onnxruntime-c xcframework
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

All four native libraries are vendored and cross-compile cleanly to iOS — see each spike's README
for the concrete build steps and verification evidence. Only the compiled build products
(`build-apple/*.xcframework`, dictionary/voice data) are gitignored; the library sources and
build scripts are committed. `openjtalk.xcframework` and `onnxruntime.xcframework` are linked
statically, not embedded (`embed: false` in `project.yml`) — both are static archives underneath
despite the `.xcframework`/`.framework` packaging, and embedding a static library as if it were a
real dynamic framework is invalid App Store bundle structure (caught during the first real
TestFlight upload attempt).

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
on-demand download, ~1 GB); the script prints the simulator app container path so you can inspect
or seed that directory directly instead of waiting on a real download.

## Distributing (TestFlight / App Store)

Requires the permanent `DEVELOPMENT_TEAM` env var above, plus a real Apple Developer account.

1. `cd ios && xcodegen generate` (picks up the team from the env var)
2. Open `Nova.xcodeproj` in Xcode, select **Any iOS Device (arm64)** as the destination
3. In the `Nova` target's **Signing & Capabilities** tab, confirm "Automatically manage signing"
   is checked and a team is selected (should already be filled in from step 1)
4. Product → Archive
5. In the Organizer that opens: **Distribute App** → **App Store Connect** → **Upload**

A first upload for a new bundle ID needs an app record created in
[App Store Connect](https://appstoreconnect.apple.com) first (Xcode offers to create one during
the upload flow) — the bundle ID must be one only you could plausibly own (a generic ID like
`com.example.app` will likely already be taken by someone else, globally, across every developer
account, not just within your own).

`ITSAppUsesNonExemptEncryption: false` is already set in `project.yml` (the app only uses
standard OS-provided HTTPS and an unencrypted local loopback WebSocket, no custom cryptography),
so App Store Connect's Export Compliance questionnaire is skipped on every upload rather than
asked each time.

If validation rejects the archive, the most likely causes have already been hit and fixed once
each — see their fixes for the exact errors and reasoning: a static library embedded as if it
were a dynamic framework (`embed: false` on `openjtalk`/`onnxruntime` in `project.yml`), a
vendored framework missing a dSYM (`build-espeak-ng-ios.sh` now generates one), and a missing app
icon / `CFBundleIconName` (`Assets.xcassets` + the explicit `CFBundleIconName` property in
`project.yml` — Xcode only auto-injects that key for projects using the newer
`GENERATE_INFOPLIST_FILE` flow, which this project doesn't).
