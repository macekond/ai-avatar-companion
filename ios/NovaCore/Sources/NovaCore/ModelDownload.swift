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

/// Progress of the one file currently downloading, for the setup overlay.
public struct DownloadFileProgress: Equatable {
    public let fileIndex: Int
    public let fileCount: Int
    public let receivedBytes: Int64
    public let expectedBytes: Int64

    public init(fileIndex: Int, fileCount: Int, receivedBytes: Int64, expectedBytes: Int64) {
        self.fileIndex = fileIndex
        self.fileCount = fileCount
        self.receivedBytes = receivedBytes
        self.expectedBytes = expectedBytes
    }

    /// nil when the server didn't report a size (no Content-Length).
    public var fraction: Double? {
        guard expectedBytes > 0 else { return nil }
        return min(1.0, Double(receivedBytes) / Double(expectedBytes))
    }

    public var detail: String {
        let file = "File \(fileIndex + 1) of \(fileCount)"
        guard let fraction else { return "\(file) · \(receivedBytes / 1_000_000) MB" }
        if expectedBytes < 1_000_000 {
            return "\(file) · \(Int(fraction * 100))% · \(Self.kilobytes(receivedBytes)) / \(Self.kilobytes(expectedBytes)) KB"
        }
        return "\(file) · \(Int(fraction * 100))% · \(receivedBytes / 1_000_000) / \(expectedBytes / 1_000_000) MB"
    }

    private static func kilobytes(_ bytes: Int64) -> Int64 { (bytes + 500) / 1_000 }
}
