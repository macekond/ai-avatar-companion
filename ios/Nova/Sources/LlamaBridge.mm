#import "LlamaBridge.h"

// Non-modular include: llama.framework's module.modulemap was deliberately
// removed (see LlamaBridge.h) so this always resolves as a plain textual
// header via the framework's search path, never as a Clang module — that's
// what keeps its ggml types out of Swift's module graph.
#include <llama/llama.h>

#include <algorithm>
#include <cstring>
#include <string>
#include <vector>
#include <TargetConditionals.h>

namespace {

struct NovaLlamaEngine {
    llama_model *model = nullptr;
    llama_context *ctx = nullptr;
    const llama_vocab *vocab = nullptr;
    bool backendInitialized = false;
};

// Used only when the model reports no built-in chat template (nullptr from
// llama_model_chat_template) or applying it fails — a plain, model-agnostic
// approximation good enough to keep the app functional rather than crashing
// or reverting to a raw unstructured prompt.
std::string buildChatMLFallback(const std::vector<llama_chat_message> &messages, bool addAssistant) {
    std::string out;
    for (const auto &message : messages) {
        out += "<|im_start|>";
        out += message.role;
        out += "\n";
        out += message.content;
        out += "<|im_end|>\n";
    }
    if (addAssistant) out += "<|im_start|>assistant\n";
    return out;
}

std::string applyChatTemplate(const llama_model *model, const std::vector<llama_chat_message> &messages, bool addAssistant) {
    const char *tmpl = llama_model_chat_template(model, nullptr);
    if (!tmpl) return buildChatMLFallback(messages, addAssistant);

    // Recommended starting size per llama_chat_apply_template's own doc
    // comment; grown and retried if the real output doesn't fit.
    int32_t bufLen = 0;
    for (const auto &message : messages) bufLen += static_cast<int32_t>(strlen(message.content)) * 2;
    bufLen = std::max(bufLen, 1024);
    std::vector<char> buf(bufLen);

    int32_t needed = llama_chat_apply_template(tmpl, messages.data(), messages.size(), addAssistant, buf.data(), bufLen);
    if (needed < 0) return buildChatMLFallback(messages, addAssistant);
    if (needed > bufLen) {
        buf.resize(needed);
        needed = llama_chat_apply_template(tmpl, messages.data(), messages.size(), addAssistant, buf.data(), needed);
        if (needed < 0) return buildChatMLFallback(messages, addAssistant);
    }
    return std::string(buf.data(), needed);
}

} // namespace

NovaLlamaHandle nova_llama_load(const char *modelPath) {
    static bool backendInitDone = false;
    if (!backendInitDone) {
        llama_backend_init();
        backendInitDone = true;
    }

    llama_model_params modelParams = llama_model_default_params();
#if TARGET_OS_SIMULATOR
    // Same iOS Simulator Metal-shim crash WhisperEngine works around (see
    // its init's comment): MTLSimDevice's shared-memory buffer allocation
    // traps on large GPU buffers. CPU-only here is simulator-only, not a
    // real-device limitation.
    modelParams.n_gpu_layers = 0;
#else
    modelParams.n_gpu_layers = 999;
#endif
    llama_model *model = llama_model_load_from_file(modelPath, modelParams);
    if (!model) return nullptr;

    llama_context_params ctxParams = llama_context_default_params();
    ctxParams.n_ctx = 2048;
    ctxParams.n_batch = 512;
    llama_context *ctx = llama_init_from_model(model, ctxParams);
    if (!ctx) {
        llama_model_free(model);
        return nullptr;
    }

    auto *engine = new NovaLlamaEngine();
    engine->model = model;
    engine->ctx = ctx;
    engine->vocab = llama_model_get_vocab(model);
    return engine;
}

void nova_llama_free(NovaLlamaHandle handle) {
    if (!handle) return;
    auto *engine = static_cast<NovaLlamaEngine *>(handle);
    if (engine->ctx) llama_free(engine->ctx);
    if (engine->model) llama_model_free(engine->model);
    delete engine;
}

int nova_llama_generate(
    NovaLlamaHandle handle,
    const NovaLlamaMessage *messages,
    int messageCount,
    int maxTokens,
    int (*onToken)(const char *piece, void *context),
    void *context
) {
    if (!handle) return -1;
    auto *engine = static_cast<NovaLlamaEngine *>(handle);

    // Every previous call's decoded tokens (a prior reply, or the
    // memory-extractor's own prompt/output run right after it on this same
    // engine) otherwise stay in the KV cache and get decoded *on top of* by
    // the next call — that's what let the system prompt leak into replies
    // and eventually overflowed the 2048-token context. See LlamaBridge.h.
    llama_memory_clear(llama_get_memory(engine->ctx), true);

    std::vector<llama_chat_message> chatMessages;
    chatMessages.reserve(messageCount);
    for (int i = 0; i < messageCount; i++) {
        chatMessages.push_back({messages[i].role, messages[i].content});
    }
    std::string promptStr = applyChatTemplate(engine->model, chatMessages, true);

    std::vector<llama_token> tokens(promptStr.size() + 8);
    int32_t nTokens = llama_tokenize(
        engine->vocab, promptStr.c_str(), static_cast<int32_t>(promptStr.size()),
        tokens.data(), static_cast<int32_t>(tokens.size()), true, true
    );
    if (nTokens <= 0) return -2;
    tokens.resize(nTokens);

    llama_sampler_chain_params samplerParams = llama_sampler_chain_default_params();
    llama_sampler *sampler = llama_sampler_chain_init(samplerParams);
    llama_sampler_chain_add(sampler, llama_sampler_init_temp(0.7f));
    llama_sampler_chain_add(sampler, llama_sampler_init_dist(0));

    // llama_decode's own GGML_ASSERT(n_tokens_all <= cparams.n_batch) aborts
    // the process (not a recoverable error return) if a single batch exceeds
    // n_batch (512, set at load time above). Nova's real system prompt
    // (personality + level instructions + memory block + appearance +
    // LANGUAGE_LOCK, see PromptBuilder) routinely exceeds 512 tokens once
    // memory/history are populated — feeding it as one llama_decode call, as
    // this used to, crashes on real conversations even though every prompt
    // used in earlier testing happened to be short enough to hide it. Fixed
    // by decoding the initial prompt in chunks of at most n_batch tokens,
    // matching llama.cpp's own examples (e.g. simple-chat.cpp).
    const int32_t nBatch = static_cast<int32_t>(llama_n_batch(engine->ctx));
    int32_t nPast = 0;
    bool promptDecodeFailed = false;
    while (nPast < nTokens) {
        int32_t chunkSize = std::min(nBatch, nTokens - nPast);
        llama_batch chunk = llama_batch_get_one(tokens.data() + nPast, chunkSize);
        if (llama_decode(engine->ctx, chunk) != 0) {
            promptDecodeFailed = true;
            break;
        }
        nPast += chunkSize;
    }
    if (promptDecodeFailed) {
        llama_sampler_free(sampler);
        return -3;
    }

    llama_token nextToken = 0;

    for (int generated = 0; generated < maxTokens; generated++) {
        llama_token newToken = llama_sampler_sample(sampler, engine->ctx, -1);
        if (llama_vocab_is_eog(engine->vocab, newToken)) break;

        char buffer[64];
        // special=false: don't render control/template tokens (e.g. ChatML's
        // <|im_end|>) as literal text into the spoken/displayed reply.
        int32_t pieceLength = llama_token_to_piece(engine->vocab, newToken, buffer, sizeof(buffer), 0, false);
        if (pieceLength < 0) break;

        std::string piece(buffer, pieceLength);
        if (!onToken(piece.c_str(), context)) break;

        nextToken = newToken;
        llama_batch batch = llama_batch_get_one(&nextToken, 1);
        if (llama_decode(engine->ctx, batch) != 0) {
            break;
        }
    }

    llama_sampler_free(sampler);
    return 0;
}
