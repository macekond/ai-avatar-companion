# Nova iOS port

Scaffolding for a from-scratch, fully on-device iOS build of Nova. The desktop app's brain
(faster-whisper STT, Ollama LLM, Piper/Kokoro TTS, pyopenjtalk phonemization — see the root
`CLAUDE.md`) is a Python process with no iOS equivalent, so this is a native Swift/C++
reimplementation of the same protocol and pipeline behaviors, hosting the existing
`ui/` (three.js/VRM) frontend in a `WKWebView`.

## Status: Phase 0 — feasibility spike, not yet started

Nothing here builds or runs yet. `ios/spikes/` holds one subdirectory per spike — each needs to
become a disposable, minimal Xcode project that proves one native-inference component works
standalone on a real device before any of the full app (protocol port, state machine, memory
storage, etc.) gets built. See each spike's `README.md` for what to integrate and what to
measure. Do not skip ahead to the full app until all four spikes have real numbers.

## Environment requirements (not available in a terminal-only session)

- **Full Xcode** (not just Command Line Tools) — needed for the iOS SDK, Metal shader
  compilation, and device provisioning. Command Line Tools alone (`swift --version` working
  for a macOS target) is not sufficient; `xcodebuild` needs the full Xcode.app installed and
  selected via `xcode-select -s /Applications/Xcode.app`.
- **A physical iPhone**, connected and provisioned for development. Simulator numbers for
  Metal GPU performance, thermal throttling, and jetsam memory limits are not representative —
  do not treat simulator results as a spike pass.

## Layout

```
ios/
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
```
