import XCTest
@testable import NovaCore

final class KatakanaToHiraganaTests: XCTestCase {
    func test_convertsKatakanaRange() {
        XCTAssertEqual(katakanaToHiragana("ワタシ"), "わたし")
    }

    func test_leavesNonKatakanaAlone() {
        XCTAssertEqual(katakanaToHiragana("私はABC123"), "私はABC123")
    }

    func test_mixedInput() {
        XCTAssertEqual(katakanaToHiragana("ニホンゴ, hello"), "にほんご, hello")
    }
}

final class ContainsKanjiTests: XCTestCase {
    func test_detectsKanji() {
        XCTAssertTrue(containsKanji("私"))
        XCTAssertTrue(containsKanji("日本語"))
    }

    func test_hiraganaOnly_isFalse() {
        XCTAssertFalse(containsKanji("わたし"))
    }

    func test_ascii_isFalse() {
        XCTAssertFalse(containsKanji("hello"))
    }
}

/// A stand-in for the real open_jtalk-backed analyzer (Phase 0 Spike 4 —
/// not yet ported to iOS). Lets FuriganaFormatter's logic be tested without
/// a native dependency.
struct StubMorphemeAnalyzer: MorphemeAnalyzing {
    let morphemes: [Morpheme]
    func analyze(_ text: String) throws -> [Morpheme] { morphemes }
}

struct FailingMorphemeAnalyzer: MorphemeAnalyzing {
    func analyze(_ text: String) throws -> [Morpheme] {
        throw NSError(domain: "test", code: 1)
    }
}

final class FuriganaFormatterTests: XCTestCase {
    func test_emptyInput_returnsEmpty() {
        let formatter = FuriganaFormatter(analyzer: FailingMorphemeAnalyzer())
        XCTAssertEqual(formatter.annotate(""), "")
    }

    func test_analyzerUnavailable_fallsBackToEscapedPlainText() {
        // Never break the reply over furigana: missing pyopenjtalk/open_jtalk
        // (Spike 4 not ported yet) must still produce valid, displayable HTML.
        let formatter = FuriganaFormatter(analyzer: FailingMorphemeAnalyzer())
        XCTAssertEqual(formatter.annotate("私<is>"), "私&lt;is&gt;")
    }

    func test_kanjiMorpheme_wrappedInRubyWithHiraganaReading() {
        let analyzer = StubMorphemeAnalyzer(morphemes: [
            Morpheme(surface: "私", readingKatakana: "ワタシ"),
            Morpheme(surface: "は", readingKatakana: "ワ"),
        ])
        let formatter = FuriganaFormatter(analyzer: analyzer)
        XCTAssertEqual(formatter.annotate("私は"), "<ruby>私<rt>わたし</rt></ruby>は")
    }

    func test_nonKanjiMorpheme_emittedEscapedAsIs() {
        let analyzer = StubMorphemeAnalyzer(morphemes: [
            Morpheme(surface: "ねこ", readingKatakana: "ネコ"),
        ])
        let formatter = FuriganaFormatter(analyzer: analyzer)
        XCTAssertEqual(formatter.annotate("ねこ"), "ねこ")
    }

    func test_missingReading_fallsBackToEscapedSurface() {
        let analyzer = StubMorphemeAnalyzer(morphemes: [
            Morpheme(surface: "私", readingKatakana: nil),
        ])
        let formatter = FuriganaFormatter(analyzer: analyzer)
        XCTAssertEqual(formatter.annotate("私"), "私")
    }

    func test_htmlSpecialCharsInSurface_areEscaped() {
        let analyzer = StubMorphemeAnalyzer(morphemes: [
            Morpheme(surface: "<b>", readingKatakana: nil),
        ])
        let formatter = FuriganaFormatter(analyzer: analyzer)
        XCTAssertEqual(formatter.annotate("<b>"), "&lt;b&gt;")
    }

    func test_annotateFor_nonJapanese_returnsNil() {
        let formatter = FuriganaFormatter(analyzer: FailingMorphemeAnalyzer())
        XCTAssertNil(formatter.annotateFor("hello", language: "en"))
    }

    func test_annotateFor_japanese_returnsAnnotatedHTML() {
        let analyzer = StubMorphemeAnalyzer(morphemes: [Morpheme(surface: "私", readingKatakana: "ワタシ")])
        let formatter = FuriganaFormatter(analyzer: analyzer)
        XCTAssertEqual(formatter.annotateFor("私", language: "ja"), "<ruby>私<rt>わたし</rt></ruby>")
    }

    func test_annotateFor_emptyText_returnsNil() {
        let formatter = FuriganaFormatter(analyzer: FailingMorphemeAnalyzer())
        XCTAssertNil(formatter.annotateFor("", language: "ja"))
    }
}
