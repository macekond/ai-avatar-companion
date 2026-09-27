import XCTest
import NovaCore
@testable import Nova

/// Runs the real downloaded LLM (skipped when the model isn't on disk yet —
/// the app downloads it on first launch). Guards the two bugs behind "Nova
/// leaked its system prompt, then stopped answering, and never switched to
/// Japanese": the KV cache carrying every previous call into the next one,
/// and an English-only placeholder model.
final class LlamaEngineIntegrationTests: XCTestCase {
    private static let modelFilename = "llm-qwen2.5-1.5b-instruct-q4_k_m.gguf"
    private static var sharedEngine: LlamaEngine?

    private func engine() throws -> LlamaEngine {
        if let engine = Self.sharedEngine { return engine }
        let path = ModelDownloader.modelsDirectory().appendingPathComponent(Self.modelFilename).path
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("LLM not downloaded yet (\(Self.modelFilename)); launch the app once first.")
        }
        let engine = try LlamaEngine(modelPath: path)
        Self.sharedEngine = engine
        return engine
    }

    private func reply(_ engine: LlamaEngine, language: String, level: String, history: ConversationHistory = ConversationHistory(), _ userMessage: String) throws -> String {
        let system = PromptBuilder(basePrompt: PromptBuilder.defaultBasePrompt(childName: "Hana"), language: language, level: level).build()
        var sentences: [String] = []
        try engine.generate(messages: buildChatMessages(systemPrompt: system, history: history, userMessage: userMessage), maxTokens: 80) {
            sentences.append($0)
        }
        return sentences.joined(separator: " ")
    }

    private func containsJapanese(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x3040...0x30FF).contains($0.value) || (0x4E00...0x9FFF).contains($0.value) }
    }

    private func assertNoPromptLeak(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        for marker in ["TOPIC:", "PROBLEM:", "ENGAGED:", "Never break character", "learning companion", "<|im_"] {
            XCTAssertFalse(text.contains(marker), "reply leaked prompt text (\(marker)): \(text)", file: file, line: line)
        }
    }

    func test_japaneseProfile_repliesInJapanese() throws {
        let text = try reply(try engine(), language: "ja", level: "N5", "こんにちは！きょうは こうえんに いったよ。")
        XCTAssertFalse(text.isEmpty)
        XCTAssertTrue(containsJapanese(text), "expected a Japanese reply, got: \(text)")
        assertNoPromptLeak(text)
    }

    func test_japaneseProfile_afterEnglishTurns_stillRepliesInJapanese() throws {
        let engine = try engine()
        _ = try reply(engine, language: "en", level: "A", "Hi Nova! I played football today.")
        let text = try reply(engine, language: "ja", level: "N5", "ねこが すきです。")
        XCTAssertTrue(containsJapanese(text), "expected a Japanese reply after a language switch, got: \(text)")
        assertNoPromptLeak(text)
    }

    /// Reply + memory-extraction pairs back to back, as a real conversation
    /// runs them. Without clearing the KV cache each call decodes on top of
    /// every earlier one: prompt text leaks in and the 2048-token context
    /// overflows within a few calls, after which generation fails outright.
    func test_manySequentialGenerations_eachStaysCleanAndNonEmpty() throws {
        let engine = try engine()
        var history = ConversationHistory()
        for turn in ["I like dogs.", "My dog is big.", "We run in the park.", "I have a red ball.", "Do you like dogs?", "Bye Nova!"] {
            let text = try reply(engine, language: "en", level: "A", history: history, turn)
            XCTAssertFalse(text.isEmpty, "turn \"\(turn)\" produced no reply")
            assertNoPromptLeak(text)
            _ = MemoryExtractor.extract(transcript: turn, reply: text, engine: engine, language: "en")
            history.append(you: turn, nova: text)
        }
    }
}
