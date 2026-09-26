import Foundation
import NovaCore

/// Wraps onnxruntime's C API directly (no ObjC++ needed — plain C has no
/// name-mangling issues, unlike llama.cpp/open_jtalk's C++ APIs) to run
/// Kokoro-82M inference. Port of kokoro_onnx's `_create_audio`: phonemes are
/// tokenized via NovaCore's `KokoroTokenizer` (already TDD'd, no espeak-ng
/// needed for the `is_phonemes=true` path this app uses — see
/// ios/spikes/03-tts-piper/README.md), then run through the ONNX session
/// with the same `tokens`/`style`/`speed` inputs.
///
/// Model/voices files are not bundled (Phase 9: on-demand download).
final class KokoroEngine: @unchecked Sendable {
    enum EngineError: Error {
        case apiUnavailable
        case envCreationFailed
        case sessionCreationFailed
        case runFailed(String)
        case invalidOutput
    }

    static let sampleRate = 24_000

    private let api: OrtApi
    private let env: OpaquePointer
    private let session: OpaquePointer
    private let memoryInfo: OpaquePointer

    /// `style` passed to `synthesize` is the voice's per-length style vector
    /// (`voices[name][tokenCount]` in the Python original) already sliced by
    /// the caller — loading the actual `.npz`/`.bin` voices file's binary
    /// format is separate, not-yet-done work (this engine's inference core
    /// can be verified once a model file exists independent of that).
    init(modelPath: String) throws {
        guard let apiBasePtr = OrtGetApiBase() else { throw EngineError.apiUnavailable }
        let apiBase = apiBasePtr.pointee
        guard let getApi = apiBase.GetApi, let apiPtr = getApi(UInt32(ORT_API_VERSION)) else {
            throw EngineError.apiUnavailable
        }
        // Local shadow, not `self.api`: closures below run before every
        // stored property is initialized, and Swift disallows capturing
        // `self` in a closure during init until that point, even to read an
        // already-assigned property.
        let api = apiPtr.pointee

        var envPtr: OpaquePointer?
        try Self.check(api.CreateEnv(ORT_LOGGING_LEVEL_WARNING, "nova-kokoro", &envPtr), api: api)
        guard let env = envPtr else { throw EngineError.envCreationFailed }

        var sessionOptions: OpaquePointer?
        try Self.check(api.CreateSessionOptions(&sessionOptions), api: api)
        defer { if let sessionOptions { api.ReleaseSessionOptions(sessionOptions) } }

        var sessionPtr: OpaquePointer?
        try Self.check(
            modelPath.withCString { api.CreateSession(env, $0, sessionOptions, &sessionPtr) },
            api: api
        )
        guard let session = sessionPtr else { throw EngineError.sessionCreationFailed }

        var memInfo: OpaquePointer?
        try Self.check(api.CreateCpuMemoryInfo(OrtArenaAllocator, OrtMemTypeDefault, &memInfo), api: api)
        guard let memInfo else { throw EngineError.envCreationFailed }

        self.api = api
        self.env = env
        self.session = session
        self.memoryInfo = memInfo
    }

    deinit {
        api.ReleaseMemoryInfo(memoryInfo)
        api.ReleaseSession(session)
        api.ReleaseEnv(env)
    }

    /// Runs inference for already-phonemized text. Returns raw float32
    /// samples at `KokoroEngine.sampleRate`.
    func synthesize(phonemes: String, style: [Float], speed: Float = 1.0) throws -> [Float] {
        var tokens = KokoroTokenizer.wrapWithPadding(KokoroTokenizer.tokenize(phonemes)).map { Int64($0) }
        var styleCopy = style
        var speedCopy: [Float] = [speed]

        let tokensShape: [Int64] = [1, Int64(tokens.count)]
        let styleShape: [Int64] = [1, Int64(style.count)]
        let speedShape: [Int64] = [1]

        var tokensValue, styleValue, speedValue: OpaquePointer?
        try tokens.withUnsafeMutableBufferPointer { buffer in
            try Self.check(api.CreateTensorWithDataAsOrtValue(
                memoryInfo, buffer.baseAddress, buffer.count * MemoryLayout<Int64>.stride,
                tokensShape, tokensShape.count, ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64, &tokensValue
            ), api: api)
        }
        try styleCopy.withUnsafeMutableBufferPointer { buffer in
            try Self.check(api.CreateTensorWithDataAsOrtValue(
                memoryInfo, buffer.baseAddress, buffer.count * MemoryLayout<Float>.stride,
                styleShape, styleShape.count, ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT, &styleValue
            ), api: api)
        }
        try speedCopy.withUnsafeMutableBufferPointer { buffer in
            try Self.check(api.CreateTensorWithDataAsOrtValue(
                memoryInfo, buffer.baseAddress, buffer.count * MemoryLayout<Float>.stride,
                speedShape, speedShape.count, ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT, &speedValue
            ), api: api)
        }
        defer {
            for v in [tokensValue, styleValue, speedValue] where v != nil { api.ReleaseValue(v!) }
        }

        let tokensNamePtr = strdup("tokens")
        let styleNamePtr = strdup("style")
        let speedNamePtr = strdup("speed")
        let outputNamePtr = strdup("audio")
        defer { [tokensNamePtr, styleNamePtr, speedNamePtr, outputNamePtr].forEach { free(UnsafeMutableRawPointer($0)) } }

        var inputNames: [UnsafePointer<CChar>?] = [
            UnsafePointer(tokensNamePtr), UnsafePointer(styleNamePtr), UnsafePointer(speedNamePtr),
        ]
        var inputValues: [OpaquePointer?] = [tokensValue, styleValue, speedValue]
        var outputNames: [UnsafePointer<CChar>?] = [UnsafePointer(outputNamePtr)]
        var outputValues: [OpaquePointer?] = [nil]

        try Self.check(
            api.Run(session, nil, &inputNames, &inputValues, 3, &outputNames, 1, &outputValues),
            api: api
        )
        guard let output = outputValues[0] else { throw EngineError.invalidOutput }
        defer { api.ReleaseValue(output) }

        var dataPtr: UnsafeMutableRawPointer?
        try Self.check(api.GetTensorMutableData(output, &dataPtr), api: api)
        guard let dataPtr else { throw EngineError.invalidOutput }

        var typeInfo: OpaquePointer?
        try Self.check(api.GetTensorTypeAndShape(output, &typeInfo), api: api)
        defer { if let typeInfo { api.ReleaseTensorTypeAndShapeInfo(typeInfo) } }
        var elementCount: Int = 0
        try Self.check(api.GetTensorShapeElementCount(typeInfo, &elementCount), api: api)

        let floatPtr = dataPtr.bindMemory(to: Float.self, capacity: elementCount)
        return Array(UnsafeBufferPointer(start: floatPtr, count: elementCount))
    }

    private static func check(_ status: OpaquePointer?, api: OrtApi) throws {
        guard let status else { return }
        let message = api.GetErrorMessage(status).map { String(cString: $0) } ?? "unknown error"
        api.ReleaseStatus(status)
        throw EngineError.runFailed(message)
    }
}
