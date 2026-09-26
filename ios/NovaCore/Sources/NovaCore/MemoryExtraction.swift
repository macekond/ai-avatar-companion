import Foundation

/// Direct port of `app.memory_extractor`'s `ExtractionResult`/`_parse`/
/// `parse_problem` — the pure text-parsing half of the desktop app's
/// post-turn memory extraction (a tiny focused LLM call after each
/// exchange, extracting a topic keyword and any grammar problem observed).
/// The LLM-call half lives in the Nova app target (needs `LlamaEngine`),
/// same split as everywhere else native-engine calls stay out of NovaCore.
public struct MemoryExtraction: Equatable {
    public let topic: String?
    public let problemRaw: String?
    public let engaged: Bool

    public init(topic: String? = nil, problemRaw: String? = nil, engaged: Bool = true) {
        self.topic = topic
        self.problemRaw = problemRaw
        self.engaged = engaged
    }

    /// Port of `_parse` — reads `TOPIC:`/`PROBLEM:`/`ENGAGED:` lines
    /// case-insensitively; "none" (either field) leaves it `nil`.
    public static func parse(_ text: String) -> MemoryExtraction {
        var topic: String?
        var problemRaw: String?
        var engaged = true
        for rawLine in text.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            let upper = line.uppercased()
            if upper.hasPrefix("TOPIC:") {
                let val = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces).lowercased()
                if !val.isEmpty, val != "none" { topic = val }
            } else if upper.hasPrefix("PROBLEM:") {
                let val = String(line.dropFirst(8)).trimmingCharacters(in: .whitespaces).lowercased()
                if !val.isEmpty, val != "none" { problemRaw = val }
            } else if upper.hasPrefix("ENGAGED:") {
                let val = String(line.dropFirst(8)).trimmingCharacters(in: .whitespaces).lowercased()
                engaged = !val.hasPrefix("n")
            }
        }
        return MemoryExtraction(topic: topic, problemRaw: problemRaw, engaged: engaged)
    }

    /// Port of `ExtractionResult.parse_problem` — splits `problemRaw` on the
    /// first `:` for the type, then on `→` (preferred) or `->` for
    /// example/correction, stripping surrounding quote characters from both.
    public func parseProblem() -> (type: String, example: String, correction: String)? {
        guard let raw = problemRaw, raw.contains(":") else { return nil }
        let colonParts = raw.split(separator: ":", maxSplits: 1).map(String.init)
        guard colonParts.count == 2 else { return nil }
        let type = colonParts[0].trimmingCharacters(in: .whitespaces)
        let rest = colonParts[1].trimmingCharacters(in: .whitespaces)

        let arrowParts: [String]
        if rest.contains("\u{2192}") {
            arrowParts = rest.components(separatedBy: "\u{2192}")
        } else if rest.contains("->") {
            arrowParts = rest.components(separatedBy: "->")
        } else {
            return nil
        }
        guard arrowParts.count == 2 else { return nil }

        let quoteChars = CharacterSet(charactersIn: "'\"`")
        func stripQuotes(_ s: String) -> String {
            s.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: quoteChars)
        }
        return (type, stripQuotes(arrowParts[0]), stripQuotes(arrowParts[1]))
    }
}
