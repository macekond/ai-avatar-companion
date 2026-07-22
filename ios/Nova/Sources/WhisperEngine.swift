import Foundation
import whisper

/// Wraps whisper.cpp (Phase 0 Spike 1 / Phase 3 of the iOS port plan) —
/// replaces `app/pipeline/stt.py`'s faster-whisper model. Model loading and
/// inference both block the calling thread (mirrors whisper.cpp's own C API,
/// which is synchronous), so callers must dispatch off the main actor.
// whisper_full is a blocking C call meant to run off the main actor; @unchecked
// because OpaquePointer isn't Sendable-checked. Safe as long as callers don't
// invoke transcribe() concurrently on the same instance — true today since
// NovaWebSocketServer only ever has one active WKWebView client at a time.
final class WhisperEngine: @unchecked Sendable {
    enum EngineError: Error {
        case modelLoadFailed
        case transcriptionFailed
    }

    private let context: OpaquePointer

    /// `modelPath` is a ggml-format `.bin` file (e.g. `ggml-small.bin`) —
    /// not bundled (Phase 9: on-demand download, same as the desktop app's
    /// own first-run model fetch), so this must be resolved by the caller.
    init(modelPath: String) throws {
        var params = whisper_context_default_params()
        params.use_gpu = true   // Metal backend, per Spike 1's recommendation
        guard let ctx = whisper_init_from_file_with_params(modelPath, params) else {
            throw EngineError.modelLoadFailed
        }
        self.context = ctx
    }

    deinit {
        whisper_free(context)
    }

    /// Transcribe 16kHz mono float32 samples — port of `STTPipeline.transcribe`
    /// in app/pipeline/stt.py, including its confidence-filter gate.
    /// `language` is an ISO code ("en"/"ja") or nil for auto-detect.
    func transcribe(samples: [Float], language: String?) throws -> String {
        func runFull(languagePointer: UnsafePointer<CChar>?) throws -> String {
            var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
            params.print_progress = false
            params.print_realtime = false
            params.print_special = false
            // Matches config.yaml's models.stt.no_speech_threshold default.
            params.no_speech_thold = 0.6
            params.language = languagePointer

            let status = samples.withUnsafeBufferPointer { buffer in
                whisper_full(context, params, buffer.baseAddress, Int32(buffer.count))
            }
            guard status == 0 else { throw EngineError.transcriptionFailed }

            let segmentCount = whisper_full_n_segments(context)
            var pieces: [String] = []
            for i in 0..<segmentCount {
                // avg_logprob < -1.0 drops a segment as garbled — mirrors
                // app/pipeline/stt.py's confidence floor.
                guard whisper_full_get_segment_no_speech_prob(context, i) < 0.6 else { continue }
                if let text = whisper_full_get_segment_text(context, i) {
                    pieces.append(String(cString: text))
                }
            }
            return pieces.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        }

        if let language {
            return try language.withCString { try runFull(languagePointer: $0) }
        }
        return try runFull(languagePointer: nil)
    }
}
