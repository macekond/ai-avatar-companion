import Foundation

/// Port of `LLMPipeline`'s rolling `_history` (app/pipeline/llm.py) — the
/// short-term, within-session conversational memory that lets Nova refer
/// back to what was just said in the same conversation. Distinct from
/// `ChildMemory`'s cross-session topics/problems (which persist to disk and
/// survive a relaunch); this is in-memory only and cleared on a profile
/// hot-swap, matching `clear_history()`.
public struct ConversationHistory: Equatable {
    public struct Exchange: Equatable {
        public let you: String
        public let nova: String
    }

    public private(set) var exchanges: [Exchange] = []
    private let maxExchanges: Int

    /// `maxExchanges` matches `config.models.llm.conversation_buffer_exchanges`'s
    /// default of 6 — desktop trims to `maxExchanges * 2` messages (user +
    /// assistant per exchange); here it's naturally `maxExchanges` pairs.
    public init(maxExchanges: Int = 6) {
        self.maxExchanges = maxExchanges
    }

    /// Port of `_trim_history`: keeps only the last N exchange pairs.
    public mutating func append(you: String, nova: String) {
        exchanges.append(Exchange(you: you, nova: nova))
        if exchanges.count > maxExchanges {
            exchanges.removeFirst(exchanges.count - maxExchanges)
        }
    }

    /// Port of `clear_history`.
    public mutating func clear() {
        exchanges.removeAll()
    }

    /// Renders as alternating "Child: .../Nova: ..." blocks — for insertion
    /// into a flat prompt string ahead of the new turn's cue, since
    /// `LlamaEngine.generate` takes a single prompt string rather than a
    /// structured chat-message array (unlike Ollama's `chat()` API on
    /// desktop, which sends `_history` as separate role-tagged messages).
    public func formatted() -> String {
        exchanges.map { "Child: \($0.you)\nNova: \($0.nova)" }.joined(separator: "\n")
    }
}
