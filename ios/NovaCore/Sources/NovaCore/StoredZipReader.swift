import Foundation

/// Minimal reader for STORED (uncompressed) ZIP archives — Kokoro's voices
/// file (`voices-v1.0.bin`) is a numpy `.npz`, which is a ZIP archive of
/// `.npy` files; confirmed via its local file header that entries use
/// compression method 0 (stored), so no DEFLATE decompression is needed.
/// Scans local file headers sequentially rather than parsing the central
/// directory — sufficient for reading every entry.
///
/// The real file uses **ZIP64** (confirmed against it directly, not just a
/// hand-built fixture): its 32-bit compressed/uncompressed size fields are
/// both `0xFFFFFFFF` sentinels, with the real 64-bit sizes carried in a
/// ZIP64 extended-information extra field (tag `0x0001`) instead. A reader
/// that only trusts the 32-bit fields throws on the first entry.
public enum StoredZipError: Error {
    case truncated
    case unsupportedCompression
    case missingZip64Size
}

public func readStoredZipEntries(_ data: Data) throws -> [String: Data] {
    var entries: [String: Data] = [:]
    var offset = data.startIndex
    let zip64SentinelSize = 0xFFFF_FFFF

    while offset < data.endIndex {
        guard data.distance(from: offset, to: data.endIndex) >= 30 else { break }
        let signature = data[offset..<offset.advanced(by: 4)]
        guard signature.elementsEqual([0x50, 0x4B, 0x03, 0x04]) else { break }  // not a local file header — stop (hit central directory)

        func u16(_ at: Data.Index) -> Int {
            Int(data[at]) | (Int(data[at.advanced(by: 1)]) << 8)
        }
        func u32(_ at: Data.Index) -> Int {
            (0..<4).reduce(0) { acc, i in acc | (Int(data[at.advanced(by: i)]) << (8 * i)) }
        }
        func u64(_ at: Data.Index) -> Int {
            (0..<8).reduce(0) { acc, i in acc | (Int(data[at.advanced(by: i)]) << (8 * i)) }
        }

        let compressionMethod = u16(offset.advanced(by: 8))
        guard compressionMethod == 0 else { throw StoredZipError.unsupportedCompression }
        let compressedSize32 = u32(offset.advanced(by: 18))
        let nameLength = u16(offset.advanced(by: 26))
        let extraLength = u16(offset.advanced(by: 28))

        let nameStart = offset.advanced(by: 30)
        let nameEnd = nameStart.advanced(by: nameLength)
        guard nameEnd <= data.endIndex, let name = String(data: data[nameStart..<nameEnd], encoding: .utf8) else {
            throw StoredZipError.truncated
        }

        let extraStart = nameEnd
        let extraEnd = extraStart.advanced(by: extraLength)
        guard extraEnd <= data.endIndex else { throw StoredZipError.truncated }

        var compressedSize = compressedSize32
        if compressedSize32 == zip64SentinelSize {
            // Scan the extra field for tag 0x0001 (Zip64 extended info);
            // its data is [uncompressedSize: u64][compressedSize: u64] in
            // that order, present only for fields that were 0xFFFFFFFF above.
            var cursor = extraStart
            var found = false
            while data.distance(from: cursor, to: extraEnd) >= 4 {
                let tag = u16(cursor)
                let size = u16(cursor.advanced(by: 2))
                let fieldStart = cursor.advanced(by: 4)
                if tag == 0x0001, size >= 16 {
                    compressedSize = u64(fieldStart.advanced(by: 8))
                    found = true
                    break
                }
                cursor = fieldStart.advanced(by: size)
            }
            guard found else { throw StoredZipError.missingZip64Size }
        }

        let dataStart = extraEnd
        let dataEnd = dataStart.advanced(by: compressedSize)
        guard dataEnd <= data.endIndex else { throw StoredZipError.truncated }

        entries[name] = data[dataStart..<dataEnd]
        offset = dataEnd
    }
    return entries
}
