import AVFoundation

/// Plays a fully-synthesized Kokoro float32 buffer through `AVAudioEngine`
/// and pulses `onAmplitude` at ~20Hz — direct port of `_play_float_audio` in
/// `app/pipeline/tts.py`, which Piper and Kokoro both share on desktop for
/// identical lip-sync behavior across backends.
///
/// Unlike the Python original (a `sounddevice` output-stream callback that
/// naturally fires once per hardware block), this schedules the whole buffer
/// on an `AVAudioPlayerNode` up front and drives the amplitude callback off
/// a wall-clock `Timer` in lockstep with elapsed playback time — accurate
/// because both playback and the timer advance at real-time rate against
/// the same fixed sample rate.
@MainActor
final class KokoroPlayer {
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private var amplitudeTimer: Timer?
    private var onAmplitude: ((Double) -> Void)?
    private var onFinish: (() -> Void)?
    private var samples: [Float] = []
    private var blockSize: Int = 1
    private var position: Int = 0
    private var finished = false

    init() {
        engine.attach(playerNode)
    }

    /// Plays `samples` (mono float32, `sampleRate` Hz), calling `onAmplitude`
    /// with RMS energy (`min(1.0, rms * 5.0)`, matching the desktop scaling)
    /// at ~20Hz, then `onAmplitude(0.0)` and `onFinish()` once done.
    func play(samples: [Float], sampleRate: Int, onAmplitude: @escaping (Double) -> Void, onFinish: @escaping () -> Void) {
        stop()
        guard !samples.isEmpty else {
            onAmplitude(0.0)
            onFinish()
            return
        }

        self.samples = samples
        self.blockSize = max(256, sampleRate / 20)
        self.position = 0
        self.finished = false
        self.onAmplitude = onAmplitude
        self.onFinish = onFinish

        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate), channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))
        else {
            finish()
            return
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            buffer.floatChannelData?[0].update(from: src.baseAddress!, count: samples.count)
        }

        engine.disconnectNodeOutput(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: format)
        do {
            if !engine.isRunning { try engine.start() }
        } catch {
            finish()
            return
        }

        playerNode.scheduleBuffer(buffer, completionHandler: nil)
        playerNode.play()

        amplitudeTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func stop() {
        guard !finished else { return }
        playerNode.stop()
        finish()
    }

    private func tick() {
        guard !finished else { return }
        let end = min(position + blockSize, samples.count)
        guard position < end else {
            finish()
            return
        }
        let chunk = samples[position..<end]
        let meanSquare = chunk.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(chunk.count)
        let rms = meanSquare.squareRoot()
        onAmplitude?(min(1.0, rms * 5.0))
        position = end
        if position >= samples.count {
            finish()
        }
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        amplitudeTimer?.invalidate()
        amplitudeTimer = nil
        onAmplitude?(0.0)
        onAmplitude = nil
        let callback = onFinish
        onFinish = nil
        callback?()
    }
}
