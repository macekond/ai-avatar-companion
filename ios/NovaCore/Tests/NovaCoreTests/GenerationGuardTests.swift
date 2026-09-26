import XCTest
@testable import NovaCore

/// Port of the object-identity guard in `app/server.py`'s
/// `_apply_extracted_memory` (and the same class of bug the delete-tombstone
/// pattern in `MemoryManager` guards against): a fire-and-forget async task
/// (memory extraction, a background save) can complete after a profile
/// hot-swap already moved state on — applying its result then would leak one
/// child's context into another's. A generation token makes the stale
/// callback a no-op instead of a silent corruption.
final class GenerationGuardTests: XCTestCase {
    func test_tokenValidAtCapture_stillValidIfNothingChanged() {
        let guard_ = GenerationGuard()
        let token = guard_.currentToken()
        XCTAssertTrue(guard_.isCurrent(token))
    }

    func test_advance_invalidatesPreviouslyCapturedTokens() {
        let guard_ = GenerationGuard()
        let staleToken = guard_.currentToken()
        guard_.advance()   // e.g. a profile hot-swap happened
        XCTAssertFalse(guard_.isCurrent(staleToken))
    }

    func test_advance_currentTokenAfterIsValid() {
        let guard_ = GenerationGuard()
        _ = guard_.currentToken()
        guard_.advance()
        let freshToken = guard_.currentToken()
        XCTAssertTrue(guard_.isCurrent(freshToken))
    }

    func test_staleCallback_isNoOpViaGuardedApply() {
        let guard_ = GenerationGuard()
        let token = guard_.currentToken()
        guard_.advance()  // swap happens before the background task finishes

        var applied = false
        guard_.apply(token) { applied = true }
        XCTAssertFalse(applied, "a callback captured before a swap must not mutate state after it")
    }

    func test_currentCallback_isApplied() {
        let guard_ = GenerationGuard()
        let token = guard_.currentToken()

        var applied = false
        guard_.apply(token) { applied = true }
        XCTAssertTrue(applied)
    }
}
