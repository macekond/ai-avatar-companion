import AVFoundation
import NovaCore

/// Session-scoped microphone capture — port of `_MicRecorder` in
/// `app/server.py` (lines 206-267). The Python original keeps one
/// `sounddevice.InputStream` open for the whole session because reopening a
/// fresh CoreAudio stream per turn was found to wedge the device after a few
/// minutes; the same risk applies to `AVAudioEngine` on iOS, so this mirrors
/// that design: `start()` is called once per session, and PTT start/stop
/// only gate whether incoming buffers are accumulated, never stop/restart
/// the engine itself.
@MainActor
final class MicRecorder {
    private let engine = AVAudioEngine()
    private var isCapturing = false
    private var capturedSampleCount = 0
    private var capturedSamples: [Float] = []

    /// Starts the persistent tap for the session. Safe to call once; PTT
    /// start/stop below control capture, not this.
    func start() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: [])
        try session.setActive(true)

        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(STTConstants.sampleRate),
            channels: 1,
            interleaved: false
        )!
        let converter = AVAudioConverter(from: inputFormat, to: targetFormat)

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            guard let self, self.isCapturing, let converter else { return }
            let outputCapacity = AVAudioFrameCount(
                Double(buffer.frameLength) * targetFormat.sampleRate / inputFormat.sampleRate
            ) + 16
            guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputCapacity) else { return }

            var error: NSError?
            converter.convert(to: converted, error: &error) { _, inputStatus in
                inputStatus.pointee = .haveData
                return buffer
            }
            guard error == nil, let channelData = converted.floatChannelData else { return }

            let frameLength = Int(converted.frameLength)
            Task { @MainActor in
                self.capturedSamples.append(contentsOf: UnsafeBufferPointer(start: channelData[0], count: frameLength))
                self.capturedSampleCount += frameLength
            }
        }

        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    func pttStart() {
        capturedSamples.removeAll(keepingCapacity: true)
        capturedSampleCount = 0
        isCapturing = true
    }

    /// Ends capture and returns whether enough audio was captured to bother
    /// transcribing (`STTConstants.hasEnoughAudio`) plus the raw samples —
    /// mirrors the Python `_MicRecorder.stop()` -> STT `MIN_DURATION_S` gate.
    func pttStop() -> (hasAudio: Bool, samples: [Float]) {
        isCapturing = false
        let samples = capturedSamples
        return (STTConstants.hasEnoughAudio(sampleCount: capturedSampleCount), samples)
    }
}
