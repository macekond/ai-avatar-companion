import AVFoundation
import NovaCore
import os

/// Session-scoped microphone capture — port of `_MicRecorder` in
/// `app/server.py` (lines 206-267). The Python original keeps one
/// `sounddevice.InputStream` open for the whole session because reopening a
/// fresh CoreAudio stream per turn was found to wedge the device after a few
/// minutes; the same risk applies to `AVAudioEngine` on iOS, so this mirrors
/// that design: `start()` is called once per session, and PTT start/stop
/// only gate whether incoming buffers are accumulated, never stop/restart
/// the engine itself — except when iOS itself has stopped the engine (see
/// `restartCapture()`), which no amount of gating can prevent.
@MainActor
final class MicRecorder {
    private let engine = AVAudioEngine()

    private struct CaptureState {
        var isCapturing = false
        var samples: [Float] = []
        var sampleCount = 0
    }
    /// Guards `CaptureState`. `@MainActor` on this class does NOT make that
    /// state safe to touch from the tap closure below: `AVAudioEngine`'s tap
    /// runs on CoreAudio's own real-time thread regardless of this class's
    /// actor annotation, so reading/writing `isCapturing`/`samples` there
    /// without synchronization is a genuine data race with `pttStart()`/
    /// `pttStop()` on the main actor — not just a style concern, an actual
    /// one this compiled and ran without ever surfacing since Swift's
    /// non-strict-concurrency mode doesn't catch it at compile time.
    private let stateLock = OSAllocatedUnfairLock(initialState: CaptureState())

    /// The STT-side format every tap converts into — fixed for the process
    /// lifetime, unlike the input node's own format (see `installTap`).
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: Double(STTConstants.sampleRate),
        channels: 1,
        interleaved: false
    )!

    private var configChangeObserver: NSObjectProtocol?
    private var interruptionObserver: NSObjectProtocol?

    /// Starts the persistent tap for the session. Safe to call once; PTT
    /// start/stop below control capture, not this.
    func start() throws {
        try activateSessionAndInstallTap()
        observeAudioLifecycleNotifications()
    }

    private func activateSessionAndInstallTap() throws {
        let session = AVAudioSession.sharedInstance()
        // `.record` is capture-only and silently drops every TTS reply played
        // through the app's other `AVAudioEngine`s (KokoroPlayer, PiperEngine,
        // SystemTTSEngine) since they never touch this shared session
        // themselves — they just play into whatever category this call last
        // established. `.playAndRecord` is required for both directions to
        // coexist; `.defaultToSpeaker` keeps replies on the speaker instead of
        // the earpiece, which is `.playAndRecord`'s default output route.
        //
        // Mode is `.default`, not `.measurement`: `.measurement` is meant for
        // calibration/analysis and specifically disables the normal output
        // loudness processing iOS applies to spoken playback — every TTS
        // reply shares this same session (see above), so every reply played
        // noticeably quieter than it should, worst on the very first line
        // (reported: "the voice is too quiet at the beginning"). `.default`
        // keeps normal output loudness; whisper.cpp's STT accuracy doesn't
        // depend on measurement-grade flat-response input, so there's no
        // real tradeoff on the capture side.
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
        try session.setActive(true)

        installTap()

        engine.prepare()
        try engine.start()
    }

    /// (Re)installs the tap using the input node's CURRENT format — shared by
    /// `start()` and `restartCapture()`. Rebuilding the converter each time
    /// matters: iOS can hand the input node a different native format after a
    /// hardware configuration change (e.g. a different sample rate once
    /// another `AVAudioEngine` — Kokoro/Piper playback — starts under the
    /// same `.playAndRecord` session), and a converter built from the old
    /// format silently produces garbage or throws for every buffer after
    /// that.
    private func installTap() {
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        let targetFormat = self.targetFormat
        let converter = AVAudioConverter(from: inputFormat, to: targetFormat)

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            guard let self, let converter else { return }
            guard self.stateLock.withLock({ $0.isCapturing }) else { return }

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
            self.stateLock.withLock { state in
                state.samples.append(contentsOf: UnsafeBufferPointer(start: channelData[0], count: frameLength))
                state.sampleCount += frameLength
            }
        }
    }

    /// iOS stops this engine outright on a hardware configuration change
    /// (`AVAudioEngineConfigurationChange` — plausibly triggered here by
    /// Kokoro/Piper's own playback engines starting at a different sample
    /// rate under the same `.playAndRecord` session) and on an audio session
    /// interruption (a phone call, Siri, another app). Either one otherwise
    /// leaves every subsequent PTT capturing zero frames silently, since
    /// `isCapturing`/`pttStart`/`pttStop` all still "work" — there's just no
    /// running engine feeding the tap anymore.
    private func observeAudioLifecycleNotifications() {
        guard configChangeObserver == nil else { return }
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            Task { @MainActor in
                self?.restartCapture(reason: "config_change")
            }
        }
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: nil
        ) { [weak self] notification in
            guard let info = notification.userInfo,
                  let rawType = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: rawType) == .ended
            else { return }
            Task { @MainActor in
                self?.restartCapture(reason: "interruption_ended")
            }
        }
    }

    /// Reactivates the session and rebuilds the tap from scratch — the input
    /// node's format may have changed, so the converter must be rebuilt too,
    /// not just re-attached (see `installTap`).
    private func restartCapture(reason: String) {
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            installTap()
            engine.prepare()
            try engine.start()
            Diagnostics.log("mic_restarted", ["reason": reason])
        } catch {
            Diagnostics.log("mic_restart_failed", ["reason": reason])
        }
    }

    func stop() {
        if let configChangeObserver { NotificationCenter.default.removeObserver(configChangeObserver) }
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
        configChangeObserver = nil
        interruptionObserver = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    func pttStart() {
        // Defense in depth: the notification handlers above are the primary
        // fix, but if the engine is somehow still stopped when a PTT press
        // arrives, restart it here rather than silently capturing nothing.
        if !engine.isRunning {
            restartCapture(reason: "ptt_start_not_running")
        }
        stateLock.withLock { state in
            state.samples.removeAll(keepingCapacity: true)
            state.sampleCount = 0
            state.isCapturing = true
        }
    }

    /// Ends capture and returns whether enough audio was captured to bother
    /// transcribing (`STTConstants.hasEnoughAudio`) plus the raw samples —
    /// mirrors the Python `_MicRecorder.stop()` -> STT `MIN_DURATION_S` gate.
    func pttStop() -> (hasAudio: Bool, samples: [Float]) {
        let (count, samples) = stateLock.withLock { state -> (Int, [Float]) in
            state.isCapturing = false
            return (state.sampleCount, state.samples)
        }
        return (STTConstants.hasEnoughAudio(sampleCount: count), samples)
    }
}
