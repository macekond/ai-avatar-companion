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

    /// Onboarding (name + age) never routes its own PTT turns through this
    /// machine — it has its own explicit speaking/idle sends, since those
    /// two questions aren't a normal conversation turn. That means whatever
    /// state this machine was left at when onboarding began (in practice
    /// always `.listening`, from the `.pttStart` of the question that
    /// triggered it) is still sitting here, untouched, once onboarding
    /// finishes — unconditionally reset to `.idle` rather than trusting
    /// (and forwarding to the client) whatever stale value happens to be
    /// here. A real bug shipped from skipping this: the client was sent
    /// "listening" as onboarding's final state and could never start
    /// another recording, since its own gating waits for "idle".
    public mutating func completeOnboarding() {
        state = .idle
    }

    public mutating func pttStart() {
        state = .listening
    }

    /// `hasAudio` reflects whether the mic captured anything above the
    /// minimum-duration floor (`MIN_DURATION_S` in `app/pipeline/stt.py`) —
    /// no audio means there's nothing to transcribe, so this is the same
    /// "didn't catch that" path as an empty transcript, not a silent skip to
    /// idle (that used to leave the talk button dead: idle is only reached
    /// again via `didntCatchAcknowledged()`).
    public mutating func pttStop(hasAudio: Bool) {
        state = hasAudio ? .thinking : .didntCatch
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
