import Foundation

/// The five session states broadcast to the UI as `{"type":"state","state":...}`
/// — port of the state machine driven by `app/server.py`'s main session loop.
public enum SessionState: String, Codable, Equatable {
    case awaitingStart = "awaiting_start"
    case idle
    case listening
    case thinking
    case speaking
    case didntCatch = "didnt_catch"
}

/// Port of the PTT-driven session state machine in `app/server.py`'s
/// `_session` loop: listening → (no audio → idle) / (audio → thinking) →
/// (empty transcript → didnt_catch → idle) / (transcript → speaking → idle).
/// `stopSpeak()` is the barge-in path, valid from `thinking` or `speaking`.
public struct SessionStateMachine {
    public private(set) var state: SessionState = .awaitingStart

    public init() {}

    /// User tapped "Say hi to Nova!" — the very first interaction.
    public mutating func start() {
        state = .idle
    }

    public mutating func pttStart() {
        state = .listening
    }

    /// `hasAudio` reflects whether the mic captured anything above the
    /// minimum-duration floor (`MIN_DURATION_S` in `app/pipeline/stt.py`) —
    /// no audio means there's nothing to transcribe, so skip straight to idle.
    public mutating func pttStop(hasAudio: Bool) {
        state = hasAudio ? .thinking : .idle
    }

    /// `nil`/empty means STT produced nothing usable (dropped by VAD or the
    /// confidence-filter thresholds) — mirrors the "didn't catch that" path.
    public mutating func transcribed(_ text: String?) {
        if text == nil || text!.isEmpty {
            state = .didntCatch
        }
        // A non-empty transcript stays in `.thinking` until beginSpeaking()
        // (the LLM is still generating).
    }

    /// After the UI has shown "didn't catch that" briefly.
    public mutating func didntCatchAcknowledged() {
        guard state == .didntCatch else { return }
        state = .idle
    }

    public mutating func beginSpeaking() {
        state = .speaking
    }

    public mutating func finishSpeaking() {
        state = .idle
    }

    /// Barge-in: the child interrupts while Nova is thinking or speaking.
    /// A no-op from any other state.
    public mutating func stopSpeak() {
        guard state == .thinking || state == .speaking else { return }
        state = .idle
    }
}
