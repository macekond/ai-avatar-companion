import XCTest
@testable import NovaCore

final class NearestColourNameTests: XCTestCase {
    func test_pureBlack() {
        XCTAssertEqual(nearestColourName(hex: "#000000"), "black")
    }

    func test_pureWhite() {
        XCTAssertEqual(nearestColourName(hex: "#ffffff"), "white")
    }

    func test_brownish() {
        XCTAssertEqual(nearestColourName(hex: "#6b4423"), "brown")
    }

    func test_withoutHashPrefix() {
        XCTAssertEqual(nearestColourName(hex: "000000"), "black")
    }
}

final class AppearanceStoreTests: XCTestCase {
    var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    func test_get_emptyKey_returnsNil() {
        let store = AppearanceStore(cacheDir: tempDir)
        XCTAssertNil(store.get(key: ""))
        XCTAssertNil(store.get(key: "   "))
    }

    func test_get_curatedKey_returnsCuratedDescription() {
        let store = AppearanceStore(cacheDir: tempDir)
        let appearance = store.get(key: "VIPEHero_2707")
        XCTAssertEqual(appearance?.source, "curated")
        XCTAssertTrue(appearance?.description.contains("pink hair") == true)
    }

    func test_get_unknownKeyNoCacheFile_returnsNil() {
        let store = AppearanceStore(cacheDir: tempDir)
        XCTAssertNil(store.get(key: "SomeUncachedAvatar"))
    }

    func test_deriveFromRegions_thenGet_roundTripsFromCache() {
        let store = AppearanceStore(cacheDir: tempDir)
        let derived = store.deriveFromRegions(key: "CustomAvatar", regions: ["hair": "#6b4423", "clothing": "#c0392b"])
        XCTAssertEqual(derived.source, "auto")
        XCTAssertTrue(derived.description.contains("brown hair"))
        XCTAssertTrue(derived.description.contains("red clothes"))

        let loaded = store.get(key: "CustomAvatar")
        XCTAssertEqual(loaded?.description, derived.description)
        XCTAssertEqual(loaded?.source, "auto")
    }

    func test_deriveFromRegions_noRegions_fallsBackToFriendlyLook() {
        let store = AppearanceStore(cacheDir: tempDir)
        let derived = store.deriveFromRegions(key: "Blank", regions: [:])
        XCTAssertEqual(derived.description, "You have a friendly look.")
    }

    func test_get_corruptCacheFile_treatedAsMissing() throws {
        let store = AppearanceStore(cacheDir: tempDir)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        try "not json".write(to: tempDir.appendingPathComponent("badavatar.json"), atomically: true, encoding: .utf8)
        XCTAssertNil(store.get(key: "BadAvatar"))
    }
}
