import AVFoundation

/// iOS counterpart to `_SystemTTSBackend` in `app/pipeline/tts.py` — the
/// "never hard-fail" TTS fallback the desktop app falls back to when
/// Piper/Kokoro aren't available. `AVSpeechSynthesizer` is iOS's built-in
/// on-device TTS (supports English and Japanese out of the box), exactly
/// filling the role `say` fills on macOS: zero extra dependencies, always
/// available. Piper and Kokoro (see ios/spikes/03-tts-piper and
/// 04-tts-kokoro-openjtalk) are both wired into the live reply flow now —
/// this engine is the fallback for when either's model/data files aren't
/// loaded yet, or synthesis throws, not the default path anymore.
///
/// `AVSpeechSynthesizer` gives no waveform access, same limitation the
/// Python `_SystemTTSBackend` docstring notes for `say` — so amplitude is
/// faked with the identical sine wave formula (`abs(sin(t * 8.0)) * 0.6`,
/// updated at the same ~20Hz), driving the avatar's lip-sync the same way.
@MainActor
final class SystemTTSEngine: NSObject, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private var amplitudeTimer: Timer?
    private var elapsed: Double = 0
    private var onAmplitude: ((Double) -> Void)?
    private var onFinish: (() -> Void)?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// Speaks `text` in `language`'s system voice, calling `onAmplitude` at
    /// ~20Hz while speaking (0.0 once finished) and `onFinish` when done.
    /// Empty/whitespace-only text is silently skipped, mirroring the Python
    /// `speak_streaming`'s early return.
    func speak(_ text: String, language: String, onAmplitude: @escaping (Double) -> Void, onFinish: @escaping () -> Void) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            onFinish()
            return
        }

        self.onAmplitude = onAmplitude
        self.onFinish = onFinish
        elapsed = 0

        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.voice = AVSpeechSynthesisVoice(language: language == "ja" ? "ja-JP" : "en-US")
        // Slightly slower than default, matching the Python backend's
        // 160wpm (vs. macOS `say`'s ~175wpm default) — easier for a learner.
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.9

        // `Timer.scheduledTimer`'s closure is `@Sendable` at the type level
        // (so it can't directly touch `elapsed`/`onAmplitude`, both
        // main-actor-isolated state, without the compiler flagging a
        // cross-actor data race) even though it only ever actually fires on
        // the main run loop here, since `speak()` itself runs on the main
        // actor. Hop back onto the actor explicitly instead, same pattern as
        // the `nonisolated` delegate callbacks below.
        amplitudeTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.elapsed += 0.05
                self.onAmplitude?(abs(sin(self.elapsed * 8.0)) * 0.6)
            }
        }
        synthesizer.speak(utterance)
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }

    private func finish() {
        amplitudeTimer?.invalidate()
        amplitudeTimer = nil
        onAmplitude?(0.0)
        onAmplitude = nil
        let callback = onFinish
        onFinish = nil
        callback?()
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finish() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finish() }
    }
}
