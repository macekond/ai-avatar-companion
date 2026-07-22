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

/// Loads a GGUF model at `modelPath`. Returns NULL on failure.
NovaLlamaHandle nova_llama_load(const char *modelPath);

void nova_llama_free(NovaLlamaHandle handle);

/// Generates text from `prompt`, invoking `onToken` once per decoded token
/// piece (UTF-8, NUL-terminated, valid only for the duration of the call).
/// `context` is passed through unchanged to `onToken` — used by the Swift
/// caller to smuggle a closure across the C boundary. Returns 0 on success.
int nova_llama_generate(
    NovaLlamaHandle handle,
    const char *prompt,
    int maxTokens,
    void (*onToken)(const char *piece, void *context),
    void *context
);

#ifdef __cplusplus
}
#endif

#endif /* LlamaBridge_h */
