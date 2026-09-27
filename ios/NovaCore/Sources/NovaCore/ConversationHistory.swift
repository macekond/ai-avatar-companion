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
}

/// One role-tagged turn for llama.cpp's chat-template API (`LlamaBridge`'s
/// `NovaLlamaMessage`) — the structured equivalent of what `ollama.chat()`
/// takes as `messages` on desktop (see `app/pipeline/llm.py`'s
/// `_build_messages`).
public struct ChatMessage: Equatable {
    public enum Role: String, Equatable {
        case system, user, assistant
    }

    public let role: Role
    public let content: String

    public init(role: Role, content: String) {
        self.role = role
        self.content = content
    }
}

/// Builds the `[system, user, assistant, user, assistant, …, user]` message
/// list a reply's LLM call sends — `history`'s exchanges interleaved between
/// the system prompt and the new turn, in place of folding everything into
/// one flat prompt string.
public func buildChatMessages(systemPrompt: String, history: ConversationHistory, userMessage: String) -> [ChatMessage] {
    var messages: [ChatMessage] = [ChatMessage(role: .system, content: systemPrompt)]
    for exchange in history.exchanges {
        messages.append(ChatMessage(role: .user, content: exchange.you))
        messages.append(ChatMessage(role: .assistant, content: exchange.nova))
    }
    messages.append(ChatMessage(role: .user, content: userMessage))
    return messages
}
