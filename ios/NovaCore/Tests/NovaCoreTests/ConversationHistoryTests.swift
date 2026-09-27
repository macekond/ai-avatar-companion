import XCTest
@testable import NovaCore

/// Port of `LLMPipeline`'s rolling `_history` (app/pipeline/llm.py) — the
/// short-term, within-session conversational memory that lets Nova refer
/// back to what was just said, distinct from `ChildMemory`'s cross-session
/// topics/problems.
final class ConversationHistoryTests: XCTestCase {
    func test_trimsToMaxExchanges_keepingMostRecent() {
        // Port of `_trim_history`: keeps only the last N exchange pairs.
        var history = ConversationHistory(maxExchanges: 2)
        history.append(you: "one", nova: "1")
        history.append(you: "two", nova: "2")
        history.append(you: "three", nova: "3")
        XCTAssertEqual(history.exchanges.map(\.you), ["two", "three"])
    }

    func test_clear_removesAllExchanges() {
        // Port of `clear_history` — called on a profile hot-swap so a new
        // profile never inherits the previous child's conversation context.
        var history = ConversationHistory()
        history.append(you: "secret", nova: "reply")
        history.clear()
        XCTAssertEqual(history.exchanges, [])
    }
}

/// `buildChatMessages` replaces `formatted()`'s flat "Child:/Nova:" text
/// block now that `LlamaBridge` sends role-tagged messages through the
/// model's own chat template instead of one raw prompt string.
final class BuildChatMessagesTests: XCTestCase {
    func test_emptyHistory_isJustSystemThenUser() {
        let messages = buildChatMessages(systemPrompt: "Be nice.", history: ConversationHistory(), userMessage: "Hi")
        XCTAssertEqual(messages, [
            ChatMessage(role: .system, content: "Be nice."),
            ChatMessage(role: .user, content: "Hi"),
        ])
    }

    func test_singleExchange_interleavesUserAndAssistant() {
        var history = ConversationHistory()
        history.append(you: "I like dogs", nova: "Dogs are great!")
        let messages = buildChatMessages(systemPrompt: "Be nice.", history: history, userMessage: "What about cats?")
        XCTAssertEqual(messages, [
            ChatMessage(role: .system, content: "Be nice."),
            ChatMessage(role: .user, content: "I like dogs"),
            ChatMessage(role: .assistant, content: "Dogs are great!"),
            ChatMessage(role: .user, content: "What about cats?"),
        ])
    }

    func test_multipleExchanges_preserveOrder() {
        var history = ConversationHistory()
        history.append(you: "Hi", nova: "Hello!")
        history.append(you: "How are you", nova: "Great, thanks!")
        let messages = buildChatMessages(systemPrompt: "sys", history: history, userMessage: "Bye")
        XCTAssertEqual(messages.map(\.role), [.system, .user, .assistant, .user, .assistant, .user])
        XCTAssertEqual(messages.map(\.content), ["sys", "Hi", "Hello!", "How are you", "Great, thanks!", "Bye"])
    }
}
