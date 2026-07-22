# Spike 2 — LLM: llama.cpp + Metal

Prove Ollama's role (`llama3.2:3b`, streamed token-by-token) can be replaced by an on-device
iOS engine fast enough to sustain the sentence-by-sentence TTS streaming the desktop app relies
on for its ~1-1.5s time-to-first-word target (see CLAUDE.md's "Voice loop" section and
`app/pipeline/llm.py`).

## What to build

A minimal Xcode app driving `llama.cpp`'s Metal backend with a **token-streaming callback**,
not a blocking full-completion call — the real app needs to re-segment the token stream into
sentences as they complete (`_extract_sentences` in `app/pipeline/llm.py`), so the chosen
wrapper must expose incremental tokens.

## Library choice

- `llama.cpp` is already vendored at `NativeCores/llama.cpp` (git submodule,
  github.com/ggml-org/llama.cpp). Start from its own in-tree `examples/llama.swiftui` —
  it already demonstrates Metal-backed streaming generation with token callbacks.
- Alternatives to consider if the in-tree example is awkward to adapt: `LLM.swift`
  (eastriverlee).

## Model candidates — A/B both

- **Llama-3.2-3B-Instruct**, GGUF, Q4_K_M quantization — closest lineage to today's model,
  highest behavioral parity with existing prompt engineering.
- **Qwen2.5-3B-Instruct**, GGUF, Q4_K_M — reportedly stronger multilingual/Japanese
  instruction-following in public evals. This matters directly: `LANGUAGE_LOCK`
  (`app/levels.py`) depends on the model actually being steerable into "reply only in
  Japanese," and smaller Llama variants are historically weaker at this than Qwen. Test both
  against a fixed EN/JA prompt set specifically for language-lock adherence, not just general
  quality.

## Success criteria

- First-token latency: **under ~1s**.
- Sustained decode throughput: **≥15 tok/s** on a mid-range current-gen iPhone with Metal
  (enough to keep sentence-by-sentence TTS fed without starving).
- Peak memory for the Q4_K_M 3B model + KV cache: **under ~2.5-3GB**. This is the single
  biggest memory-budget risk in the whole app — it must coexist with STT and TTS engines
  resident at the same time during a live conversational turn (a coexistence stress test
  belongs in Phase 3/4/5 integration later, not fully captured by this spike in isolation).

## Failure signal / fallback

Memory pressure crashes/jetsam on a 4-6GB device, decode too slow to sustain streaming TTS, or
Japanese output quality unacceptable even under language-lock prompting → try a JA-specialized
small model, or flag a real schedule/scope risk back to the user rather than silently
compromising the language-lock behavior.

## Status: engine verified correct on macOS; linked into the iOS app (simulator-only environment)

Built `llama.cpp`'s own `build-xcframework.sh` — but the full script builds 7 platform slices
(iOS, iOS-sim, macOS, visionOS×2, tvOS×2) and this environment has a **very small disk quota**
(hit `ENOSPC` twice, once badly enough that the tool harness itself briefly couldn't write). Use
`NativeCores/llama.cpp/build-xcframework-ios-only.sh` instead — a trimmed copy that builds only
iOS device + simulator and deletes intermediates immediately after assembling the xcframework.

**Correctness verified directly** (not performance): built `llama-cli` natively for macOS,
downloaded a real small GGUF (`SmolLM2-135M-Instruct`, ~100MB — not the eventual 3B model
candidates, just something fast to fetch), and confirmed it loads and generates actual text via
Metal (~200 tok/s on this Mac's GPU). Output quality was poor, as expected of a 135M model — this
only confirms the engine/model-loading pipeline is sound, not anything about the real candidate
models.

**Real integration obstacle found and fixed**: `whisper.xcframework` and `llama.xcframework` each
vendor their own (differently versioned) copy of `ggml`. Importing both as Clang modules in the
same Swift target fails — `'ggml_op' has different definitions in different modules`. Fixed by
removing `llama.framework`'s `module.modulemap` (in each platform slice) so Clang can never treat
it as a module, and bridging llama.cpp through a plain-C API (`LlamaBridge.h`/`.mm`, Objective-C++
`#include <llama/llama.h>` as a normal textual header) instead of `import llama` in Swift —
`LlamaEngine.swift` talks to that C API via an opaque handle, never touching `ggml` types
directly. Both engines now link into the same `Nova` target and the app runs correctly on iOS
Simulator with both present (avatar renders, protocol handshake completes) — verified by
installing and launching the built app, not just compiling it.

**Still open** (the actual point of this spike): no real 3B candidate model (Llama-3.2-3B vs.
Qwen2.5-3B) has been tried, no JA language-lock steerability test has been run, and — as with
Spike 1 — every real latency/memory/thermal number needs a **physical iPhone**, which this
environment doesn't have.
