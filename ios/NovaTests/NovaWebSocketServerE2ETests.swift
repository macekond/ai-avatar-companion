import XCTest

/// End-to-end tests that drive the actual production `NovaWebSocketServer`
/// (port 8765) `ContentView` starts for real on app launch — same
/// `NWListener`/`NWConnection` loopback socket, `SessionStateMachine`,
/// profile-picker flow the bundled `ui/src/main.js` talks to — over the wire
/// with a second `URLSessionWebSocketTask` client. This is the "app-level
/// integration test... that genuinely needs the iOS test host"
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
/// connecting, so a fresh connection always starts from a clean,
/// deterministic "no profile yet" state for *this test's own connection*,
/// regardless of what the app's real WKWebView connection (already
/// established before tests run) or a previous test left behind on disk.
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

    private func profilesDir() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support.appendingPathComponent("profiles")
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

    /// One turn of a ptt-gated exchange: press-and-immediately release. The
    /// simulator/test host has no real mic input, so the recorded duration is
    /// ~0 and `hasAudio` comes back false - this is what drives the server
    /// down its synchronous no-transcript branch.
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

    // MARK: - Fresh connect, no profiles yet

    /// A brand-new connection with no saved profiles must present the picker
    /// (empty list) instead of auto-creating a default "child" profile and
    /// running spoken onboarding - the behavior this whole flow replaces.
    func test_freshConnect_noProfiles_receivesEmptyChooseProfile() async throws {
        let client = connectClient()
        defer { client.cancel(with: .goingAway, reason: nil) }

        try await send(client, ["type": "avatar_loaded", "key": "test-avatar"])
        let choose = try await receiveUntil(client, timeout: 10) { $0["type"] as? String == "choose_profile" }
        XCTAssertEqual(choose["list"] as? [String], [])

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: profilesDir().path),
            "no profile file should be created just by connecting and seeing the picker"
        )
    }

    // MARK: - Creating a new kid via switch_profile

    /// The picker's "new kid" form sends switch_profile with slug+language;
    /// the server must create that profile (defaulting its level for the
    /// language), make it active, and proceed exactly like a normal load.
    func test_switchProfile_newSlugWithLanguage_createsAndActivatesProfile() async throws {
        let client = connectClient()
        defer { client.cancel(with: .goingAway, reason: nil) }

        try await send(client, ["type": "avatar_loaded", "key": "test-avatar"])
        _ = try await receiveUntil(client, timeout: 10) { $0["type"] as? String == "choose_profile" }

        try await send(client, ["type": "switch_profile", "slug": "Hana", "language": "ja"])
        var profiles: [String: Any] = [:]
        let memoryLoaded = try await receiveUntil(client, timeout: 10) { msg in
            if msg["type"] as? String == "profiles" { profiles = msg }
            return msg["type"] as? String == "memory_loaded"
        }
        XCTAssertEqual(memoryLoaded["name"] as? String, "Hana")
        XCTAssertEqual(memoryLoaded["language"] as? String, "ja")
        XCTAssertEqual(memoryLoaded["level"] as? String, "N5")
        XCTAssertEqual(profiles["active"] as? String, "hana")

        let state = try await receiveUntil(client, timeout: 10) { $0["type"] as? String == "state" }
        XCTAssertEqual(state["state"] as? String, "awaiting_start")
    }

    /// A kid just created from the picker has never met Nova, so "welcome
    /// back" / "また会えてうれしい" would be wrong.
    func test_newKid_isGreetedAsNew_notWelcomedBack() async throws {
        let client = connectClient()
        defer { client.cancel(with: .goingAway, reason: nil) }

        try await send(client, ["type": "avatar_loaded", "key": "test-avatar"])
        _ = try await receiveUntil(client, timeout: 10) { $0["type"] as? String == "choose_profile" }
        try await send(client, ["type": "switch_profile", "slug": "Hana", "language": "ja"])
        _ = try await receiveUntil(client, timeout: 10) { $0["type"] as? String == "memory_loaded" }

        try await send(client, ["type": "start"])
        let greeting = try await receiveUntil(client, timeout: 10) { $0["type"] as? String == "sentence" }
        let text = greeting["text"] as? String ?? ""
        XCTAssertTrue(text.hasPrefix("はじめまして"), "expected the first-meeting greeting, got: \(text)")
    }

    // MARK: - An existing kid is offered by choose_profile and can be picked

    func test_chooseProfile_offersAndCanSelectAnExistingKid() async throws {
        let creator = connectClient()
        try await send(creator, ["type": "avatar_loaded", "key": "test-avatar"])
        _ = try await receiveUntil(creator, timeout: 10) { $0["type"] as? String == "choose_profile" }
        try await send(creator, ["type": "switch_profile", "slug": "Lily", "language": "en"])
        _ = try await receiveUntil(creator, timeout: 10) { $0["type"] as? String == "memory_loaded" }
        creator.cancel(with: .goingAway, reason: nil)

        let client = connectClient()
        defer { client.cancel(with: .goingAway, reason: nil) }
        try await send(client, ["type": "avatar_loaded", "key": "test-avatar"])
        let choose = try await receiveUntil(client, timeout: 10) { $0["type"] as? String == "choose_profile" }
        XCTAssertEqual(choose["list"] as? [String], ["lily"])

        try await send(client, ["type": "switch_profile", "slug": "lily"])
        let memoryLoaded = try await receiveUntil(client, timeout: 10) { $0["type"] as? String == "memory_loaded" }
        XCTAssertEqual(memoryLoaded["name"] as? String, "Lily")
    }

    // MARK: - Profile-gated messages are ignored before a profile is picked

    /// `ptt_start`/`ptt_stop` must not record, transcribe, or advance the
    /// session state machine while no profile is active for the connection -
    /// they must be silently ignored, not just no-ops that still echo a
    /// `state` frame.
    func test_pttBeforeProfilePicked_producesNoStateFrame() async throws {
        let client = connectClient()
        defer { client.cancel(with: .goingAway, reason: nil) }

        try await send(client, ["type": "avatar_loaded", "key": "test-avatar"])
        _ = try await receiveUntil(client, timeout: 10) { $0["type"] as? String == "choose_profile" }

        try await pttTurn(client)
        do {
            let unexpected = try await receiveUntil(client, timeout: 2) { $0["type"] as? String == "state" }
            XCTFail("unexpected state frame arrived before a profile was picked: \(unexpected)")
        } catch {
            // Expected: no `state` frame arrives, so `receiveUntil` times out.
        }
    }

    // MARK: - I1/I6/I9: choose_profile/profiles carry display names + languages

    /// The slug list alone mangles "Zoë" into "Zo" client-side and carries no
    /// language. `choose_profile`'s `kids` field must give the real display
    /// name and language back for each slug, on a *fresh* connection (i.e.
    /// read from disk, not just echoed from the creating connection's memory).
    func test_reconnect_chooseProfileKids_hasDisplayNameAndLanguage() async throws {
        let creator = connectClient()
        try await send(creator, ["type": "avatar_loaded", "key": "test-avatar"])
        _ = try await receiveUntil(creator, timeout: 10) { $0["type"] as? String == "choose_profile" }
        try await send(creator, ["type": "switch_profile", "slug": "Zoë", "language": "en"])
        _ = try await receiveUntil(creator, timeout: 10) { $0["type"] as? String == "memory_loaded" }
        creator.cancel(with: .goingAway, reason: nil)

        let client = connectClient()
        defer { client.cancel(with: .goingAway, reason: nil) }
        try await send(client, ["type": "avatar_loaded", "key": "test-avatar"])
        let choose = try await receiveUntil(client, timeout: 10) { $0["type"] as? String == "choose_profile" }
        XCTAssertEqual(choose["list"] as? [String], ["zo"])
        let kids = choose["kids"] as? [[String: Any]]
        XCTAssertEqual(kids?.count, 1)
        XCTAssertEqual(kids?.first?["slug"] as? String, "zo")
        XCTAssertEqual(kids?.first?["name"] as? String, "Zoë")
        XCTAssertEqual(kids?.first?["language"] as? String, "en")
    }

    // MARK: - I2: creating a duplicate name must not silently open the existing kid

    /// `switch_profile` WITH `language` is the "create a new kid" intent. If
    /// that name already exists, it must be rejected with `profile_error`
    /// rather than quietly loading the existing kid under a parent's nose.
    func test_switchProfile_duplicateNameWithLanguage_isRejected() async throws {
        let client = connectClient()
        defer { client.cancel(with: .goingAway, reason: nil) }

        try await send(client, ["type": "avatar_loaded", "key": "test-avatar"])
        _ = try await receiveUntil(client, timeout: 10) { $0["type"] as? String == "choose_profile" }

        try await send(client, ["type": "switch_profile", "slug": "Hana", "language": "en"])
        _ = try await receiveUntil(client, timeout: 10) { $0["type"] as? String == "memory_loaded" }

        try await send(client, ["type": "switch_profile", "slug": "hana", "language": "en"])
        let error = try await receiveUntil(client, timeout: 10) { $0["type"] as? String == "profile_error" }
        XCTAssertEqual(error["message"] as? String, "There's already a kid called Hana. Tap their name to continue.")

        do {
            let unexpected = try await receiveUntil(client, timeout: 2) { $0["type"] as? String == "memory_loaded" }
            XCTFail("unexpected memory_loaded after a rejected duplicate create: \(unexpected)")
        } catch {
            // Expected: no memory_loaded arrives.
        }
    }

    // MARK: - C1: a Japanese-script name must be able to create a kid

    /// `nameToSlug` alone strips non-ASCII, so "はな" used to sanitise to ""
    /// and profile creation was refused outright. `switch_profile` must now
    /// resolve it through `profileSlug` and create the profile, keeping the
    /// raw Japanese name as the display name.
    func test_switchProfile_japaneseName_createsProfile() async throws {
        let client = connectClient()
        defer { client.cancel(with: .goingAway, reason: nil) }

        try await send(client, ["type": "avatar_loaded", "key": "test-avatar"])
        _ = try await receiveUntil(client, timeout: 10) { $0["type"] as? String == "choose_profile" }

        try await send(client, ["type": "switch_profile", "slug": "はな", "language": "ja"])
        let memoryLoaded = try await receiveUntil(client, timeout: 10) { $0["type"] as? String == "memory_loaded" }
        XCTAssertEqual(memoryLoaded["name"] as? String, "はな")
        XCTAssertEqual(memoryLoaded["language"] as? String, "ja")
    }

    // MARK: - C3: talk button must survive a too-short/empty recording

    /// A `ptt_stop` with no usable audio (the simulator test host has no mic
    /// input, so `hasAudio` is always false) must not leave the session stuck
    /// — it must announce `didnt_catch` and speak the "didn't catch that"
    /// line in the active profile's language, not just silently stay put.
    func test_pttStopWithoutAudio_sendsDidntCatchAndSorrySentence() async throws {
        let client = connectClient()
        defer { client.cancel(with: .goingAway, reason: nil) }

        try await send(client, ["type": "avatar_loaded", "key": "test-avatar"])
        _ = try await receiveUntil(client, timeout: 10) { $0["type"] as? String == "choose_profile" }
        try await send(client, ["type": "switch_profile", "slug": "Hana", "language": "ja"])
        _ = try await receiveUntil(client, timeout: 10) { $0["type"] as? String == "memory_loaded" }

        // The `sentence` for the sorry line is sent before the `didnt_catch`
        // `state` frame (speakDidntCatch runs ahead of dispatch's trailing
        // state send) — capture it in the same pass rather than a second
        // receiveUntil call, which would discard it as an unmatched frame
        // read past on the way to `state` (see this file's receiveUntil doc
        // comment).
        try await pttTurn(client)
        var sentenceText: String?
        let didntCatch = try await receiveUntil(client, timeout: 10) { msg in
            if msg["type"] as? String == "sentence" { sentenceText = msg["text"] as? String }
            return msg["type"] as? String == "state" && (msg["state"] as? String) == "didnt_catch"
        }
        XCTAssertEqual(didntCatch["state"] as? String, "didnt_catch")
        XCTAssertEqual(sentenceText, "うまくきこえなかったよ、もう一度おしえて！")
    }

    // MARK: - I7: Nova's greeting must show in the Conversation panel

    /// The spoken greeting from `sendGreeting` must also land as a
    /// `conversation_turn` with an empty `you` (Nova spoke unprompted), so
    /// the history panel — and a later reconnect's replay — shows it.
    func test_start_greetingAppearsAsConversationTurn() async throws {
        let client = connectClient()
        defer { client.cancel(with: .goingAway, reason: nil) }

        try await send(client, ["type": "avatar_loaded", "key": "test-avatar"])
        _ = try await receiveUntil(client, timeout: 10) { $0["type"] as? String == "choose_profile" }
        try await send(client, ["type": "switch_profile", "slug": "Hana", "language": "en"])
        _ = try await receiveUntil(client, timeout: 10) { $0["type"] as? String == "memory_loaded" }

        // conversation_turn is sent before the greeting's own `sentence`
        // frame (recordTurn happens ahead of replay in sendGreeting) —
        // capture it while waiting for `sentence` rather than a second
        // receiveUntil call, which would discard it as an unmatched frame
        // read past on the way to `sentence` (see this file's receiveUntil
        // doc comment).
        try await send(client, ["type": "start"])
        var turn: [String: Any]?
        let sentence = try await receiveUntil(client, timeout: 10) { msg in
            if msg["type"] as? String == "conversation_turn" { turn = msg }
            return msg["type"] as? String == "sentence"
        }
        XCTAssertEqual(turn?["you"] as? String, "")
        XCTAssertEqual(turn?["nova"] as? String, sentence["text"] as? String)
    }

    // MARK: - I8: switching language and back restores the last level used

    /// Levels are per-language taxonomies, so switching languages must reset
    /// to a valid level for the new one — but switching back to a language
    /// already visited this profile must restore the level last set for it,
    /// not silently reset to the default every time (a regression the
    /// picker's language toggle would otherwise hit constantly).
    func test_switchLanguageAwayAndBack_restoresLastLevelForLanguage() async throws {
        let client = connectClient()
        defer { client.cancel(with: .goingAway, reason: nil) }

        try await send(client, ["type": "avatar_loaded", "key": "test-avatar"])
        _ = try await receiveUntil(client, timeout: 10) { $0["type"] as? String == "choose_profile" }
        try await send(client, ["type": "switch_profile", "slug": "Hana", "language": "en"])
        _ = try await receiveUntil(client, timeout: 10) { $0["type"] as? String == "memory_loaded" }

        try await send(client, ["type": "set_level", "level": "B"])
        _ = try await receiveUntil(client, timeout: 10) { $0["type"] as? String == "state" }

        try await send(client, ["type": "set_language", "language": "ja"])
        _ = try await receiveUntil(client, timeout: 10) { $0["type"] as? String == "settings" }

        try await send(client, ["type": "set_language", "language": "en"])
        let settings = try await receiveUntil(client, timeout: 10) { $0["type"] as? String == "settings" }
        XCTAssertEqual(settings["level"] as? String, "B")
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

        try await send(client, ["type": "avatar_loaded", "key": "test-avatar"])
        _ = try await receiveUntil(client, timeout: 10) { $0["type"] as? String == "choose_profile" }

        // Create + activate "child" via switch_profile (replaces onboarding).
        try await send(client, ["type": "switch_profile", "slug": "child", "language": "en"])
        _ = try await receiveUntil(client, timeout: 10) { $0["type"] as? String == "memory_loaded" }

        // Create a second profile ("buddy") via switch_profile with
        // language present, which both creates it and makes it active.
        try await send(client, ["type": "switch_profile", "slug": "buddy", "language": "en", "level": "A"])
        let switched = try await receiveUntil(client, timeout: 10) { $0["type"] as? String == "profiles" }
        XCTAssertEqual(switched["active"] as? String, "buddy")

        // Greet once on "buddy" - hasGreeted[id] becomes true for this
        // connection. Not waiting for the greeting's TTS to finish (it's
        // synchronous the instant sendGreeting is called, before TTS starts).
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
