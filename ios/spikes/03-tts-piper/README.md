# Spike 3 — TTS: Piper on iOS

Prove Piper's role (English TTS in `app/pipeline/tts.py`) can run natively on-device.

## Why this is a real port, not a drop-in dependency

Piper's inference is two pieces: a small ONNX acoustic model, and `piper-phonemize`
(an espeak-ng-based C++ text-to-phoneme library). **No confirmed existing iOS package for
`piper-phonemize` was found during planning** — budget this as a genuine cross-compile of
`espeak-ng` (and `piper-phonemize`, which wraps it) to `arm64-apple-ios`. This is described as
"known-tractable but nontrivial" — espeak-ng has been cross-compiled to iOS in other
open-source TTS-on-iOS projects, so search for prior art (build scripts, CMake toolchain files)
before starting a build from scratch.

## What to build

1. First step: search for existing espeak-ng / piper-phonemize iOS cross-compile recipes
   (CMake toolchain files, other open-source projects that ship on-device Piper on iOS).
2. Cross-compile `espeak-ng` + `piper-phonemize` as a static library / XCFramework for iOS.
3. Run the acoustic model via **onnxruntime-mobile** — this has official SPM/CocoaPod
   distribution (`onnxruntime-objc` / `onnxruntime-c` pods, or Microsoft's
   `onnxruntime-swift-package-manager`), unlike piper-phonemize.
4. Wire output through `AVAudioEngine` playback and confirm RMS amplitude extraction at ~20Hz
   is reproducible (this drives the avatar's lip-sync — see `app/pipeline/tts.py`'s
   `_play_float_audio`).

## Success criteria

- End-to-end text→audio for a ~1-sentence English string: **under ~300-500ms** (Piper is
  already near-instant on desktop CPU; on-device ONNX should be comparable).
- Correct playback, and RMS amplitude values that look sane for lip-sync driving.

## Failure signal

Cross-compilation failing outright is one failure mode, but the more dangerous one is a
**silent correctness bug**: incorrect phonemization producing audio that "plays" but sounds
wrong. Verify actual output audio against the desktop Piper output for the same input text —
not just "it ran without crashing."

## Status: not started — `AVSpeechSynthesizer` wired in as the interim engine instead

The real Piper cross-compile (espeak-ng + piper-phonemize + onnxruntime-mobile) described above
hasn't been attempted — it's a genuine multi-day R&D effort and this environment can't test on a
physical device anyway. To avoid leaving the app with **no** audio output while that's pending,
`ios/Nova/Sources/SystemTTSEngine.swift` wires up `AVSpeechSynthesizer` — the same "never
hard-fail" fallback role `_SystemTTSBackend` (macOS `say`) plays in `app/pipeline/tts.py`,
including the identical sine-wave amplitude fake (`abs(sin(t*8.0))*0.6` at ~20Hz) for lip-sync,
since `AVSpeechSynthesizer` gives no more waveform access than `say` does.

**Verified working end-to-end on iOS Simulator** — not just compiling: connected a raw WebSocket
test client, drove a two-sentence reply, and confirmed real synthesis occurred (each sentence's
audio took several real seconds — not instant — with ~150 amplitude messages streamed at the
correct cadence over that time) and that sentences played back-to-back correctly. Also verified
`stop_speak` (barge-in): a real bug was caught and fixed here — cancelling the current utterance
alone let the recursive next-sentence callback keep going, so a `speechInterrupted` flag was
added and confirmed by test to actually halt the remaining reply, not just the interrupted line.

This means the app has genuine (if not final-quality) spoken output today. Piper/Kokoro remain
the real target engines for actual production quality — this spike's original scope is
unchanged and still pending a physical device + the cross-compile work above.

## Follow-up investigation: why this is harder than whisper.cpp/llama.cpp/open_jtalk were

Those three all had clean CMake-based iOS-ready build systems — genuinely tractable, as the
other spikes document. Piper's two dependencies are a different category:

- **espeak-ng** (the phonemizer `piper-phonemize` wraps) uses **autotools**, not CMake — no
  `CMakeLists.txt` anywhere in its source tree, only `configure.ac`/`Makefile.am` plus a
  separate Android NDK build (Gradle/`jni/`) that doesn't transfer to iOS. Generating `configure`
  requires `autoreconf`/`automake`/`libtool` (installed via `brew install autoconf automake
  libtool pkg-config` — straightforward) and hit friction partway through `./autogen.sh`
  (automake's dist-file checks erroring on a missing `ChangeLog.md` that persisted even after
  creating the file) before a `configure` script was ever produced. Autotools cross-compilation
  in general is more fragile than CMake's built-in iOS toolchain support (manual `--host=` triples,
  hand-written cross toolchain wrapper scripts, configure-time test programs that can't execute
  against a cross-compiled target) — this is real, bounded work, but a different scale of effort
  than the CMake-based wins.
- **onnxruntime — UPDATE: solved.** It's true there's no binary in GitHub releases, but its
  CocoaPods distribution's actual download URL was found and works: the CDN podspec path is
  MD5-sharded (`https://cdn.cocoapods.org/Specs/<h0>/<h1>/<h2>/onnxruntime-c/<version>/
  onnxruntime-c.podspec.json`, `h = md5("onnxruntime-c")`); its `source.http` field points at
  `https://download.onnxruntime.ai/pod-archive-onnxruntime-c-1.20.0.zip`, a **44MB official
  Microsoft-built xcframework** with real `ios-arm64` and `ios-arm64_x86_64-simulator` slices.
  Fetched via `ios/scripts/fetch-onnxruntime.sh`, linked into the `Nova` target (its C API headers
  needed a flattened, platform-independent copy for the bridging header — xcframework per-slice
  paths aren't directly referenceable via `HEADER_SEARCH_PATHS`), and **verified executing at
  runtime** (not just linking): called `OrtGetApiBase()` from Swift through the bridging header
  and confirmed a non-null return on iOS Simulator. All four native libraries (whisper, llama,
  open_jtalk, onnxruntime) now coexist in one target without conflict.

**Net effect**: onnxruntime is no longer a blocker for either Piper or Kokoro — the actual
remaining gap is narrower than it looked: **espeak-ng's autotools cross-compile** (Piper's
phonemizer) still needs debugging past the point reached here, and **a `KokoroEngine.swift`
inference wrapper** (session creation, input/output tensor marshaling, waveform post-processing)
hasn't been written yet — Kokoro's Japanese phonemization input can already go through the
working `open_jtalk`/`misaki`-equivalent path (Phase 6), so Kokoro may be closer to done than
Piper is. `AVSpeechSynthesizer` remains what actually produces audio today.
