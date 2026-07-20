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
