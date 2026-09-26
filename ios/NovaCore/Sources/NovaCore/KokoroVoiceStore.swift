import Foundation

/// Loads Kokoro's voices archive (`voices-v1.0.bin` — a stored/uncompressed
/// ZIP of per-voice `.npy` files, each shaped `(maxLength, 1, styleWidth)`)
/// and looks up the per-token-count style vector — port of
/// `voice[len(tokens)]` indexing in kokoro_onnx's `_create_audio`.
public struct KokoroVoiceStore {
    public enum StoreError: Error {
        case voiceNotFound
        case indexOutOfRange
    }

    private let arrays: [String: NpyArray]

    public init(data: Data) throws {
        let entries = try readStoredZipEntries(data)
        var parsed: [String: NpyArray] = [:]
        for (name, entryData) in entries where name.hasSuffix(".npy") {
            let voiceName = String(name.dropLast(".npy".count))
            parsed[voiceName] = try NpyArray(data: entryData)
        }
        self.arrays = parsed
    }

    /// The style vector for `voice` at `tokenCount` — shape `[styleWidth]`,
    /// matching what `KokoroEngine.synthesize`'s `style` parameter expects.
    public func styleVector(voice: String, tokenCount: Int) throws -> [Float] {
        guard let array = arrays[voice] else { throw StoreError.voiceNotFound }
        guard array.shape.count == 3 else { throw StoreError.indexOutOfRange }
        let (maxLength, dim1, styleWidth) = (array.shape[0], array.shape[1], array.shape[2])
        guard tokenCount >= 0, tokenCount < maxLength else { throw StoreError.indexOutOfRange }
        let sliceSize = dim1 * styleWidth
        let start = tokenCount * sliceSize
        return Array(array.data[start..<(start + sliceSize)])
    }
}
