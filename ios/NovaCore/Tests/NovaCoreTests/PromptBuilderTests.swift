import XCTest
@testable import NovaCore

final class PromptBuilderTests: XCTestCase {
    func test_order_basePersonalityComesFirst() {
        let builder = PromptBuilder(basePrompt: "BASE", language: "en", level: "A")
        XCTAssertTrue(builder.build().hasPrefix("BASE"))
    }

    func test_order_languageLockIsAlwaysLast() {
        // Load-bearing: the small local model weights the final instruction
        // most heavily, so LANGUAGE_LOCK must never be followed by anything.
        var builder = PromptBuilder(basePrompt: "BASE", language: "en", level: "A")
        builder.memory = ChildMemory(profile: ChildProfile(name: "Lily", age: 8))
        builder.appearance = "a friendly fox"
        XCTAssertTrue(builder.build().hasSuffix(Levels.languageLock(for: "en")))
    }

    func test_order_fullSequence() {
        var builder = PromptBuilder(basePrompt: "BASE", language: "en", level: "A")
        builder.memory = ChildMemory(profile: ChildProfile(name: "Lily", age: 8))
        builder.appearance = "a friendly fox"
        let prompt = builder.build()

        let base = prompt.range(of: "BASE")!
        let frame = prompt.range(of: Levels.teachingFrame(for: "en"))!
        let level = prompt.range(of: Levels.instructions(forLevel: "A", language: "en"))!
        let memory = prompt.range(of: "Memory about Lily")!
        let appearance = prompt.range(of: "a friendly fox")!
        let lock = prompt.range(of: Levels.languageLock(for: "en"))!

        XCTAssertTrue(base.lowerBound < frame.lowerBound)
        XCTAssertTrue(frame.lowerBound < level.lowerBound)
        XCTAssertTrue(level.lowerBound < memory.lowerBound)
        XCTAssertTrue(memory.lowerBound < appearance.lowerBound)
        XCTAssertTrue(appearance.lowerBound < lock.lowerBound)
    }

    func test_noMemoryOrAppearance_promptOmitsBothBlocks() {
        let builder = PromptBuilder(basePrompt: "BASE", language: "en", level: "A")
        let prompt = builder.build()
        XCTAssertFalse(prompt.contains("Memory about"))
        XCTAssertFalse(prompt.contains("About how you look"))
    }

    func test_japaneseLanguage_usesJapaneseLockAndInstructions() {
        let builder = PromptBuilder(basePrompt: "BASE", language: "ja", level: "N5")
        let prompt = builder.build()
        XCTAssertTrue(prompt.hasSuffix(Levels.languageLock(for: "ja")))
        XCTAssertTrue(prompt.contains(Levels.instructions(forLevel: "N5", language: "ja")))
    }

    func test_memoryBlock_includesRecentTopicsSortedByRecency() {
        var memory = ChildMemory(profile: ChildProfile(name: "Lily", age: 8))
        memory.topics = [
            Topic(keyword: "dinosaurs", mentionCount: 1, lastMentioned: todayString()),
            Topic(keyword: "football", mentionCount: 3, lastMentioned: todayString()),
        ]
        var builder = PromptBuilder(basePrompt: "BASE", language: "en", level: "A")
        builder.memory = memory
        let prompt = builder.build()
        XCTAssertTrue(prompt.contains("Recent topics of interest"))
        XCTAssertTrue(prompt.contains("dinosaurs"))
        XCTAssertTrue(prompt.contains("football"))
    }

    func test_memoryBlock_includesUnresolvedProblemsOnly() {
        var memory = ChildMemory(profile: ChildProfile(name: "Lily"))
        memory.problems = [
            Problem(type: "past_tense", example: "goed", correction: "went", resolved: false),
            Problem(type: "article", example: "a apple", correction: "an apple", resolved: true),
        ]
        var builder = PromptBuilder(basePrompt: "BASE", language: "en", level: "A")
        builder.memory = memory
        let prompt = builder.build()
        XCTAssertTrue(prompt.contains("Known language challenges"))
        XCTAssertTrue(prompt.contains("goed"))
        XCTAssertFalse(prompt.contains("a apple"))
    }

    func test_memoryBlock_emptyMemory_omitsHistoryHintButKeepsHeader() {
        let memory = ChildMemory(profile: ChildProfile(name: "Lily", age: 8))
        var builder = PromptBuilder(basePrompt: "BASE", language: "en", level: "A")
        builder.memory = memory
        let prompt = builder.build()
        // Freshly onboarded child: no topics/problems means no "referenced
        // history" hint, which would otherwise prime the model to invent a
        // shared past on the very first conversation.
        XCTAssertTrue(prompt.contains("Memory about Lily"))
        XCTAssertFalse(prompt.contains("yesterday you told me about"))
    }
}
