import Foundation

/// Minimal parser for numpy's `.npy` format (v1.0), just enough to read the
/// float32 arrays Kokoro's voices file bundles — shape + raw data, no
/// support for non-float32 dtypes or Fortran ordering (the real
/// `voices-v1.0.bin` uses neither, confirmed via Python's own `numpy.load`
/// before writing this).
public struct NpyArray {
    public let shape: [Int]
    public let data: [Float]

    public enum ParseError: Error {
        case invalidMagic
        case invalidHeader
        case unsupportedDType
    }

    public init(data raw: Data) throws {
        // Magic: \x93NUMPY, then 2 version bytes, then a 2-byte
        // little-endian header length (v1.0 format).
        guard raw.count >= 10, raw[raw.startIndex] == 0x93,
              raw[raw.startIndex.advanced(by: 1)..<raw.startIndex.advanced(by: 6)].elementsEqual(Array("NUMPY".utf8))
        else {
            throw ParseError.invalidMagic
        }
        let headerLenBytes = raw[raw.startIndex.advanced(by: 8)..<raw.startIndex.advanced(by: 10)]
        let headerLen = Int(headerLenBytes[headerLenBytes.startIndex]) | (Int(headerLenBytes[headerLenBytes.startIndex + 1]) << 8)
        let headerStart = raw.startIndex.advanced(by: 10)
        let headerEnd = headerStart.advanced(by: headerLen)
        guard headerEnd <= raw.endIndex, let headerString = String(data: raw[headerStart..<headerEnd], encoding: .ascii)
        else {
            throw ParseError.invalidHeader
        }

        guard headerString.contains("'descr': '<f4'") else { throw ParseError.unsupportedDType }
        guard let shapeRange = headerString.range(of: "'shape': ("),
              let closeParen = headerString.range(of: ")", range: shapeRange.upperBound..<headerString.endIndex)
        else {
            throw ParseError.invalidHeader
        }
        let shapeContent = headerString[shapeRange.upperBound..<closeParen.lowerBound]
        let shape = shapeContent.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }

        let payload = raw[headerEnd...]
        let floatCount = payload.count / MemoryLayout<Float>.size
        var floats = [Float](repeating: 0, count: floatCount)
        floats.withUnsafeMutableBytes { dest in
            _ = payload.copyBytes(to: dest, count: dest.count)
        }
        // numpy stores little-endian float32; the copy above is already
        // little-endian on this platform (all supported Apple hardware is),
        // so no byte-swap is needed.

        self.shape = shape
        self.data = floats
    }
}
