import XCTest

/// End-to-end tests that drive the actual production `NovaWebSocketServer`
/// (port 8765) `ContentView` starts for real on app launch — same
/// `NWListener`/`NWConnection` loopback socket, `SessionStateMachine`,
/// onboarding/profile flow the bundled `ui/src/main.js` talks to — over the
/// wire with a second `URLSessionWebSocketTask` client. This is the
/// "app-level integration test... that genuinely needs the iOS test host"
/// `NovaTests.swift`'s original placeholder comment called out as future
/// work, distinct from `NovaCore`'s protocol/state-machine unit tests (which
/// run offline via `swift test`, no simulator).
///
/// These tests connect to the app's own already-running server rather than
/// instantiating a second `NovaWebSocketServer` on its own port: a second
/// instance means a second `MicRecorder`, and two `AVAudioSession.setActive`
/// calls racing from two live recorders in the same process reliably hung
/// the whole test run (confirmed while writing these - the app's real
/// connection sat fine at "Hold to talk" throughout, so it wasn't a crash,
/// just two recorders fighting over one audio session). Multiple concurrent
/// *connections* to one server are fine and already relied upon by the app
/// itself (per-connection state is keyed by `ObjectIdentifier`, see
/// `NovaWebSocketServer`'s own "single-connection assumption" doc comment
/// about WKWebView reconnects) - only a second whole server instance isn't.
///
/// Each test wipes `Application Support/{profiles,transcripts}` before
/// connecting, so onboarding always starts from a clean, deterministic
/// "no profile yet" state for *this test's own connection*, regardless of
/// what the app's real WKWebView connection (already established before
/// tests run) or a previous test left behind on disk.
final class NovaWebSocketServerE2ETests: XCTestCase {
    private static let port: UInt16 = 8765

    override func setUp() async throws {
        try await super.setUp()
        clearPersistedProfileState()
    }

    private func clearPersistedProfileState() {
        let fm = FileManager.default
        guard let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        try? fm.removeItem(at: support.appendingPathComponent("profiles"))
        try? fm.removeItem(at: support.appendingPathComponent("transcripts"))
    }

    // MARK: - Minimal WebSocket test client

    private func connectClient() -> URLSessionWebSocketTask {
        let url = URL(string: "ws://127.0.0.1:\(Self.port)")!
        let task = URLSession.shared.webSocketTask(with: url)
        task.resume()
        return task
    }

    private func send(_ task: URLSessionWebSocketTask, _ payload: [String: Any]) async throws {
        let data = try JSONSerialization.data(withJSONObject: payload)
        try await task.send(.string(String(decoding: data, as: UTF8.self)))
    }

    /// One turn of onboarding (or any ptt-gated turn): press-and-immediately
    /// release. The simulator/test host has no real mic input, so the
    /// recorded duration is ~0 and `hasAudio` comes back false - this is what
    /// drives the server down its synchronous no-transcript branch.
    private func pttTurn(_ task: URLSessionWebSocketTask) async throws {
        try await send(task, ["type": "ptt_start"])
        try await send(task, ["type": "ptt_stop"])
    }

    private struct TestTimeoutError: Error {}

    private func receiveJSON(_ task: URLSessionWebSocketTask) async throws -> [String: Any] {
        let message = try await task.receive()
        switch message {
        case .string(let text):
            let data = Data(text.utf8)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                XCTFail("non-object JSON frame: \(text)")
                return [:]
            }
            return json
        case .data(let data):
            XCTFail("unexpected binary frame: \(data)")
            return [:]
        @unknown default:
            XCTFail("unexpected frame type")
            return [:]
        }
    }

    /// Drains frames until one matches `predicate`, racing a timeout so a
    /// protocol regression fails the test instead of hanging the suite.
    ///
    /// `URLSessionWebSocketTask.receive()`'s async bridge isn't
    /// cancellation-aware: calling `group.cancelAll()` after the timeout
    /// child wins the race sets the receive child's cancellation flag, but
    /// its already-pending `receive()` call keeps waiting regardless.
    /// `withThrowingTaskGroup` won't let this function return until *every*
    /// child has actually finished (a structured-concurrency guarantee), so
    /// without forcing that receive to resolve, the whole call hangs forever
    /// on timeout instead of throwing `TestTimeoutError` - this is exactly
    /// what caused this test file's real, multi-minute hangs while writing
    /// these tests, not anything in the server under test. Explicitly
    /// cancelling `task` forces its pending `receive()` to fail immediately,
    /// letting the group actually drain.
    private func receiveUntil(
        _ task: URLSessionWebSocketTask,
        timeout: TimeInterval = 15,
        _ predicate: @escaping ([String: Any]) -> Bool
    ) async throws -> [String: Any] {
        try await withThrowingTaskGroup(of: [String: Any].self) { group in
            group.addTask {
                while true {
                    let msg = try await self.receiveJSON(task)
                    if predicate(msg) { return msg }
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                task.cancel(with: .goingAway, reason: nil)
                throw TestTimeoutError()
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    /// Drives both onboarding turns to completion *without* ever waiting on
    /// `state: idle` in between: that transition is only reachable through
    /// `AVSpeechSynthesizer`'s `didFinish` delegate callback
    /// (`SystemTTSEngine`/`speakOnboardingPrompt`), which real playback under
    /// the iOS-test-host Simulator (no active audio route) never reliably
    /// fires - confirmed by instrumenting a raw frame dump here, which showed
    /// `amplitude` frames streaming indefinitely with no terminating `state:
    /// idle`. The server itself doesn't require the client to wait for
    /// speech to finish before answering the next question (`dispatch`
    /// doesn't gate `ptt_start`/`ptt_stop` on the session being idle), so
    /// this only waits on messages `dispatch` sends *synchronously* - the
    /// same messages a real UI would already have on screen the instant each
    /// question is asked, regardless of whether its audio has finished.
    /// Returns the `profiles` message `continueOnboarding`'s `.askingAge`
    /// branch sends *before* `memory_loaded`, in the same synchronous burst
    /// - waiting for `memory_loaded` alone would drain and discard it
    /// (`receiveUntil` only returns the first matching frame; every
    /// non-matching frame before it is read off the socket and gone), so
    /// callers that need it must capture it here, in the same pass.
    @discardableResult
    private func completeOnboarding(_ task: URLSessionWebSocketTask) async throws -> [String: Any] {
        try await send(task, ["type": "avatar_loaded", "key": "test-avatar"])
        _ = try await receiveUntil(task, timeout: 10) { $0["type"] as? String == "onboarding_start" }
        _ = try await receiveUntil(task, timeout: 10) { $0["type"] as? String == "sentence" } // "what's your name?"
        // Stop that prompt's never-finishing TTS (see above) before moving
        // on, so its endless `amplitude` stream can't starve a later wait's
        // timeout race.
        try await send(task, ["type": "stop_speak"])
        try await pttTurn(task) // name question
        _ = try await receiveUntil(task, timeout: 10) { $0["type"] as? String == "sentence" } // "how old are you?"
        try await send(task, ["type": "stop_speak"])
        try await pttTurn(task) // age question -> finalizes the profile synchronously
        var profiles: [String: Any] = [:]
        _ = try await receiveUntil(task, timeout: 10) { msg in
            if msg["type"] as? String == "profiles" { profiles = msg }
            return msg["type"] as? String == "memory_loaded"
        }
        return profiles
    }

    // MARK: - Happy path

    /// Basic end-to-end sanity check: a fresh connection runs the full
    /// two-turn spoken onboarding and ends up with a real, saved "child"
    /// profile the server reports back as active - the same path every
    /// first-run of the packaged app takes.
    func test_freshConnect_completesOnboardingAndCreatesActiveProfile() async throws {
        let client = connectClient()
        defer { client.cancel(with: .goingAway, reason: nil) }

        let profiles = try await completeOnboarding(client)
        XCTAssertEqual(profiles["active"] as? String, "child")
        XCTAssertEqual(profiles["list"] as? [String], ["child"])
    }

    // MARK: - Regression: onboarding's synchronous no-audio path used to clobber session state

    /// Regression test for the bug fixed alongside this test: `pttStop`'s
    /// synchronous no-audio onboarding branch (`continueOnboarding`) wrote
    /// the freshly-completed `SessionStateMachine` straight into
    /// `stateMachines[id]`, but `handle()` still held a stale pre-dispatch
    /// snapshot and unconditionally overwrote `stateMachines[id]` with it
    /// right after - silently reverting the persisted state back to
    /// "listening" even though the client had already correctly been told
    /// "idle". `stop_speak` is the one transition that's conditional on the
    /// *current* state (`SessionStateMachine.stopSpeak()` only acts from
    /// `.thinking`/`.speaking`), so it's what makes the corrupted persisted
    /// value externally observable: sent right after onboarding completes,
    /// it must echo back `idle` (a no-op), not the stale `listening`.
    func test_onboarding_stopSpeakRightAfterCompletion_reportsIdleNotListening() async throws {
        let client = connectClient()
        defer { client.cancel(with: .goingAway, reason: nil) }

        try await completeOnboarding(client)

        try await send(client, ["type": "stop_speak"])
        let state = try await receiveUntil(client) { $0["type"] as? String == "state" }
        XCTAssertEqual(
            state["state"] as? String, "idle",
            "session state must be idle right after onboarding completes, not a stale pre-dispatch value"
        )
    }

    // MARK: - Regression: deleting an unrelated profile used to reset the active session

    /// Regression test for the bug fixed alongside this test: `delete_profile`
    /// unconditionally advanced the generation guard and cleared
    /// `hasGreeted`/`conversationHistories` for the *connection* before
    /// checking whether the deleted slug was the active profile - so
    /// deleting a completely unrelated, inactive profile wiped session state
    /// for whatever profile the same connection actually had active.
    /// Observable via `hasGreeted`: deleting the inactive profile must not
    /// cause a second greeting on the next `start` for the still-active one.
    func test_deleteProfile_inactiveProfile_doesNotResetActiveSessionGreeting() async throws {
        let client = connectClient()
        defer { client.cancel(with: .goingAway, reason: nil) }

        try await completeOnboarding(client) // creates + activates "child"

        // Create a second profile ("buddy") via switch_profile with
        // language+level present, which both creates it and makes it active.
        try await send(client, ["type": "switch_profile", "slug": "buddy", "language": "en", "level": "A"])
        let switched = try await receiveUntil(client, timeout: 10) { $0["type"] as? String == "profiles" }
        XCTAssertEqual(switched["active"] as? String, "buddy")

        // Greet once on "buddy" - hasGreeted[id] becomes true for this
        // connection. Not waiting for the greeting's TTS to finish (see
        // `completeOnboarding`'s comment) - `hasGreeted[id]` is already set
        // the instant `sendGreeting` is called, synchronously, before TTS
        // even starts.
        try await send(client, ["type": "start"])
        _ = try await receiveUntil(client, timeout: 10) { $0["type"] as? String == "sentence" }

        // Delete the OTHER, inactive profile ("child"). Active profile must
        // remain "buddy", untouched.
        try await send(client, ["type": "delete_profile", "slug": "child"])
        let afterDelete = try await receiveUntil(client, timeout: 10) { $0["type"] as? String == "profiles" }
        XCTAssertEqual(afterDelete["active"] as? String, "buddy")
        XCTAssertEqual(afterDelete["list"] as? [String], ["buddy"])

        // `start` again on the same still-active "buddy" session must NOT
        // greet a second time - nothing about buddy's session changed.
        try await send(client, ["type": "start"])
        do {
            let unexpected = try await receiveUntil(client, timeout: 3) { $0["type"] as? String == "sentence" }
            XCTFail("unexpected second greeting fired: \(unexpected["text"] ?? "?")")
        } catch {
            // Expected: no greeting arrives, so `receiveUntil` times out.
            // Cancelling the socket to force that timeout to resolve (see
            // `receiveUntil`'s doc comment) races two errors on the same
            // outcome - `TestTimeoutError` from our own deadline, or a
            // transport error from the receive loop noticing the cancel
            // first - either one confirms "nothing arrived", so any thrown
            // error here is the expected, passing outcome.
        }
    }
}
