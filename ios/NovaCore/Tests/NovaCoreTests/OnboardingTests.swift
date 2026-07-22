import XCTest
@testable import NovaCore

final class ExtractNameTests: XCTestCase {
    func test_simpleStatement() {
        XCTAssertEqual(extractName(from: "my name is Lily"), "Lily")
    }

    func test_skipsFillerWords() {
        XCTAssertEqual(extractName(from: "hi it's Mia"), "Mia")
    }

    func test_capitalizesResult() {
        XCTAssertEqual(extractName(from: "lily"), "Lily")
    }

    func test_singleLetterWord_isSkipped() {
        // "len(w) >= 2" in the Python original — a stray single letter isn't
        // treated as a name.
        XCTAssertEqual(extractName(from: "i a Sam"), "Sam")
    }

    func test_noUsableWord_returnsNil() {
        XCTAssertNil(extractName(from: "my name is"))
    }

    func test_emptyString_returnsNil() {
        XCTAssertNil(extractName(from: ""))
    }

    func test_nonAlphaTokens_areStripped() {
        // "it's," strips to "its" (filler, skipped); "um," strips to "um" —
        // not in the Python original's filler list either, so it's accepted
        // as the name before reaching "Kai". A faithful port, not a bug.
        XCTAssertEqual(extractName(from: "it's, um, Kai!"), "Um")
    }
}

final class ExtractAgeTests: XCTestCase {
    func test_digitInSentence() {
        XCTAssertEqual(extractAge(from: "I am 8 years old"), 8)
    }

    func test_wordNumber() {
        XCTAssertEqual(extractAge(from: "I am seven"), 7)
    }

    func test_digitTakesPriorityOverWordNumber() {
        XCTAssertEqual(extractAge(from: "I am 9 not seven"), 9)
    }

    func test_outOfRangeDigit_isIgnored() {
        // 1...18 range in the Python original.
        XCTAssertNil(extractAge(from: "I am 42"))
    }

    func test_zeroIsOutOfRange() {
        XCTAssertNil(extractAge(from: "0"))
    }

    func test_boundaryEighteen_isValid() {
        XCTAssertEqual(extractAge(from: "18"), 18)
    }

    func test_noNumber_returnsNil() {
        XCTAssertNil(extractAge(from: "I don't know"))
    }
}

final class OnboardingFlowTests: XCTestCase {
    func test_missingName_fallsBackToFriend() {
        // Port of app/server.py's _run_onboarding: `if not name: name = "Friend"`.
        let name = extractName(from: "") ?? "Friend"
        XCTAssertEqual(name, "Friend")
    }
}
