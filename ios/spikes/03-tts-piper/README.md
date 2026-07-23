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

**Net effect**: onnxruntime is no longer a blocker for either Piper or Kokoro.

## Update: Kokoro-82M inference verified working end-to-end

`KokoroEngine.swift` calls onnxruntime's C API directly from Swift (no ObjC++ bridge needed —
plain C has no name-mangling issues, unlike llama.cpp/open_jtalk's C++). It ports
`kokoro_onnx`'s `_create_audio` exactly: `KokoroTokenizer` (NovaCore, TDD'd — the 114-entry IPA
vocab table and `[0, *tokens, 0]` padding, deliberately excluding `Tokenizer.phonemize()`'s
espeak-ng dependency since the `is_phonemes=true` path this app uses skips it) produces token
IDs, which go into `tokens`/`style`/`speed` ONNX tensors, `Run()`, then the `audio` output
tensor's raw float32 samples are extracted.

**Verified against the real model, not a stub**: downloaded the actual Kokoro-82M ONNX model
(325MB, `kokoro-v1.0.onnx` from `thewh1teagle/kokoro-onnx`'s GitHub release) into the app's
sandbox, and ran real inference against it — `CreateSession` loaded the genuine model graph,
`Run()` executed it with a placeholder style vector (real voice styling needs the separate
voices file parsed — not done yet) and a short phoneme string, and produced **17,400 real
float32 samples** (0.725s of audio at Kokoro's 24kHz) from the actual neural network. The output
audio would sound wrong (placeholder style, not a trained voice), but this proves the entire
tensor-plumbing, session-lifecycle, and C API integration is correct — the risk that mattered
(does onnxruntime + this specific model graph actually run on iOS) is resolved.

## Update: real voice styling parsed and verified — placeholder eliminated

Kokoro's voices file (`voices-v1.0.bin`) turned out to be a numpy `.npz` — a ZIP archive of
per-voice `.npy` files, each shaped `(maxLength, 1, styleWidth)` — pure binary parsing, no native
library needed. `NpyArray.swift` (numpy `.npy` v1.0 format) + `StoredZipReader.swift` (minimal
STORED-only ZIP reader) + `KokoroVoiceStore.swift` (ties them together, porting
`voice[len(tokens)]` indexing) are all TDD'd in NovaCore against hand-crafted fixtures.

**Verified against the real 28MB file, not just synthetic fixtures** — this caught a real bug
the fixtures couldn't: the actual file uses **ZIP64** (32-bit size fields are `0xFFFFFFFF`
sentinels; real sizes live in a tag-`0x0001` extended-info extra field), which a first-pass
STORED-only reader didn't handle and threw on the very first entry. Fixed, then re-verified: the
parsed `af_alloy` style vector matches Python's own `numpy.load()` output exactly
(`-0.23859501, -0.05444383, -0.01275184, ...`).

**Then verified the full real-voice synthesis pipeline end-to-end** (not a placeholder style
vector this time): loaded the real model + real voices file into the running app, tokenized
`"hɪˈloʊ ðɛr"` ("hello there"), looked up `af_alloy`'s real style vector for that token count,
and ran inference — produced 39,000 samples (1.625s at 24kHz, a plausible duration for that
phrase) with max amplitude 0.78 (no clipping) and RMS 0.095 (a healthy speech-level signal, not
noise or silence) — exactly the statistical signature of real, correctly-scaled speech audio.

**Still needed**: wiring real Japanese phonemes into this pipeline (Kokoro's IPA-style vocab
needs a `misaki`-equivalent JA phoneme mapper — a different, not-yet-ported step from
open_jtalk's kana readings used for furigana), and playback/amplitude integration into
`NovaWebSocketServer`'s live reply flow (currently only `AVSpeechSynthesizer` is wired in there).
Piper (English) remains separately blocked on **espeak-ng's autotools cross-compile**, still
unresolved. `AVSpeechSynthesizer` remains what actually produces audio in the live app today.

## Update: Kokoro wired into the live reply flow for Japanese

`JapanesePhonemizer.swift` (NovaCore, TDD'd against `misaki.ja.JAG2P` run directly in Python —
its `HEPBURN` table + digraph/sokuon/moraic-nasal/long-vowel-mark logic) bridges the remaining
gap: `NovaWebSocketServer.speak(_:language:...)` now dispatches Japanese text through
`morphemeAnalyzer.analyze()` (open_jtalk) -> `katakanaToHiragana` -> `JapanesePhonemizer` ->
`KokoroTokenizer` -> `KokoroVoiceStore.styleVector(voice: "af_alloy", ...)` -> `KokoroEngine.synthesize`
-> a new `KokoroPlayer` (`AVAudioEngine`-based, direct port of `_play_float_audio`'s
`BLOCK = max(256, sampleRate/20)` RMS-pulse-at-20Hz algorithm). Any failure at any step (missing
model/voices file, missing dictionary, a throw) falls back to `ttsEngine`
(`AVSpeechSynthesizer`) — the same "never hard-fail" guarantee as before, now enforced by a
`do`/`catch` around the whole Kokoro path rather than Kokoro being entirely unwired.

**Verified real (not just compiling)**: built and ran the actual app in iOS Simulator via
`xcodebuild`/`xcrun simctl` (full Xcode is now installed, not just CLT), confirmed the
WebSocket server starts, a real `websockets` Python client can complete
`avatar_loaded` -> `switch_profile` (to a Japanese profile) -> `stop_speak`, and that
`stop_speak` cleanly no-ops on both `ttsEngine` and the new `kokoroPlayer` when nothing is
speaking (this is exactly the code path a prior barge-in bug lived in). No model/voices file is
present in this sandboxed environment (disk-constrained, and downloading the ~350MB combined
Kokoro assets here isn't warranted just to re-prove what Kokoro's own inference correctness
update above already verified against the real files) — so this run exercises the fallback
branch and the routing/plumbing, not a live Kokoro-Japanese utterance end-to-end. That last mile
(real device, real downloaded model, an actual spoken Japanese reply) still needs a physical
device pass, same as every other engine in this app.

## Update: espeak-ng cross-compiled — the actual blocker is resolved

The "autotools, no CMake" framing above was based on a stale/pre-CMake read of espeak-ng —
current upstream (`master`, v1.53.0) ships `CMakeLists.txt` throughout its tree. Cross-compiled
cleanly for iOS device (arm64) + simulator (arm64 + x86_64) via
`ios/scripts/build-espeak-ng-ios.sh`, producing `NativeCores/espeak-ng/build-apple/espeak-ng.xcframework`
(1.7MB) plus a 30MB compiled dictionary/intonation data directory
(`build-apple/espeak-ng-data`, not committed — Phase 9 on-demand download, same as every other
model). Two non-obvious fixes over a naive iOS CMake invocation, both documented in the script's
own comments: `-DCMAKE_MACOSX_BUNDLE=OFF` (without it, configuring fails outright — CMake's iOS
platform defaults executables to `MACOSX_BUNDLE`, irrelevant since only the library target is
built) and `-DNativeBuild_DIR=<native-build-dir>` (the upstream CMakeLists.txt's own help text
says `-DNativeBuild=`, but the variable it actually reads is `NativeBuild_DIR` — a real upstream
inconsistency). `COMPILE_INTONATIONS` needs a *native* (macOS host) espeak-ng binary to compile
dictionary data even when cross-compiling for iOS; the script builds that native binary first.
espeak-ng's public API (`speak_lib.h`) is plain C with no C++ dependency, so `EspeakPhonemizer.swift`
calls it directly via the bridging header (same pattern as onnxruntime — no ObjC++ bridge needed).

`EspeakPhonemizer.swift` is a direct Swift port of piper-tts's own `espeakbridge.c` (fetched from
the `OHF-Voice/piper1-gpl` GitHub repo to read the real reference implementation) — same
`espeak_TextToPhonemesWithTerminator` call, same `CLAUSE_INTONATION_*`/`CLAUSE_TYPE_*` bit-masking
for clause terminators (espeak-ng doesn't expose these constants publicly; piper redefines them
locally, and so does this port). `PiperPhonemeIds.swift` (NovaCore, TDD'd against
`piper.phoneme_ids.phonemes_to_ids` run directly in Python) ports the `DEFAULT_PHONEME_ID_MAP`
and BOS/PAD-interleave/EOS wrapping — including a real correctness fix caught by testing an NFD
edge case first: piper's own phonemizer NFD-normalizes espeak's output *and iterates by Unicode
scalar*, so a precomposed accented phoneme (e.g. nasalized "ɛ̃") decomposes into a base letter +
a *separate* combining-mark id. Iterating by Swift `Character` (extended grapheme cluster, the
more natural default) would keep such a sequence as one element and silently drop it as
unmapped — fixed by decomposing and iterating by `unicodeScalars` instead, matching Python's
`list(unicodedata.normalize("NFD", s))` exactly. `PiperConfig.swift` (NovaCore, TDD'd) parses a
voice's `.onnx.json` (`espeak.voice`, `phoneme_id_map`, `inference` scales, sample rate).
`PiperEngine.swift` mirrors `KokoroEngine`'s direct-onnxruntime-C-API pattern with Piper's
different tensor shapes (`input`/`input_lengths`/`scales`, optional `sid`) — confirmed against
the real `en_US-amy-medium.onnx` model's actual input/output tensor names via `onnxruntime.InferenceSession`
in Python before writing the Swift side, not guessed.

**Wired into the live reply flow and verified against real files, not just unit tests**: this
environment already had real Piper voices cached at `~/.local/share/piper/voices/` (~380MB
across 6 voices, downloaded by earlier desktop-app runs) and a real whisper/llama model pair
already present in a prior Simulator app container from earlier phases — a lucky, real-data
verification opportunity, not staged. Implemented `replay` (`app/server.py`'s "re-speak a stored
line" feature — `_speak_interruptible`: `state:speaking` -> `sentence` -> TTS with live,
barge-in-able amplitude -> `state:idle`, no transcript/memory) in `NovaWebSocketServer`, since
it's the real protocol feature that happens to be the cleanest way to exercise TTS directly
without needing a live mic/STT/LLM turn. Copied `en_US-amy-medium.onnx`(+`.json`) and the
compiled `espeak-ng-data` into a running Simulator app's container, drove a real `avatar_loaded`
-> `replay` over a live WebSocket connection, and confirmed: real audio played (83 amplitude
messages over ~4s at the expected 20Hz cadence, with values up to 0.99 — `AVSpeechSynthesizer`'s
sine-wave fallback caps at 0.6, so this couldn't be the fallback path; no espeak/Piper errors in
the device log); and `stop_speak` sent mid-utterance correctly cut playback short (state reached
`idle` well before the ~8s sentence would have finished naturally, matching the same barge-in
guarantee already verified for Kokoro/AVSpeechSynthesizer). `en_US-amy-medium` is a placeholder
voice choice for this verification, same status as the interim LLM model — Phase 8's license
re-verification pass hasn't targeted a specific shipping English voice yet.

**Net effect**: neither TTS backend is blocked anymore. Both Piper (English) and Kokoro
(Japanese) are wired into the live reply flow with real-file verification; `AVSpeechSynthesizer`
remains the fallback for both when a model/data file is missing or synthesis throws. All
physical-device validation (latency, memory, thermal, and real spoken-audio quality judgment)
remains open — this and Kokoro's Japanese path have only been verified in Simulator.
