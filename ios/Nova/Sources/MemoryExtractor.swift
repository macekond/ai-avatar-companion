import Foundation
import NovaCore

/// Runs the same small, focused LLM call as `app/memory_extractor.py`'s
/// `MemoryExtractor.extract` after each turn — a non-streaming, capped
/// (`maxTokens`), temperature-0-equivalent-in-spirit prompt that returns a
/// topic keyword and any grammar problem observed. Parsing is
/// `MemoryExtraction.parse` (NovaCore, TDD'd against the real Python
/// output); this class only owns the LLM call itself, since that needs
/// `LlamaEngine`.
///
/// `LlamaEngine.generate` is the same blocking, off-main-actor call used for
/// live replies — call this off the main actor too, same as everywhere else
/// engine calls happen in this app.
enum MemoryExtractor {
    /// Returns safe defaults (`MemoryExtraction()` — no topic, no problem,
    /// `engaged: true`) on any failure, matching the Python original's
    /// silent-failure guarantee: extraction must never surface an error to
    /// the conversation. `language` picks the prompt framing (NovaCore's
    /// `MemoryExtractionPrompt`) so a Japanese profile's topic keyword comes
    /// back in Japanese instead of English.
    static func extract(transcript: String, reply: String, engine: LlamaEngine, language: String) -> MemoryExtraction {
        let prompt = MemoryExtractionPrompt.build(transcript: transcript, reply: reply, language: language)
        let messages = [ChatMessage(role: .user, content: prompt)]
        var pieces: [String] = []
        // maxTokens: 40, matching the Python original's num_predict cap —
        // this response is always 3 short lines.
        do {
            try engine.generate(messages: messages, maxTokens: 40, onSentence: { pieces.append($0) })
        } catch {
            Diagnostics.log("llm_generation_failed", ["caller": "memory_extractor"])
            return MemoryExtraction()
        }
        // LlamaEngine.generate's only public API segments by sentence
        // (`.!?` boundaries) for TTS streaming — irrelevant here since this
        // call never speaks, but it means the original newlines between
        // this prompt's TOPIC:/PROBLEM:/ENGAGED: lines are consumed as
        // segment-boundary whitespace and lost. Rejoining with "\n" is a
        // reasonable reconstruction (each label reliably starts fresh) as
        // long as no line's *value* itself contains an internal ".!?" —
        // true for the short keywords/tags this prompt asks for in
        // practice, and MemoryExtraction.parse's per-line prefix matching
        // degrades safely (unmatched text is just ignored) if it doesn't.
        return MemoryExtraction.parse(pieces.joined(separator: "\n"))
    }
}
