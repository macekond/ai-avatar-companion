import Foundation

public struct TranscriptCorrection: Codable, Equatable {
    public let kind: String
    public let wrong: String
    public let right: String

    public init(kind: String, wrong: String, right: String) {
        self.kind = kind
        self.wrong = wrong
        self.right = right
    }
}

public struct TranscriptTurn: Equatable {
    public let id: Int
    public let you: String
    public let nova: String
    public var corrections: [TranscriptCorrection]
}

/// Append-only per-child conversation history on disk — direct port of
/// `TranscriptStore` in `app/transcript.py`. One JSONL file per child,
/// mirroring `MemoryManager`'s one-file-per-child layout but kept separate
/// since it's display-only, never fed back into the LLM prompt.
public final class TranscriptStore {
    private let dir: URL
    private let path: URL
    /// A fire-and-forget task (e.g. a correction landing after profile
    /// deletion) can outlive `delete()` and still hold this instance; once
    /// tombstoned, appends must no-op rather than resurrecting the file —
    /// same invariant as `MemoryManager`'s delete-tombstone pattern.
    private var deleted = false

    public init(transcriptsDir: URL, slug: String) {
        self.dir = transcriptsDir
        self.path = transcriptsDir.appendingPathComponent("\(slug).jsonl")
    }

    // MARK: Writing

    public func appendTurn(id: Int, you: String, nova: String) {
        append(["kind": "turn", "id": id, "you": you, "nova": nova])
    }

    public func appendCorrection(id: Int, kind: String, wrong: String, right: String) {
        append(["kind": "correction", "id": id, "correction_kind": kind, "wrong": wrong, "right": right])
    }

    private func append(_ record: [String: Any]) {
        guard !deleted else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let data = try? JSONSerialization.data(withJSONObject: record) else { return }
        guard let line = (String(data: data, encoding: .utf8).map { $0 + "\n" })?.data(using: .utf8) else { return }

        if let handle = FileHandle(forWritingAtPath: path.path) {
            defer { handle.closeFile() }
            handle.seekToEndOfFile()
            handle.write(line)
        } else {
            try? line.write(to: path)
        }
    }

    // MARK: Reading

    /// Ordered turns with their corrections applied. A missing file yields
    /// `[]`; malformed or unknown lines are skipped.
    public func load() -> [TranscriptTurn] {
        guard let data = try? Data(contentsOf: path), let text = String(data: data, encoding: .utf8) else {
            return []
        }
        var turns: [Int: TranscriptTurn] = [:]
        var order: [Int] = []

        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard
                let lineData = String(line).data(using: .utf8),
                let rec = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                let id = rec["id"] as? Int
            else { continue }

            switch rec["kind"] as? String {
            case "turn":
                if turns[id] == nil { order.append(id) }
                let existingCorrections = turns[id]?.corrections ?? []
                turns[id] = TranscriptTurn(
                    id: id, you: rec["you"] as? String ?? "", nova: rec["nova"] as? String ?? "",
                    corrections: existingCorrections
                )
            case "correction":
                guard turns[id] != nil else { continue }   // correction for an unknown turn — ignore
                turns[id]?.corrections.append(TranscriptCorrection(
                    kind: rec["correction_kind"] as? String ?? "",
                    wrong: rec["wrong"] as? String ?? "",
                    right: rec["right"] as? String ?? ""
                ))
            default:
                continue
            }
        }
        return order.compactMap { turns[$0] }
    }

    /// Highest turn id on record, or 0 when there's no history.
    public func lastId() -> Int {
        load().map(\.id).max() ?? 0
    }

    // MARK: Removal

    /// Remove this child's history and tombstone the instance.
    public func delete() {
        deleted = true
        try? FileManager.default.removeItem(at: path)
    }
}
