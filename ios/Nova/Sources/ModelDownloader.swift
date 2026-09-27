import Foundation
import NovaCore

/// Downloads missing model files to Application Support/models/ (Phase 9 of
/// the iOS port plan) — mirrors the desktop app's own first-use download of
/// Piper voices/Kokoro weights, re-hosted at a URL the iOS app controls
/// rather than fetched live from HF/GitHub on a shipped app (relying on a
/// live third-party fetch from a shipped App Store app is fragile).
@MainActor
final class ModelDownloader: NSObject {
    nonisolated static func modelsDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("models")
    }

    /// Downloads every spec not already present, reporting the current file's
    /// progress via `onProgress` (on the main actor, throttled).
    ///
    /// Returns `false` if any file failed to download after retries — the
    /// caller must not treat setup as "ready" in that case.
    @discardableResult
    func downloadMissing(_ specs: [ModelSpec], onProgress: @escaping @MainActor (DownloadFileProgress) -> Void) async -> Bool {
        let dir = Self.modelsDirectory()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let existing = (try? FileManager.default.contentsOfDirectory(atPath: dir.path))
            .map(Set.init) ?? []
        let needed = modelsNeedingDownload(specs, existingFiles: existing)
        guard !needed.isEmpty else { return true }

        var allSucceeded = true
        for (index, spec) in needed.enumerated() {
            guard let url = spec.url else {
                Diagnostics.log("model_download_failed", ["file": spec.filename, "reason": "invalid_url"])
                allSucceeded = false
                continue
            }
            let succeeded = await downloadOne(url: url, destination: dir.appendingPathComponent(spec.filename)) { received, expected in
                onProgress(DownloadFileProgress(fileIndex: index, fileCount: needed.count, receivedBytes: received, expectedBytes: expected))
            }
            if !succeeded {
                Diagnostics.log("model_download_failed", ["file": spec.filename])
                allSucceeded = false
            }
        }
        return allSucceeded
    }

    /// `requestTimeout` is an idle timeout (no bytes for 30s), which is what
    /// catches a genuinely stalled connection. The per-attempt resource cap
    /// only guards against pathological cases, so it must comfortably exceed
    /// a slow download of the ~1.1 GB LLM — a 10-minute cap aborted it (and
    /// restarted from zero) on anything under ~1.9 MB/s.
    private static let requestTimeout: TimeInterval = 30
    private static let resourceTimeout: TimeInterval = 3 * 60 * 60
    private static let maxAttempts = 3

    private func downloadOne(url: URL, destination: URL, onBytes: @escaping @MainActor (Int64, Int64) -> Void) async -> Bool {
        for attempt in 1...Self.maxAttempts {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = Self.requestTimeout
            config.timeoutIntervalForResource = Self.resourceTimeout
            let result: Result<Void, Error> = await withCheckedContinuation { continuation in
                let delegate = DownloadDelegate(destination: destination, onBytes: onBytes) { result in
                    continuation.resume(returning: result)
                }
                // The async `session.download(from:)` convenience never calls the session
                // delegate's didWriteData, so progress needs an explicit download task.
                let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
                session.downloadTask(with: url).resume()
                session.finishTasksAndInvalidate()
            }
            switch result {
            case .success:
                return true
            case .failure(let error):
                Diagnostics.log("model_download_retry", [
                    "file": destination.lastPathComponent, "attempt": String(attempt), "reason": String(describing: error),
                ])
            }
        }
        return false
    }

    private struct HTTPStatusError: Error, CustomStringConvertible {
        let code: Int
        var description: String { "http_\(code)" }
    }

    /// Callbacks arrive on the session's own serial delegate queue, so the
    /// mutable state below is only ever touched from that one queue.
    private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        private let destination: URL
        private let onBytes: @MainActor (Int64, Int64) -> Void
        private let completion: (Result<Void, Error>) -> Void
        private var lastReport = Date.distantPast
        private var fileResult: Result<Void, Error>?

        init(destination: URL, onBytes: @escaping @MainActor (Int64, Int64) -> Void, completion: @escaping (Result<Void, Error>) -> Void) {
            self.destination = destination
            self.onBytes = onBytes
            self.completion = completion
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            let now = Date()
            guard now.timeIntervalSince(lastReport) >= 0.25 else { return }
            lastReport = now
            let onBytes = self.onBytes
            Task { @MainActor in onBytes(totalBytesWritten, totalBytesExpectedToWrite) }
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            // The temp file is deleted as soon as this returns, so it must be moved here.
            let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? -1
            guard status == 200 else {
                fileResult = .failure(HTTPStatusError(code: status))
                return
            }
            do {
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: location, to: destination)
                fileResult = .success(())
            } catch {
                fileResult = .failure(error)
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let error {
                completion(.failure(error))
            } else {
                completion(fileResult ?? .failure(URLError(.cannotCreateFile)))
            }
        }
    }
}
