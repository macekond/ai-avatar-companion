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

    public init(totalFiles: Int) {
        self.totalFiles = totalFiles
    }

    public mutating func recordBytes(received: Int64, expected: Int64, fileIndex: Int) {
        perFileFraction[fileIndex] = expected > 0 ? Double(received) / Double(expected) : 0.0
    }

    public var fractionComplete: Double {
        guard totalFiles > 0 else { return 0.0 }
        return perFileFraction.values.reduce(0, +) / Double(totalFiles)
    }
}
