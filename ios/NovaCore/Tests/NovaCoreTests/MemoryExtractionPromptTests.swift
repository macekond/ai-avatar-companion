import XCTest
@testable import NovaCore

/// The exact English prompt text is transcribed from
/// `ios/Nova/Sources/MemoryExtractor.swift`'s original hardcoded template —
/// pinned here so a refactor into NovaCore can't silently reword it (parsing
/// depends only on the TOPIC:/PROBLEM:/ENGAGED: labels, but the surrounding
/// instructions are what keeps the small model's output in that format).
final class MemoryExtractionPromptTests: XCTestCase {
    func test_english_matchesOriginalTemplateExactly() {
        let expected = """
        Analyze this English learning conversation turn.

        Child said: "I played football"
        Avatar replied: "That sounds fun!"

        Reply in EXACTLY this format (3 lines, nothing else):
        TOPIC: <main topic keyword 1-3 words, or none>
        PROBLEM: <error_type: child_said -> correction, or none>
        ENGAGED: <yes or no>

        Examples:
        TOPIC: football
        PROBLEM: past_tense: goed -> went
        ENGAGED: yes

        TOPIC: none
        PROBLEM: none
        ENGAGED: no
        """
        XCTAssertEqual(
            MemoryExtractionPrompt.build(transcript: "I played football", reply: "That sounds fun!", language: "en"),
            expected
        )
    }

    func test_english_trimsWhitespaceFromTranscriptAndReply() {
        let expected = MemoryExtractionPrompt.build(transcript: "hi", reply: "hello", language: "en")
        XCTAssertEqual(
            MemoryExtractionPrompt.build(transcript: "  hi  \n", reply: " hello ", language: "en"),
            expected
        )
    }

    func test_japanese_saysJapaneseLearningConversation() {
        let prompt = MemoryExtractionPrompt.build(transcript: "サッカーをした", reply: "たのしそうだね！", language: "ja")
        XCTAssertTrue(prompt.contains("Japanese learning conversation"))
        XCTAssertFalse(prompt.contains("English learning conversation"))
    }

    func test_japanese_asksForTopicKeywordInJapanese() {
        let prompt = MemoryExtractionPrompt.build(transcript: "サッカーをした", reply: "たのしそうだね！", language: "ja")
        XCTAssertTrue(prompt.contains("in Japanese"))
        XCTAssertFalse(prompt.contains("TOPIC: football"), "the example topic must not be an English word for a Japanese prompt")
    }

    func test_japanese_keepsSameOutputFormatLabels() {
        let prompt = MemoryExtractionPrompt.build(transcript: "サッカーをした", reply: "たのしそうだね！", language: "ja")
        XCTAssertTrue(prompt.contains("TOPIC:"))
        XCTAssertTrue(prompt.contains("PROBLEM:"))
        XCTAssertTrue(prompt.contains("ENGAGED:"))
        XCTAssertTrue(prompt.contains("PROBLEM: <error_type: child_said -> correction, or none>"))
    }

    func test_unknownLanguage_fallsBackToEnglishTemplate() {
        XCTAssertEqual(
            MemoryExtractionPrompt.build(transcript: "hi", reply: "hello", language: "fr"),
            MemoryExtractionPrompt.build(transcript: "hi", reply: "hello", language: "en")
        )
    }
}
