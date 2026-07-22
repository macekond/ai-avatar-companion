# Spike 1 — STT: whisper.cpp

Prove faster-whisper's role (STT for both English and Japanese, with VAD and confidence
filtering) can be replaced by an on-device iOS engine at acceptable latency/memory.

## What to build

A minimal single-view Xcode app that:
1. Loads the multilingual **"small"** ggml/CoreML model (same tier as the desktop app's
   `faster-whisper` model — see `app/pipeline/stt.py` and `config.yaml`).
2. Transcribes a **fixed pre-recorded WAV test corpus** first — short EN and JA utterances,
   deterministic, no mic variable. Only after that works, wire up live `AVAudioEngine` mic
   capture.

## Library choice

- `whisper.cpp` is already vendored at `NativeCores/whisper.cpp` (git submodule,
  github.com/ggml-org/whisper.cpp) — it ships an SPM manifest and `whisper.xcframework`.
- Also evaluate **WhisperKit** (Argmax's Swift wrapper, adds CoreML-accelerated encoder) as an
  alternative — it may solve the Swift-bridging work whisper.cpp's raw C API leaves undone.

## Port from the desktop implementation (verbatim constants, not re-derived)

From `app/pipeline/stt.py`:
- VAD: `vad_filter=True`, `min_silence_duration_ms=300` (faster-whisper's built-in Silero VAD).
  Confirm whisper.cpp/WhisperKit exposes an equivalent VAD path; if not, the per-segment
  probabilities are still available to implement confidence filtering manually.
- Confidence filtering: drop a segment if `no_speech_prob >= 0.6` or `avg_logprob < -1.0`.
- `MIN_DURATION_S = 0.3` — recordings shorter than this return `""` immediately.

## Success criteria

- Time-to-transcript for a ~3s utterance: **under 1.5s** on-device.
- Peak resident memory during inference: **under ~600MB** (the small model is ~500MB on disk;
  watch headroom against iOS jetsam limits, which are stricter on 4GB-RAM devices).
- No thermal throttling across 5 consecutive utterances within a 2-minute span.

## Failure signal / fallback

If latency/memory targets are missed, evaluate a smaller model tier (base/tiny multilingual)
as a fallback, accepting an accuracy hit — flag this trade-off back to the user rather than
deciding unilaterally.

## Status: engine verified correct on macOS (simulator-only environment — no device access)

`whisper.cpp`'s own `build-xcframework.sh` (requires `cmake`) produces
`NativeCores/whisper.cpp/build-apple/whisper.xcframework`, linked into the `Nova` Xcode target
via `project.yml`. `ios/Nova/Sources/WhisperEngine.swift` wraps the C API (`whisper_full`,
segment iteration, the `no_speech_prob` confidence gate from `app/pipeline/stt.py`) and the
whole project builds successfully with it linked.

Correctness (not performance) was verified directly against the underlying engine: built
`whisper-cli` natively for macOS, downloaded the real `tiny.en` ggml model, and transcribed
whisper.cpp's own `samples/jfk.wav` — output matched the expected quote exactly ("And so my
fellow Americans ask not what your country can do for you, ask what you can do for your
country."), confirming the model+engine pipeline itself is sound.

**Still open** (the actual point of this spike): no iOS Simulator or physical-device
transcription has been run yet (`WhisperEngine` is wired into the Xcode project but not yet
called from `NovaWebSocketServer` — `MicRecorder`'s captured samples aren't fed to it), and the
model tier decision (small vs. base vs. tiny — this smoke test used `tiny.en`, not the `small`
multilingual model the spike calls for) plus every real latency/memory/thermal number still need
a physical device.
