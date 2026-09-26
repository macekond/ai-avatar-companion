import XCTest
@testable import NovaCore

/// Placeholder — the bulk of the ported logic is unit-tested directly in
/// ios/NovaCore/Tests (runs via `swift test`, no simulator needed). This
/// target exists for future app-level integration tests (WKWebView +
/// NovaWebSocketServer wiring) that genuinely need the iOS test host.
final class NovaTests: XCTestCase {
    func test_novaCoreIsLinked() {
        XCTAssertEqual(Levels.defaultLevel(for: "en"), "A")
    }
}
