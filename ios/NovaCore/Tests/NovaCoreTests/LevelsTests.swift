import XCTest
@testable import NovaCore

final class LevelsTests: XCTestCase {
    func test_languages_isStableOrder_englishFirst() {
        // `app/levels.py`'s LANGUAGES = list(LEVELS_BY_LANG.keys()) works
        // correctly on desktop because Python dicts preserve insertion
        // order — Swift Dictionary has no such guarantee, so `languages`
        // must be an explicit literal list, not derived from
        // levelsByLanguage.keys, or the UI's language order becomes
        // unstable across runs.
        XCTAssertEqual(Levels.languages, ["en", "ja"])
    }

    func test_levelsFor_english() {
        XCTAssertEqual(Levels.levelsFor("en"), ["Pre A", "A", "B", "C1", "C2"])
    }

    func test_levelsFor_japanese() {
        XCTAssertEqual(Levels.levelsFor("ja"), ["N5", "N4", "N3", "N2", "N1"])
    }

    func test_levelsFor_unknownLanguage_fallsBackToEnglish() {
        XCTAssertEqual(Levels.levelsFor("fr"), Levels.levelsFor("en"))
    }

    func test_defaultLevelFor_english() {
        XCTAssertEqual(Levels.defaultLevel(for: "en"), "A")
    }

    func test_defaultLevelFor_japanese() {
        XCTAssertEqual(Levels.defaultLevel(for: "ja"), "N5")
    }

    func test_defaultLevelFor_unknownLanguage_fallsBackToEnglishDefault() {
        XCTAssertEqual(Levels.defaultLevel(for: "fr"), "A")
    }

    func test_languageLock_english_mentionsEnglishOnly() {
        let lock = Levels.languageLock(for: "en")
        XCTAssertTrue(lock.contains("ALWAYS reply only in English"))
    }

    func test_languageLock_japanese_mentionsJapaneseOnly() {
        let lock = Levels.languageLock(for: "ja")
        XCTAssertTrue(lock.contains("ALWAYS reply only in Japanese"))
    }

    func test_languageLock_unknownLanguage_fallsBackToEnglishLock() {
        XCTAssertEqual(Levels.languageLock(for: "fr"), Levels.languageLock(for: "en"))
    }

    func test_teachingFrame_english_nonEmpty() {
        XCTAssertFalse(Levels.teachingFrame(for: "en").isEmpty)
    }

    func test_teachingFrame_unknownLanguage_isEmpty() {
        XCTAssertEqual(Levels.teachingFrame(for: "fr"), "")
    }

    func test_instructionsFor_knownLevelAndLanguage_nonEmpty() {
        XCTAssertFalse(Levels.instructions(forLevel: "A", language: "en").isEmpty)
        XCTAssertFalse(Levels.instructions(forLevel: "N5", language: "ja").isEmpty)
    }

    func test_instructionsFor_outOfTaxonomyLevel_isEmpty() {
        // "N5" is a JLPT level, meaningless for an English profile.
        XCTAssertEqual(Levels.instructions(forLevel: "N5", language: "en"), "")
    }

    func test_instructionsFor_unknownLanguage_isEmpty() {
        XCTAssertEqual(Levels.instructions(forLevel: "A", language: "fr"), "")
    }

    func test_allLevelsHaveInstructions() {
        for level in Levels.levelsFor("en") {
            XCTAssertFalse(Levels.instructions(forLevel: level, language: "en").isEmpty, "missing EN instructions for \(level)")
        }
        for level in Levels.levelsFor("ja") {
            XCTAssertFalse(Levels.instructions(forLevel: level, language: "ja").isEmpty, "missing JA instructions for \(level)")
        }
    }
}
