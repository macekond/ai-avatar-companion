import Foundation
import NovaCore

/// Wraps llama.cpp + Metal (Phase 0 Spike 2 / Phase 4 of the iOS port plan)
/// — replaces `app/pipeline/llm.py`'s Ollama-backed streaming. Talks to
/// llama.cpp through `LlamaBridge`'s plain-C API rather than importing the
/// `llama` framework as a Clang module directly: both whisper.xcframework
/// and llama.xcframework vendor their own (differently versioned) copy of
/// ggml, and Swift can't reconcile two Clang modules that each declare
/// `ggml_op` differently. Routing through an opaque `void *` handle keeps
/// ggml's types out of Swift's module graph entirely (see LlamaBridge.h).
///
/// Token generation is synchronous/blocking, same as `WhisperEngine` — call
/// off the main actor.
final class LlamaEngine: @unchecked Sendable {
    enum EngineError: Error {
        case modelLoadFailed
        case generationFailed(Int32)
    }

    private let handle: NovaLlamaHandle

    /// `modelPath` is a GGUF file — not bundled (Phase 9: on-demand
    /// download), resolved by the caller.
    init(modelPath: String) throws {
        guard let handle = nova_llama_load(modelPath) else {
            throw EngineError.modelLoadFailed
        }
        self.handle = handle
    }

    deinit {
        nova_llama_free(handle)
    }

    /// Streams generated text sentence-by-sentence via `onSentence`, using
    /// `SentenceSegmenter` (NovaCore) so the boundary logic is identical to
    /// the desktop app's — the same mechanism that lets TTS start on
    /// sentence 1 before generation finishes (Phase 4's load-bearing
    /// streaming behavior, `_extract_sentences` in app/pipeline/llm.py).
    func generate(prompt: String, maxTokens: Int32 = 200, onSentence: @escaping (String) -> Void) throws {
        // onToken must be a C function pointer (no captures), so the
        // segmenter/onSentence closure is smuggled through `context` as an
        // Unmanaged reference and unpacked inside the trampoline.
        final class Box {
            var segmenter: SentenceSegmenter
            let onSentence: (String) -> Void
            let start = DispatchTime.now()
            var firstTokenMs: Int?
            var tokenCount = 0
            init(segmenter: SentenceSegmenter, onSentence: @escaping (String) -> Void) {
                self.segmenter = segmenter
                self.onSentence = onSentence
            }
        }
        let box = Box(segmenter: SentenceSegmenter(), onSentence: onSentence)
        let boxPointer = Unmanaged.passUnretained(box).toOpaque()

        let status = prompt.withCString { cPrompt in
            nova_llama_generate(handle, cPrompt, maxTokens, { cPiece, context in
                guard let context, let cPiece else { return }
                let box = Unmanaged<Box>.fromOpaque(context).takeUnretainedValue()
                if box.firstTokenMs == nil {
                    box.firstTokenMs = Int((DispatchTime.now().uptimeNanoseconds - box.start.uptimeNanoseconds) / 1_000_000)
                }
                box.tokenCount += 1
                let piece = String(cString: cPiece)
                for sentence in box.segmenter.feed(piece) {
                    box.onSentence(sentence)
                }
            }, boxPointer)
        }
        guard status == 0 else { throw EngineError.generationFailed(status) }

        let remainder = box.segmenter.flush()
        if !remainder.isEmpty { onSentence(remainder) }

        // Phase 0 Spike 2's go/no-go: <1s first-token, >=15 tok/s sustained.
        let totalMs = Int((DispatchTime.now().uptimeNanoseconds - box.start.uptimeNanoseconds) / 1_000_000)
        let tokensPerSec = totalMs > 0 ? Double(box.tokenCount) * 1000.0 / Double(totalMs) : 0
        Diagnostics.log("llm_generation", [
            "first_token_ms": String(box.firstTokenMs ?? -1), "total_ms": String(totalMs),
            "tokens": String(box.tokenCount), "tokens_per_sec": String(format: "%.1f", tokensPerSec),
            "memory_mb": String(Diagnostics.memoryFootprintMB()),
        ])
    }
}
