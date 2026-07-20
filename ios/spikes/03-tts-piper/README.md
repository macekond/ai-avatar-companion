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
