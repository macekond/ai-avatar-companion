import Foundation

/// Tuned constants from `app/pipeline/stt.py` — copied verbatim, not
/// re-derived (see that module's `SAMPLE_RATE`/`MIN_DURATION_S`).
public enum STTConstants {
    /// Whisper requires 16 kHz mono input.
    public static let sampleRate = 16_000
    /// Recordings shorter than this are silently discarded — nothing to
    /// transcribe, so skip straight back to idle rather than invoking STT.
    public static let minDurationS = 0.3

    /// Port of `len(audio) < int(SAMPLE_RATE * MIN_DURATION_S)` — true means
    /// there's enough audio to bother transcribing.
    public static func hasEnoughAudio(sampleCount: Int) -> Bool {
        sampleCount >= Int(Double(sampleRate) * minDurationS)
    }
}
