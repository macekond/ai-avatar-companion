import Foundation

/// Streaming sentence-boundary splitter — direct port of `_extract_sentences`
/// in `app/pipeline/llm.py`. Lets TTS start on sentence 1 as soon as it's
/// complete, without waiting for the rest of the LLM reply to generate.
///
/// Splits on `.`/`!`/`?` (optionally followed by a closing quote) then
/// whitespace — mirrors the Python regex `(?<=[.!?])["')»]?\s+` used with
/// `re.split`. Known Phase-1 limitation carried over verbatim: abbreviations
/// ("Mr.", "Dr.") and ellipses will cause incorrect splits; not fixed here
/// since the Python original documents the same limitation.
///
/// A second alternative handles Japanese `。！？`: unlike English, no
/// whitespace ever follows Japanese sentence-final punctuation, so the
/// Python regex's `\s+` requirement never matches and a Japanese reply was
/// never split until generation finished — TTS only started after the whole
/// reply was generated instead of streaming sentence-by-sentence. This
/// alternative splits right after `。！？` (optionally followed by a closing
/// bracket/quote) whether or not whitespace follows; the English alternative
/// above is untouched, so English behavior stays identical.
public struct SentenceSegmenter {
    private var buffer: String = ""

    private static let boundary: NSRegularExpression = {
        // Japanese split point sits after a trailing closing bracket, so 「…！」 keeps its 」.
        try! NSRegularExpression(pattern: "(?<=[.!?])[\"')»]?\\s+|(?:(?<=[。！？])(?![」』）\"'])|(?<=[。！？][」』）\"']))\\s*")
    }()

    public init() {}

    /// Feed newly-arrived text (e.g. one more LLM token). Returns any
    /// sentences that are now complete; the trailing fragment (no terminal
    /// punctuation yet) is retained internally until more text arrives or
    /// `flush()` is called.
    public mutating func feed(_ token: String) -> [String] {
        buffer += token
        let (sentences, remainder) = Self.extractSentences(buffer)
        buffer = remainder
        return sentences
    }

    /// Return and clear whatever fragment remains (e.g. at stream end).
    public mutating func flush() -> String {
        let remainder = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        buffer = ""
        return remainder
    }

    static func extractSentences(_ text: String) -> (sentences: [String], remainder: String) {
        let full = text as NSString
        let matches = boundary.matches(in: text, range: NSRange(location: 0, length: full.length))
        guard !matches.isEmpty else {
            return ([], text)
        }
        var parts: [String] = []
        var cursor = 0
        for match in matches {
            let piece = full.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            parts.append(piece)
            cursor = match.range.location + match.range.length
        }
        parts.append(full.substring(from: cursor))
        let remainder = parts.removeLast()
        return (parts, remainder)
    }
}
