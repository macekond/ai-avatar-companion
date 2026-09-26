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

final class DownloadProgressTests: XCTestCase {
    func test_fractionComplete_ofMultipleFiles() {
        var progress = DownloadProgress(totalFiles: 2)
        XCTAssertEqual(progress.fractionComplete, 0.0, accuracy: 0.001)

        progress.recordBytes(received: 50, expected: 100, fileIndex: 0)
        // First file half-done out of 2 total files = 0.25 overall.
        XCTAssertEqual(progress.fractionComplete, 0.25, accuracy: 0.001)

        progress.recordBytes(received: 100, expected: 100, fileIndex: 0)
        progress.recordBytes(received: 100, expected: 100, fileIndex: 1)
        XCTAssertEqual(progress.fractionComplete, 1.0, accuracy: 0.001)
    }

    func test_zeroExpectedBytes_doesNotCrashOrDivideByZero() {
        var progress = DownloadProgress(totalFiles: 1)
        progress.recordBytes(received: 0, expected: 0, fileIndex: 0)
        XCTAssertEqual(progress.fractionComplete, 0.0, accuracy: 0.001)
    }

    // The UI wants "210 MB / 500 MB", not just a bare percentage — a
    // multi-GB download that appears to sit at "0%" for a long time (small
    // fraction, rounds to zero) reads as hung even when real bytes are
    // moving; showing actual MB makes progress visible immediately.
    func test_totalBytes_sumAcrossFiles() {
        var progress = DownloadProgress(totalFiles: 2)
        progress.recordBytes(received: 50, expected: 100, fileIndex: 0)
        progress.recordBytes(received: 30, expected: 200, fileIndex: 1)
        XCTAssertEqual(progress.totalReceivedBytes, 80)
        XCTAssertEqual(progress.totalExpectedBytes, 300)
    }

    func test_totalBytes_updatesOnRepeatedCallsForSameFile() {
        var progress = DownloadProgress(totalFiles: 1)
        progress.recordBytes(received: 10, expected: 100, fileIndex: 0)
        progress.recordBytes(received: 60, expected: 100, fileIndex: 0)
        XCTAssertEqual(progress.totalReceivedBytes, 60)
        XCTAssertEqual(progress.totalExpectedBytes, 100)
    }
}
