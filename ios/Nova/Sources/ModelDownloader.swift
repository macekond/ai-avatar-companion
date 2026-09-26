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
    /// progress via `onProgress` (fraction 0...1, bytes received, bytes
    /// expected) — `DownloadProgress` (NovaCore) does the fraction/byte math,
    /// tested independent of any real network call.
    ///
    /// Returns `false` if any file failed to download after retries — the
    /// caller must not treat setup as "ready" in that case. Every failure
    /// used to be silently swallowed here (`try?` discarding the error, a
    /// bare `return` with no signal at all), which meant a single stalled or
    /// failed download left that model file simply never created — nothing
    /// in the logs, nothing in the UI, and the app would sit on "ready" with
    /// a permanently-nil engine, making the whole thing look randomly broken
    /// rather than reporting an actual network failure.
    @discardableResult
    func downloadMissing(_ specs: [ModelSpec], onProgress: @escaping (_ fraction: Double, _ receivedBytes: Int64, _ expectedBytes: Int64) -> Void) async -> Bool {
        let dir = Self.modelsDirectory()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let existing = (try? FileManager.default.contentsOfDirectory(atPath: dir.path))
            .map(Set.init) ?? []
        let needed = modelsNeedingDownload(specs, existingFiles: existing)
        guard !needed.isEmpty else { return true }

        var progress = DownloadProgress(totalFiles: needed.count)
        var allSucceeded = true
        for (index, spec) in needed.enumerated() {
            guard let url = spec.url else {
                Diagnostics.log("model_download_failed", ["file": spec.filename, "reason": "invalid_url"])
                allSucceeded = false
                continue
            }
            let succeeded = await downloadOne(url: url, destination: dir.appendingPathComponent(spec.filename)) { received, expected in
                progress.recordBytes(received: received, expected: expected, fileIndex: index)
                onProgress(progress.fractionComplete, progress.totalReceivedBytes, progress.totalExpectedBytes)
            }
            if !succeeded {
                Diagnostics.log("model_download_failed", ["file": spec.filename])
                allSucceeded = false
            }
        }
        return allSucceeded
    }

    /// A stalled (not merely slow) connection would otherwise hang for
    /// `URLSessionConfiguration`'s default 7-day `timeoutIntervalForResource`
    /// before ever failing — indistinguishable from the app just being
    /// broken. 10 minutes per attempt, up to 3 attempts, is generous enough
    /// for a real multi-hundred-MB model over a slow connection while still
    /// failing in bounded time so the retry/error path actually runs.
    private static let requestTimeout: TimeInterval = 30
    private static let resourceTimeout: TimeInterval = 600
    private static let maxAttempts = 3

    private func downloadOne(url: URL, destination: URL, onBytes: @escaping (Int64, Int64) -> Void) async -> Bool {
        for attempt in 1...Self.maxAttempts {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = Self.requestTimeout
            config.timeoutIntervalForResource = Self.resourceTimeout
            let delegate = ProgressDelegate(onBytes: onBytes)
            let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
            do {
                let (tempURL, response) = try await session.download(from: url)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    Diagnostics.log("model_download_retry", [
                        "file": destination.lastPathComponent, "attempt": String(attempt),
                        "reason": "http_\((response as? HTTPURLResponse)?.statusCode ?? -1)",
                    ])
                    continue
                }
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: tempURL, to: destination)
                return true
            } catch {
                Diagnostics.log("model_download_retry", [
                    "file": destination.lastPathComponent, "attempt": String(attempt), "reason": String(describing: error),
                ])
            }
        }
        return false
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
