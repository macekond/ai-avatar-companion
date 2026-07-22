import XCTest
@testable import NovaCore

/// Verifies the "one reader on the socket" invariant (see CLAUDE.md and
/// app/server.py's `_next_raw`/`buffered_msgs`): draining the stash before
/// the underlying receiver, so a message set aside by one phase (onboarding,
/// a barge-in watcher) isn't lost or read twice by the next phase.
final class MessageStashTests: XCTestCase {
    func test_noStash_readsFromUnderlyingReceiver() async {
        var incoming = ["a", "b"]
        let stash = MessageStash<String> {
            incoming.removeFirst()
        }
        let first = await stash.next()
        XCTAssertEqual(first, "a")
    }

    func test_stashedMessage_isDrainedBeforeUnderlyingReceiver() async {
        var underlyingCallCount = 0
        var incoming = ["from_socket"]
        let stash = MessageStash<String> {
            underlyingCallCount += 1
            return incoming.removeFirst()
        }
        stash.push("stashed_by_onboarding")

        let first = await stash.next()
        XCTAssertEqual(first, "stashed_by_onboarding")
        XCTAssertEqual(underlyingCallCount, 0, "a stashed message must not trigger a real socket read")

        let second = await stash.next()
        XCTAssertEqual(second, "from_socket")
        XCTAssertEqual(underlyingCallCount, 1)
    }

    func test_multipleStashedMessages_drainInFIFOOrder() async {
        let stash = MessageStash<String> { "unexpected_socket_read" }
        stash.push("first")
        stash.push("second")

        let a = await stash.next()
        let b = await stash.next()
        XCTAssertEqual(a, "first")
        XCTAssertEqual(b, "second")
    }

    func test_pushBack_doesNotReplayForeverAndOnlyServesOnce() async {
        // Regression guard for the documented bug: stashing into the same
        // list a reader pops from would re-serve the same message forever.
        // A correct stash must be consumed exactly once per push.
        let stash = MessageStash<String> { "socket" }
        stash.push("only_once")
        let a = await stash.next()
        let b = await stash.next()
        XCTAssertEqual(a, "only_once")
        XCTAssertEqual(b, "socket")
    }
}
