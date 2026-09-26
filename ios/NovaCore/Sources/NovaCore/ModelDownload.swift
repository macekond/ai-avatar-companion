import Foundation

/// Describes one on-demand model download (Phase 9 of the iOS port plan —
/// mirrors the desktop app's own first-use download of Piper voices/Kokoro
/// weights, just re-hosted somewhere the iOS app controls rather than
/// fetched live from HF/GitHub on a shipped app).
public struct ModelSpec: Equatable {
    public let filename: String
    public let urlString: String

    public init(filename: String, urlString: String) {
        self.filename = filename
        self.urlString = urlString
    }

    public var url: URL? { URL(string: urlString) }
}

/// Returns the specs whose filename isn't in `existingFiles` — pure/testable
/// without touching the real filesystem or network.
public func modelsNeedingDownload(_ specs: [ModelSpec], existingFiles: Set<String>) -> [ModelSpec] {
    specs.filter { !existingFiles.contains($0.filename) }
}

/// Tracks aggregate download progress across multiple files, so a UI can
/// show one overall percentage rather than per-file numbers.
public struct DownloadProgress {
    private let totalFiles: Int
    private var perFileFraction: [Int: Double] = [:]
    private var perFileReceived: [Int: Int64] = [:]
    private var perFileExpected: [Int: Int64] = [:]

    public init(totalFiles: Int) {
        self.totalFiles = totalFiles
    }

    public mutating func recordBytes(received: Int64, expected: Int64, fileIndex: Int) {
        perFileFraction[fileIndex] = expected > 0 ? Double(received) / Double(expected) : 0.0
        perFileReceived[fileIndex] = received
        perFileExpected[fileIndex] = expected
    }

    public var fractionComplete: Double {
        guard totalFiles > 0 else { return 0.0 }
        return perFileFraction.values.reduce(0, +) / Double(totalFiles)
    }

    /// Raw byte totals across every file touched so far — a UI can show
    /// "210 MB / 500 MB" alongside (or instead of) a bare percentage, which
    /// stays readable even early in a multi-gigabyte download where the
    /// percentage itself rounds to 0% for a long time.
    public var totalReceivedBytes: Int64 { perFileReceived.values.reduce(0, +) }
    public var totalExpectedBytes: Int64 { perFileExpected.values.reduce(0, +) }
}
