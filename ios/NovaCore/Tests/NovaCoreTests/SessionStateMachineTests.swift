import XCTest
@testable import NovaCore

final class SessionStateMachineTests: XCTestCase {
    func test_initialState_isAwaitingStart() {
        let machine = SessionStateMachine()
        XCTAssertEqual(machine.state, .awaitingStart)
    }

    func test_start_movesToIdle() {
        var machine = SessionStateMachine()
        machine.start()
        XCTAssertEqual(machine.state, .idle)
    }

    func test_pttStart_movesToListening() {
        var machine = SessionStateMachine()
        machine.start()
        machine.pttStart()
        XCTAssertEqual(machine.state, .listening)
    }

    func test_pttStop_withAudio_movesToThinking() {
        var machine = SessionStateMachine()
        machine.start(); machine.pttStart()
        machine.pttStop(hasAudio: true)
        XCTAssertEqual(machine.state, .thinking)
    }

    func test_pttStop_withoutAudio_goesToDidntCatch() {
        var machine = SessionStateMachine()
        machine.start(); machine.pttStart()
        machine.pttStop(hasAudio: false)
        XCTAssertEqual(machine.state, .didntCatch)
        machine.didntCatchAcknowledged()
        XCTAssertEqual(machine.state, .idle)
    }

    func test_emptyTranscript_movesToDidntCatchThenIdle() {
        var machine = SessionStateMachine()
        machine.start(); machine.pttStart(); machine.pttStop(hasAudio: true)
        machine.transcribed(nil)
        XCTAssertEqual(machine.state, .didntCatch)
        machine.didntCatchAcknowledged()
        XCTAssertEqual(machine.state, .idle)
    }

    func test_nonEmptyTranscript_staysThinkingUntilSpeaking() {
        var machine = SessionStateMachine()
        machine.start(); machine.pttStart(); machine.pttStop(hasAudio: true)
        machine.transcribed("hello")
        XCTAssertEqual(machine.state, .thinking)
        machine.beginSpeaking()
        XCTAssertEqual(machine.state, .speaking)
        machine.finishSpeaking()
        XCTAssertEqual(machine.state, .idle)
    }

    func test_stopSpeak_bargeInFromSpeaking_returnsToIdle() {
        var machine = SessionStateMachine()
        machine.start(); machine.pttStart(); machine.pttStop(hasAudio: true)
        machine.transcribed("hello"); machine.beginSpeaking()
        machine.stopSpeak()
        XCTAssertEqual(machine.state, .idle)
    }

    func test_stopSpeak_bargeInFromThinking_returnsToIdle() {
        var machine = SessionStateMachine()
        machine.start(); machine.pttStart(); machine.pttStop(hasAudio: true)
        machine.transcribed("hello")
        machine.stopSpeak()
        XCTAssertEqual(machine.state, .idle)
    }

    func test_stopSpeak_fromIdle_isNoOp() {
        var machine = SessionStateMachine()
        machine.start()
        machine.stopSpeak()
        XCTAssertEqual(machine.state, .idle)
    }

    // Onboarding (NovaWebSocketServer) never routes its PTT turns through
    // this machine at all — it has its own explicit speaking/idle sends,
    // since the child/age questions aren't a normal conversation turn. That
    // means whatever this machine's state happened to be when onboarding
    // *started* (always .listening in practice, left over from the
    // .pttStart of the question being answered) is still sitting there,
    // untouched, when onboarding finishes. A real bug shipped from reading
    // that stale value directly instead of resetting it: the client was
    // sent "listening" as the final post-onboarding state and could never
    // start another recording (its own gating waits for "idle"). No matter
    // what the machine's state was left at, completing onboarding must
    // unconditionally land on .idle.
    func test_completeOnboarding_fromStaleListeningState_movesToIdle() {
        var machine = SessionStateMachine()
        machine.start()
        machine.pttStart()
        XCTAssertEqual(machine.state, .listening)
        machine.completeOnboarding()
        XCTAssertEqual(machine.state, .idle)
    }

    func test_completeOnboarding_fromAnyState_movesToIdle() {
        for setup: (inout SessionStateMachine) -> Void in [
            { $0 = SessionStateMachine() },
            { $0.start() },
            { $0.start(); $0.pttStart() },
            { $0.start(); $0.pttStart(); $0.pttStop(hasAudio: true) },
            { $0.start(); $0.pttStart(); $0.pttStop(hasAudio: true); $0.beginSpeaking() },
        ] {
            var machine = SessionStateMachine()
            setup(&machine)
            machine.completeOnboarding()
            XCTAssertEqual(machine.state, .idle)
        }
    }
}
