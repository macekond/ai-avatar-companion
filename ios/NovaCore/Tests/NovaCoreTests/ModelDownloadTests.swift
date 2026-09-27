import XCTest
@testable import NovaCore

final class ModelSpecTests: XCTestCase {
    let specs = [
        ModelSpec(filename: "ggml-small.bin", urlString: "https://example.com/ggml-small.bin"),
        ModelSpec(filename: "llm.gguf", urlString: "https://example.com/llm.gguf"),
    ]

    func test_noneExist_bothNeedDownload() {
        let needed = modelsNeedingDownload(specs, existingFiles: [])
        XCTAssertEqual(needed.map(\.filename), ["ggml-small.bin", "llm.gguf"])
    }

    func test_oneExists_onlyTheOtherNeedsDownload() {
        let needed = modelsNeedingDownload(specs, existingFiles: ["ggml-small.bin"])
        XCTAssertEqual(needed.map(\.filename), ["llm.gguf"])
    }

    func test_allExist_noneNeedDownload() {
        let needed = modelsNeedingDownload(specs, existingFiles: ["ggml-small.bin", "llm.gguf"])
        XCTAssertTrue(needed.isEmpty)
    }

    func test_url_isValid() {
        for spec in specs {
            XCTAssertNotNil(spec.url)
        }
    }
}

// Per-file, not averaged across files: averaging weighted a 1 KB config the
// same as a 1.1 GB model, so the bar jumped and the MB total grew mid-download.
final class DownloadFileProgressTests: XCTestCase {
    func test_knownSize_reportsFileCountPercentAndMegabytes() {
        let p = DownloadFileProgress(fileIndex: 1, fileCount: 5, receivedBytes: 460_000_000, expectedBytes: 1_117_000_000)
        XCTAssertEqual(p.detail, "File 2 of 5 · 41% · 460 / 1117 MB")
        XCTAssertEqual(p.fraction!, 0.4118, accuracy: 0.001)
    }

    func test_unknownSize_omitsPercentAndHasNoFraction() {
        let p = DownloadFileProgress(fileIndex: 0, fileCount: 3, receivedBytes: 12_000_000, expectedBytes: -1)
        XCTAssertEqual(p.detail, "File 1 of 3 · 12 MB")
        XCTAssertNil(p.fraction)
    }

    func test_subMegabyteFile_isShownInKilobytes() {
        let p = DownloadFileProgress(fileIndex: 5, fileCount: 6, receivedBytes: 4_972, expectedBytes: 4_972)
        XCTAssertEqual(p.detail, "File 6 of 6 · 100% · 5 / 5 KB")
    }

    func test_fraction_isClampedToOne() {
        let p = DownloadFileProgress(fileIndex: 0, fileCount: 1, receivedBytes: 150, expectedBytes: 100)
        XCTAssertEqual(p.fraction, 1.0)
    }
}
