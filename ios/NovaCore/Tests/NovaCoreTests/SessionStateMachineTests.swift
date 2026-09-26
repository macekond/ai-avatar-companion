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

    func test_pttStop_withoutAudio_returnsToIdle() {
        var machine = SessionStateMachine()
        machine.start(); machine.pttStart()
        machine.pttStop(hasAudio: false)
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
}
