import XCTest
@testable import NovaCore

/// Ground truth from `app.memory_extractor.MemoryExtractor._parse`/
/// `ExtractionResult.parse_problem`, run directly in Python.
final class MemoryExtractionTests: XCTestCase {
    func test_parse_topicAndProblemAndEngaged() {
        let r = MemoryExtraction.parse("TOPIC: football\nPROBLEM: past_tense: goed -> went\nENGAGED: yes")
        XCTAssertEqual(r.topic, "football")
        XCTAssertEqual(r.problemRaw, "past_tense: goed -> went")
        XCTAssertTrue(r.engaged)
        let parsed = r.parseProblem()
        XCTAssertEqual(parsed?.type, "past_tense")
        XCTAssertEqual(parsed?.example, "goed")
        XCTAssertEqual(parsed?.correction, "went")
    }

    func test_parse_allNone_engagedNo() {
        let r = MemoryExtraction.parse("TOPIC: none\nPROBLEM: none\nENGAGED: no")
        XCTAssertNil(r.topic)
        XCTAssertNil(r.problemRaw)
        XCTAssertFalse(r.engaged)
        XCTAssertNil(r.parseProblem())
    }

    func test_parse_isCaseInsensitiveOnLabelsAndYesValue() {
        let r = MemoryExtraction.parse("topic: Cooking\nproblem: article: a apple -> an apple\nengaged: YES")
        XCTAssertEqual(r.topic, "cooking")
        let parsed = r.parseProblem()
        XCTAssertEqual(parsed?.type, "article")
        XCTAssertEqual(parsed?.example, "a apple")
        XCTAssertEqual(parsed?.correction, "an apple")
    }

    func test_parse_acceptsUnicodeArrowAndStripsQuotes() {
        let r = MemoryExtraction.parse("TOPIC: colors\nPROBLEM: verb_tense: 'she go' \u{2192} 'she goes'\nENGAGED: yes")
        let parsed = r.parseProblem()
        XCTAssertEqual(parsed?.type, "verb_tense")
        XCTAssertEqual(parsed?.example, "she go")
        XCTAssertEqual(parsed?.correction, "she goes")
    }

    func test_parse_malformedProblem_noColon_parseProblemIsNil() {
        let r = MemoryExtraction.parse("TOPIC: \nPROBLEM: malformed_no_colon\nENGAGED: n")
        XCTAssertNil(r.topic)
        XCTAssertEqual(r.problemRaw, "malformed_no_colon")
        XCTAssertFalse(r.engaged)
        XCTAssertNil(r.parseProblem())
    }

    func test_parse_emptyText_defaultsEngagedTrue() {
        // Port of ExtractionResult()'s dataclass default (engaged: bool = True)
        // — an empty/unparseable response (e.g. a silent-failure fallback)
        // must never mark a child as disengaged by omission.
        let r = MemoryExtraction.parse("")
        XCTAssertNil(r.topic)
        XCTAssertNil(r.problemRaw)
        XCTAssertTrue(r.engaged)
    }
}
