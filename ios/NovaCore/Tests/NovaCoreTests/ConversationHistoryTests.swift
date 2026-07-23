import XCTest
@testable import NovaCore

/// Port of `LLMPipeline`'s rolling `_history` (app/pipeline/llm.py) — the
/// short-term, within-session conversational memory that lets Nova refer
/// back to what was just said, distinct from `ChildMemory`'s cross-session
/// topics/problems.
final class ConversationHistoryTests: XCTestCase {
    func test_empty_formatsAsEmptyString() {
        let history = ConversationHistory()
        XCTAssertEqual(history.formatted(), "")
    }

    func test_singleExchange_formatsAsChildNovaBlock() {
        var history = ConversationHistory()
        history.append(you: "I like dogs", nova: "Dogs are great!")
        XCTAssertEqual(history.formatted(), "Child: I like dogs\nNova: Dogs are great!")
    }

    func test_multipleExchanges_joinedInOrder() {
        var history = ConversationHistory()
        history.append(you: "Hi", nova: "Hello!")
        history.append(you: "How are you", nova: "Great, thanks!")
        XCTAssertEqual(history.formatted(), "Child: Hi\nNova: Hello!\nChild: How are you\nNova: Great, thanks!")
    }

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
        XCTAssertEqual(history.formatted(), "")
    }
}
