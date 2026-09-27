import XCTest
@testable import NovaCore

/// `profileSlug(forName:)` is the create-path slug resolver (C1): unlike
/// `nameToSlug`, a name with no ASCII letters/digits (e.g. "はな") must still
/// produce a usable, stable slug rather than collapsing to "" and refusing
/// profile creation outright.
final class ProfileSlugTests: XCTestCase {
    func test_japaneseName_producesKidPlusEightHexDigits() {
        let slug = profileSlug(forName: "はな")
        XCTAssertNotNil(slug)
        XCTAssertTrue(slug!.hasPrefix("kid"))
        let hex = slug!.dropFirst(3)
        XCTAssertEqual(hex.count, 8)
        XCTAssertTrue(hex.allSatisfy { $0.isHexDigit && !$0.isUppercase })
    }

    func test_japaneseName_isStableAcrossCalls() {
        XCTAssertEqual(profileSlug(forName: "はな"), profileSlug(forName: "はな"))
    }

    func test_differentJapaneseNames_produceDifferentSlugs() {
        XCTAssertNotEqual(profileSlug(forName: "はな"), profileSlug(forName: "花"))
    }

    func test_nameWithAsciiLetters_delegatesToNameToSlug() {
        XCTAssertEqual(profileSlug(forName: "Zoë"), "zo")
    }

    func test_multiWordAsciiName_delegatesToNameToSlug() {
        XCTAssertEqual(profileSlug(forName: "Mia Rose"), "mia_rose")
    }

    func test_whitespaceOnly_isNil() {
        XCTAssertNil(profileSlug(forName: "  "))
    }

    func test_punctuationOnly_isNil() {
        XCTAssertNil(profileSlug(forName: "..."))
    }

    func test_hashedSlugIsIdempotentUnderNameToSlug() {
        let slug = profileSlug(forName: "はな")!
        XCTAssertEqual(nameToSlug(slug, fallback: ""), slug)
    }
}
