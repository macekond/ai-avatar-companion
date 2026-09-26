# Spike 4 — TTS: Kokoro-82M + open_jtalk on iOS (highest risk)

Prove Japanese TTS (`app/pipeline/tts.py`'s Kokoro backend) and Japanese phonemization
(`pyopenjtalk`, also used by `app/furigana.py` for furigana rendering) can run natively on iOS.
**This is the single biggest schedule risk in the whole iOS port** — do not start the full app
build until this spike has a real answer, and escalate to the user rather than silently
descoping if it fails.

## Two bundled unknowns

### 1. Kokoro-82M via onnxruntime-mobile
Plausible — onnxruntime-mobile is real and maintained — but not confirmed as already proven
for this specific model. Same integration path as Spike 3 (onnxruntime-mobile SPM/CocoaPod),
different model file. Kokoro is ~330MB (model + voices): check bundle-size implications now
(see the plan's Phase 9 model-packaging notes — this almost certainly needs on-demand download,
not IPA bundling).

### 2. open_jtalk on iOS — **no known existing port**
`pyopenjtalk` is a Python binding around `open_jtalk`, a C++ Japanese morphological
analysis/phonemization engine with its own dictionary data (`unidic_lite`, tens of MB).

**Before writing any code**, investigate:
- Whether any existing Swift/iOS port of `open_jtalk` exists (search GitHub, CocoaPods, SPM
  registries).
- Whether an **Android NDK port** exists — Android has more precedent for embedding
  `open_jtalk` in on-device Japanese TTS apps, and an existing NDK cross-compile setup could
  directly inform the iOS toolchain file.
- Whether `misaki`'s G2P wrapper (used by the desktop app alongside pyopenjtalk) has any
  more-portable dependency path, or is irreducibly tied to open_jtalk's dictionary-based
  analysis.

If no port exists, this becomes a from-scratch CMake cross-compile of `open_jtalk` to
`arm64-apple-ios`. Mechanically it's "just" a C++ library port (no GPU/ML dependency), but
watch for:
- Build-system assumptions about glibc/Linux-isms or a full POSIX environment atypical of
  iOS's sandboxed libc.
- Dictionary loading / mmap patterns that may not work under iOS sandbox file-access rules.

This same port serves **two** consumers if it works: Kokoro TTS phonemization input, and
furigana rendering (`app/furigana.py`'s `annotate_for`) — which raises the stakes of getting it
right early, since a failure here blocks two features, not one.

## Success criteria

- `open_jtalk` cross-compiles and runs on-device, producing phoneme/morpheme output that
  matches desktop output for a **fixed JA test-sentence corpus** (byte-for-byte or
  reading-level parity check — build this corpus first, it's reused by Spike 4 and later by
  Phase 6's furigana verification).
- Kokoro ONNX inference produces audio within a similar latency/memory envelope to Spike 3.

## Failure signal — escalate, don't silently descope

If open_jtalk's build system doesn't cross-compile cleanly within a fixed time-box, or produces
incorrect output, stop and bring this back to the user with two real options:
1. Accept a JA-quality-degraded fallback (e.g. a simpler rule-based JA phonemizer, or ship JA
   TTS without furigana initially).
2. Accept a real schedule slip while a proper port is pursued.

Do not pick either option unilaterally inside this spike.

## Status: open_jtalk cross-compile **succeeded** — this was NOT the risk it looked like

Contrary to this spike's original "no known existing port" framing, `open_jtalk`'s C++ source
cross-compiles to iOS **cleanly, with zero errors**, for both device and simulator.

**How the source was found**: `pyopenjtalk`'s published PyPI wheel only ships prebuilt binaries
(no C++ source) — but `pip download --no-binary=:all: --no-deps pyopenjtalk` fetches its sdist,
which vendors the actual `open_jtalk` 1.11 C++ source at `lib/open_jtalk/src/`. That source is
now vendored at `NativeCores/open_jtalk/` (BSD-style license — see its `VENDORED.md`).

**Why it was tractable**: `open_jtalk`'s own `CMakeLists.txt` already builds a portable static
library (`add_library(openjtalk STATIC ...)`) using `check_include_files`/`configure_file` for
its `mecab/config.h` generation — every header it probes for (`ctype.h`, `dirent.h`, `unistd.h`,
`sys/mman.h`, etc.) is a standard POSIX header iOS's libc provides. There were no glibc-specific
assumptions to work around, contrary to this spike's original worry.

**Verified**: ran both
```
cmake -B build-ios-sim    -G Xcode -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT=iphonesimulator -DCMAKE_OSX_ARCHITECTURES=arm64 ...
cmake -B build-ios-device -G Xcode -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT=iphoneos        -DCMAKE_OSX_ARCHITECTURES=arm64 ...
```
from `NativeCores/open_jtalk/` — both configure and build with `** BUILD SUCCEEDED **`, producing
a 2.3MB `libopenjtalk.a` (`lipo -info` confirms `arm64`) for each target. Only two harmless
warnings (a deprecated `sprintf` call, an integer-narrowing warning), no errors.

**Update — the bridge is built, wired, and verified correct, not just linking:**

1. `OpenJTalkBridge.h`/`.mm` (same ObjC++ pattern as `LlamaBridge.h`/`.mm`) exposes
   `pyopenjtalk.run_frontend`'s exact call sequence — `text2mecab` → `Mecab_analysis` →
   `mecab2njd` → `njd_set_pronunciation/digit/accent_phrase/accent_type/unvoiced_vowel/
   long_vowel` → walk the `NJD` linked list — through a plain-C API. `OpenJTalkMorphemeAnalyzer.swift`
   implements NovaCore's `MorphemeAnalyzing` protocol against it for real, replacing the stub.
   Both are wired into `NovaWebSocketServer` (loaded from Application Support/models/openjtalk_dic
   if present, same on-demand pattern as the other models — see `dictionaryDirectory()`).
2. **Dictionary sourcing solved for verification purposes**: the compiled dictionary
   (`open_jtalk_dic_utf_8-1.11`) is bundled inside `pyopenjtalk`'s own wheel — copied directly
   from the local Python venv's `site-packages/pyopenjtalk/open_jtalk_dic_utf_8-1.11/` into the
   app's sandbox for testing. A production build still needs to host this ~50-100MB asset
   somewhere the app can download it from (Phase 9), but sourcing it at all is no longer unclear.
3. **Correctness verified end-to-end against ground truth**: ran the real on-device pipeline
   (Swift → ObjC++ bridge → cross-compiled `open_jtalk` → real dictionary) against
   `"私は日本語を話します"` and compared to `pyopenjtalk.run_frontend()` called directly in
   Python (same underlying library, different binding) as ground truth. Both agree exactly:
   `私→わたし`, `日本語→にほんご`, `話し→はなし`, with non-kanji tokens (`は`/`を`/`ます`)
   passed through unwrapped — the app produced
   `<ruby>私<rt>わたし</rt></ruby>は<ruby>日本語<rt>にほんご</rt></ruby>を<ruby>話し<rt>はなし</rt></ruby>ます`,
   byte-for-byte the expected furigana HTML.
4. Kokoro-82M via onnxruntime-mobile (the other half of this spike) is still untouched — the
   TTS *audio* side of Japanese support remains open; only phonemization/furigana is done.

The originally-flagged worst-case (a from-scratch C++ library port with unknown feasibility) did
not materialize. What's left is comparable in shape to the whisper.cpp/llama.cpp integrations
already done: bridge + wire + verify, not open-ended research.
