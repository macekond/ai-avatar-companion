import Foundation
import NovaCore

/// Wraps onnxruntime's C API directly (same reasoning as `KokoroEngine`) to
/// run a Piper VITS-family voice model. Port of piper-tts's
/// `phoneme_ids_to_audio`: `input`/`input_lengths`/`scales` ONNX tensors in,
/// a single `audio` output tensor out.
final class PiperEngine: @unchecked Sendable {
    enum EngineError: Error {
        case apiUnavailable
        case envCreationFailed
        case sessionCreationFailed
        case runFailed(String)
        case invalidOutput
    }

    private let api: OrtApi
    private let env: OpaquePointer
    private let session: OpaquePointer
    private let memoryInfo: OpaquePointer

    init(modelPath: String) throws {
        guard let apiBasePtr = OrtGetApiBase() else { throw EngineError.apiUnavailable }
        let apiBase = apiBasePtr.pointee
        guard let getApi = apiBase.GetApi, let apiPtr = getApi(UInt32(ORT_API_VERSION)) else {
            throw EngineError.apiUnavailable
        }
        let api = apiPtr.pointee

        var envPtr: OpaquePointer?
        try Self.check(api.CreateEnv(ORT_LOGGING_LEVEL_WARNING, "nova-piper", &envPtr), api: api)
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

    /// Runs inference for already-computed phoneme ids (see
    /// `PiperPhonemeIds.phonemesToIds`). Returns raw float32 samples at the
    /// voice config's sample rate (typically 22050Hz), unnormalized.
    func synthesize(phonemeIds: [Int], config: PiperConfig, speakerId: Int? = nil) throws -> [Float] {
        var ids = phonemeIds.map { Int64($0) }
        var lengths: [Int64] = [Int64(ids.count)]
        var scales: [Float] = [config.noiseScale, config.lengthScale, config.noiseWScale]
        var sid: [Int64] = [Int64(speakerId ?? 0)]

        let idsShape: [Int64] = [1, Int64(ids.count)]
        let lengthsShape: [Int64] = [1]
        let scalesShape: [Int64] = [3]
        let sidShape: [Int64] = [1]

        var idsValue, lengthsValue, scalesValue, sidValue: OpaquePointer?
        try ids.withUnsafeMutableBufferPointer { buffer in
            try Self.check(api.CreateTensorWithDataAsOrtValue(
                memoryInfo, buffer.baseAddress, buffer.count * MemoryLayout<Int64>.stride,
                idsShape, idsShape.count, ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64, &idsValue
            ), api: api)
        }
        try lengths.withUnsafeMutableBufferPointer { buffer in
            try Self.check(api.CreateTensorWithDataAsOrtValue(
                memoryInfo, buffer.baseAddress, buffer.count * MemoryLayout<Int64>.stride,
                lengthsShape, lengthsShape.count, ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64, &lengthsValue
            ), api: api)
        }
        try scales.withUnsafeMutableBufferPointer { buffer in
            try Self.check(api.CreateTensorWithDataAsOrtValue(
                memoryInfo, buffer.baseAddress, buffer.count * MemoryLayout<Float>.stride,
                scalesShape, scalesShape.count, ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT, &scalesValue
            ), api: api)
        }

        let usesSpeakerId = config.numSpeakers > 1
        if usesSpeakerId {
            try sid.withUnsafeMutableBufferPointer { buffer in
                try Self.check(api.CreateTensorWithDataAsOrtValue(
                    memoryInfo, buffer.baseAddress, buffer.count * MemoryLayout<Int64>.stride,
                    sidShape, sidShape.count, ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64, &sidValue
                ), api: api)
            }
        }
        defer {
            for v in [idsValue, lengthsValue, scalesValue, sidValue] where v != nil { api.ReleaseValue(v!) }
        }

        let inputNamePtr = strdup("input")
        let lengthsNamePtr = strdup("input_lengths")
        let scalesNamePtr = strdup("scales")
        let sidNamePtr = strdup("sid")
        let outputNamePtr = strdup("output")
        defer { [inputNamePtr, lengthsNamePtr, scalesNamePtr, sidNamePtr, outputNamePtr].forEach { free(UnsafeMutableRawPointer($0)) } }

        var inputNames: [UnsafePointer<CChar>?] = [UnsafePointer(inputNamePtr), UnsafePointer(lengthsNamePtr), UnsafePointer(scalesNamePtr)]
        var inputValues: [OpaquePointer?] = [idsValue, lengthsValue, scalesValue]
        if usesSpeakerId {
            inputNames.append(UnsafePointer(sidNamePtr))
            inputValues.append(sidValue)
        }
        var outputNames: [UnsafePointer<CChar>?] = [UnsafePointer(outputNamePtr)]
        var outputValues: [OpaquePointer?] = [nil]

        try Self.check(
            api.Run(session, nil, &inputNames, &inputValues, inputNames.count, &outputNames, 1, &outputValues),
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
