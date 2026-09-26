import XCTest
@testable import NovaCore

/// Builds tiny, hand-crafted fixtures matching the real formats (a stored/
/// uncompressed ZIP of .npy files — confirmed against the real
/// `voices-v1.0.bin` via `unzip`/`numpy` before writing this) rather than
/// embedding the real ~28MB archive in the test bundle.
private func makeNpyBytes(shape: [Int], values: [Float]) -> Data {
    let shapeStr = "(" + shape.map { "\($0)" }.joined(separator: ", ") + (shape.count == 1 ? "," : "") + ")"
    var header = "{'descr': '<f4', 'fortran_order': False, 'shape': \(shapeStr), }"
    // Pad so (10 [preamble] + header.count) is a multiple of 64, matching
    // numpy's own alignment padding, then newline-terminate.
    let preambleLength = 10
    let unpadded = header.count + 1
    let padding = (64 - (preambleLength + unpadded) % 64) % 64
    header += String(repeating: " ", count: padding) + "\n"

    var data = Data()
    data.append(contentsOf: [0x93] + Array("NUMPY".utf8))          // magic
    data.append(contentsOf: [1, 0])                                 // version 1.0
    let headerLen = UInt16(header.utf8.count)
    data.append(UInt8(headerLen & 0xFF))
    data.append(UInt8((headerLen >> 8) & 0xFF))
    data.append(contentsOf: Array(header.utf8))
    for v in values {
        withUnsafeBytes(of: v.bitPattern.littleEndian) { data.append(contentsOf: $0) }
    }
    return data
}

/// Minimal STORED (uncompressed) ZIP with one entry, matching what
/// `voices-v1.0.bin` actually uses (confirmed compression method 0 in its
/// local file header before writing this parser).
private func makeStoredZip(entries: [(name: String, data: Data)]) -> Data {
    var body = Data()

    for entry in entries {
        let nameBytes = Array(entry.name.utf8)
        var local = Data()
        local.append(contentsOf: [0x50, 0x4B, 0x03, 0x04])   // local file header signature
        local.append(contentsOf: [20, 0])                     // version needed
        local.append(contentsOf: [0, 0])                      // flags
        local.append(contentsOf: [0, 0])                      // compression = stored
        local.append(contentsOf: [0, 0, 0, 0])                // mod time/date
        local.append(contentsOf: [0, 0, 0, 0])                // crc32 (unchecked by our reader)
        let size = UInt32(entry.data.count)
        withUnsafeBytes(of: size.littleEndian) { local.append(contentsOf: $0) }  // compressed size
        withUnsafeBytes(of: size.littleEndian) { local.append(contentsOf: $0) }  // uncompressed size
        withUnsafeBytes(of: UInt16(nameBytes.count).littleEndian) { local.append(contentsOf: $0) }
        local.append(contentsOf: [0, 0])                      // extra field length
        local.append(contentsOf: nameBytes)
        local.append(entry.data)
        body.append(local)
    }
    // A minimal reader only needs local headers (no central directory) since
    // it scans sequentially — matches the approach KokoroVoiceStore takes.
    return body
}

/// A single-entry ZIP64 local file header: 32-bit compressed/uncompressed
/// size fields set to the `0xFFFFFFFF` sentinel, with the real 64-bit sizes
/// carried in a tag-`0x0001` extended-info extra field instead — the exact
/// shape the real `voices-v1.0.bin` turned out to use, which a first-pass
/// STORED-only reader (trusting only the 32-bit fields) threw on.
private func makeZip64Entry(name: String, data: Data) -> Data {
    let nameBytes = Array(name.utf8)
    var extra = Data()
    withUnsafeBytes(of: UInt16(0x0001).littleEndian) { extra.append(contentsOf: $0) }  // tag
    withUnsafeBytes(of: UInt16(16).littleEndian) { extra.append(contentsOf: $0) }       // field size
    withUnsafeBytes(of: UInt64(data.count).littleEndian) { extra.append(contentsOf: $0) }  // uncompressed size
    withUnsafeBytes(of: UInt64(data.count).littleEndian) { extra.append(contentsOf: $0) }  // compressed size

    var local = Data()
    local.append(contentsOf: [0x50, 0x4B, 0x03, 0x04])
    local.append(contentsOf: [45, 0])   // version needed (ZIP64 requires >= 4.5)
    local.append(contentsOf: [0, 0])
    local.append(contentsOf: [0, 0])    // compression = stored
    local.append(contentsOf: [0, 0, 0, 0])
    local.append(contentsOf: [0, 0, 0, 0])
    local.append(contentsOf: [0xFF, 0xFF, 0xFF, 0xFF])  // compressed size sentinel
    local.append(contentsOf: [0xFF, 0xFF, 0xFF, 0xFF])  // uncompressed size sentinel
    withUnsafeBytes(of: UInt16(nameBytes.count).littleEndian) { local.append(contentsOf: $0) }
    withUnsafeBytes(of: UInt16(extra.count).littleEndian) { local.append(contentsOf: $0) }
    local.append(contentsOf: nameBytes)
    local.append(extra)
    local.append(data)
    return local
}

final class NpyArrayTests: XCTestCase {
    func test_parsesShapeAndFloatData() throws {
        let bytes = makeNpyBytes(shape: [2, 3], values: [1, 2, 3, 4, 5, 6])
        let array = try NpyArray(data: bytes)
        XCTAssertEqual(array.shape, [2, 3])
        XCTAssertEqual(array.data, [1, 2, 3, 4, 5, 6])
    }

    func test_threeDimensionalShape() throws {
        let bytes = makeNpyBytes(shape: [2, 1, 4], values: [1, 2, 3, 4, 5, 6, 7, 8])
        let array = try NpyArray(data: bytes)
        XCTAssertEqual(array.shape, [2, 1, 4])
        XCTAssertEqual(array.data.count, 8)
    }

    func test_invalidMagic_throws() {
        let bad = Data([0, 1, 2, 3, 4, 5, 6, 7, 8, 9])
        XCTAssertThrowsError(try NpyArray(data: bad))
    }
}

final class StoredZipReaderTests: XCTestCase {
    func test_readsMultipleEntries() throws {
        let zip = makeStoredZip(entries: [
            ("a.npy", Data([1, 2, 3])),
            ("b.npy", Data([4, 5])),
        ])
        let entries = try readStoredZipEntries(zip)
        XCTAssertEqual(entries["a.npy"], Data([1, 2, 3]))
        XCTAssertEqual(entries["b.npy"], Data([4, 5]))
    }

    func test_emptyArchive() throws {
        let entries = try readStoredZipEntries(Data())
        XCTAssertTrue(entries.isEmpty)
    }

    func test_zip64SentinelSizes_readRealSizeFromExtraField() throws {
        // Regression test for a real bug: the actual voices-v1.0.bin file
        // uses ZIP64 (32-bit size fields are 0xFFFFFFFF sentinels), which a
        // reader trusting only those fields throws StoredZipError.truncated
        // on for the very first entry — caught only by testing against the
        // real file, not synthetic non-ZIP64 fixtures like the ones above.
        // Nothing exercised this shape until this test.
        let payload = Data([10, 20, 30, 40, 50])
        let zip = makeZip64Entry(name: "af_test.npy", data: payload)
        let entries = try readStoredZipEntries(zip)
        XCTAssertEqual(entries["af_test.npy"], payload)
    }

    func test_zip64_missingExtraField_throwsMissingZip64Size() {
        // A 0xFFFFFFFF sentinel with no tag-0x0001 extra field to back it up
        // is malformed input — must throw a specific error, not silently
        // misread garbage as the entry's size.
        var local = Data()
        local.append(contentsOf: [0x50, 0x4B, 0x03, 0x04])          // signature (4)
        local.append(contentsOf: [45, 0])                            // version needed (2)
        local.append(contentsOf: [0, 0])                             // flags (2)
        local.append(contentsOf: [0, 0])                             // compression = stored (2)
        local.append(contentsOf: [0, 0, 0, 0])                       // mod time/date (4)
        local.append(contentsOf: [0, 0, 0, 0])                       // crc32 (4)
        local.append(contentsOf: [0xFF, 0xFF, 0xFF, 0xFF])           // compressed size sentinel
        local.append(contentsOf: [0xFF, 0xFF, 0xFF, 0xFF])           // uncompressed size sentinel
        let name = Array("x.npy".utf8)
        withUnsafeBytes(of: UInt16(name.count).littleEndian) { local.append(contentsOf: $0) }
        local.append(contentsOf: [0, 0])  // no extra field at all
        local.append(contentsOf: name)

        XCTAssertThrowsError(try readStoredZipEntries(local)) { error in
            XCTAssertEqual(error as? StoredZipError, .missingZip64Size)
        }
    }
}

final class KokoroVoiceStoreTests: XCTestCase {
    func test_styleVector_indexesByTokenCount() throws {
        // 3 "lengths" x 1 x 2-wide style vectors, distinct per length so
        // indexing is unambiguous.
        let npy = makeNpyBytes(shape: [3, 1, 2], values: [
            0, 0,     // length 0
            10, 11,   // length 1
            20, 21,   // length 2
        ])
        let zip = makeStoredZip(entries: [("af_test.npy", npy)])
        let store = try KokoroVoiceStore(data: zip)

        XCTAssertEqual(try store.styleVector(voice: "af_test", tokenCount: 1), [10, 11])
        XCTAssertEqual(try store.styleVector(voice: "af_test", tokenCount: 2), [20, 21])
    }

    func test_unknownVoice_throws() throws {
        let zip = makeStoredZip(entries: [])
        let store = try KokoroVoiceStore(data: zip)
        XCTAssertThrowsError(try store.styleVector(voice: "nope", tokenCount: 0))
    }
}
