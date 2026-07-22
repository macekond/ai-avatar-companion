import Foundation
import NovaCore

/// Downloads missing model files to Application Support/models/ (Phase 9 of
/// the iOS port plan) — mirrors the desktop app's own first-use download of
/// Piper voices/Kokoro weights, re-hosted at a URL the iOS app controls
/// rather than fetched live from HF/GitHub on a shipped app (relying on a
/// live third-party fetch from a shipped App Store app is fragile).
@MainActor
final class ModelDownloader: NSObject {
    static func modelsDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("models")
    }

    /// Downloads every spec not already present, reporting aggregate
    /// progress via `onProgress` (0...1) — `DownloadProgress` (NovaCore)
    /// does the fraction math, tested independent of any real network call.
    func downloadMissing(_ specs: [ModelSpec], onProgress: @escaping (Double) -> Void) async {
        let dir = Self.modelsDirectory()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let existing = (try? FileManager.default.contentsOfDirectory(atPath: dir.path))
            .map(Set.init) ?? []
        let needed = modelsNeedingDownload(specs, existingFiles: existing)
        guard !needed.isEmpty else { return }

        var progress = DownloadProgress(totalFiles: needed.count)
        for (index, spec) in needed.enumerated() {
            guard let url = spec.url else { continue }
            await downloadOne(url: url, destination: dir.appendingPathComponent(spec.filename)) { received, expected in
                progress.recordBytes(received: received, expected: expected, fileIndex: index)
                onProgress(progress.fractionComplete)
            }
        }
    }

    private func downloadOne(url: URL, destination: URL, onBytes: @escaping (Int64, Int64) -> Void) async {
        let delegate = ProgressDelegate(onBytes: onBytes)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        guard let (tempURL, response) = try? await session.download(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { return }
        try? FileManager.default.removeItem(at: destination)
        try? FileManager.default.moveItem(at: tempURL, to: destination)
    }

    private final class ProgressDelegate: NSObject, URLSessionDownloadDelegate {
        let onBytes: (Int64, Int64) -> Void
        init(onBytes: @escaping (Int64, Int64) -> Void) { self.onBytes = onBytes }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            onBytes(totalBytesWritten, totalBytesExpectedToWrite)
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            // Handled by the awaited `session.download(from:)` call itself.
        }
    }
}
