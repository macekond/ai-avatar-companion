#ifndef LlamaBridge_h
#define LlamaBridge_h

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Plain-C bridge to llama.cpp, kept deliberately free of any llama.h/ggml.h
/// types in this header. Both whisper.xcframework and llama.xcframework
/// bundle their own (differently versioned) copy of ggml; if Swift imports
/// both as Clang modules, it hits "'ggml_op' has different definitions in
/// different modules" trying to reconcile them. Routing llama.cpp through
/// this opaque-handle C API — implemented in LlamaBridge.mm, which #includes
/// llama.h directly as a normal (non-modular) header — means Swift only ever
/// sees `void *` here, never ggml's types, so only whisper's Clang module
/// needs to exist in Swift's module graph.
typedef void *NovaLlamaHandle;

/// One role/content turn — `role` is one of "system", "user", "assistant".
/// Both pointers are only valid for the duration of the `nova_llama_generate`
/// call that receives them.
typedef struct {
    const char *role;
    const char *content;
} NovaLlamaMessage;

/// Loads a GGUF model at `modelPath`. Returns NULL on failure.
NovaLlamaHandle nova_llama_load(const char *modelPath);

void nova_llama_free(NovaLlamaHandle handle);

/// Generates a reply to `messages` (applying the model's own chat template,
/// falling back to a manually-built ChatML string when the model has none),
/// invoking `onToken` once per decoded token piece (UTF-8, NUL-terminated,
/// valid only for the duration of the call). `context` is passed through
/// unchanged to `onToken` — used by the Swift caller to smuggle a closure
/// across the C boundary. Returns 0 on success.
///
/// Clears the engine's KV cache before decoding `messages` — every call
/// starts from a clean context rather than decoding on top of whatever a
/// previous call (a prior reply, or the memory-extractor's own prompt) left
/// behind, which used to both leak that prior prompt's content into replies
/// and eventually overflow the context window.
///
/// `onToken` returns 1 to keep generating, 0 to stop early — the Swift side
/// uses this to halt as soon as the model starts hallucinating a fake
/// continuation turn (e.g. emitting its own "Child:"/"Nova:" cue), rather
/// than grinding on to maxTokens every time.
int nova_llama_generate(
    NovaLlamaHandle handle,
    const NovaLlamaMessage *messages,
    int messageCount,
    int maxTokens,
    int (*onToken)(const char *piece, void *context),
    void *context
);

#ifdef __cplusplus
}
#endif

#endif /* LlamaBridge_h */
