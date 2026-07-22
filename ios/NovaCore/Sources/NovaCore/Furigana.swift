import Foundation

/// Kanji covers CJK Unified Ideographs (main block) + a couple of extended
/// blocks that appear in modern Japanese — mirrors `_KANJI_RE` in
/// `app/furigana.py`.
private let kanjiScalarRanges: [ClosedRange<UInt32>] = [
    0x4E00...0x9FFF,    // CJK Unified Ideographs
    0x3400...0x4DBF,    // CJK Extension A
    0xF900...0xFAFF,    // CJK Compatibility Ideographs
]

public func containsKanji(_ s: String) -> Bool {
    s.unicodeScalars.contains { scalar in
        kanjiScalarRanges.contains { $0.contains(scalar.value) }
    }
}

/// Shift full-width katakana to hiragana (leaves everything else alone) —
/// direct port of `katakana_to_hiragana` in `app/furigana.py`. Furigana is
/// conventionally hiragana; the plain codepoint offset covers U+30A1..U+30F6
/// (ァ..ヶ ↔ ぁ..ゖ).
public func katakanaToHiragana(_ s: String) -> String {
    var out = String.UnicodeScalarView()
    for scalar in s.unicodeScalars {
        if (0x30A1...0x30F6).contains(scalar.value) {
            out.append(Unicode.Scalar(scalar.value - 0x60)!)
        } else {
            out.append(scalar)
        }
    }
    return String(out)
}

private func htmlEscape(_ s: String) -> String {
    s.replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
}

/// One morpheme from Japanese text analysis — the pieces `open_jtalk`'s
/// frontend produces, mirroring `pyopenjtalk.run_frontend()`'s output shape.
public struct Morpheme {
    public let surface: String
    /// Grammatical kanji reading in katakana (私→ワタシ), preferred over the
    /// phonological `pron` field which carries changes wrong on top of kanji
    /// (は→ワ). Nil when no reading is available.
    public let readingKatakana: String?

    public init(surface: String, readingKatakana: String?) {
        self.surface = surface
        self.readingKatakana = readingKatakana
    }
}

/// Abstraction over Japanese morphological analysis, so `FuriganaFormatter`
/// can be tested without a native `open_jtalk` dependency. The real
/// implementation (Phase 0 Spike 4 / Phase 6 in the iOS port plan) bridges
/// `open_jtalk` via Objective-C++; no iOS port of it is known to exist yet.
public protocol MorphemeAnalyzing {
    func analyze(_ text: String) throws -> [Morpheme]
}

/// Japanese furigana annotation for learner-friendly display — direct port
/// of `app/furigana.py`. Wraps kanji morphemes in HTML `<ruby><rt>` tags with
/// hiragana readings. Falls back to plain escaped text if the analyzer is
/// unavailable or throws — Japanese display must never break over furigana.
public struct FuriganaFormatter {
    private let analyzer: MorphemeAnalyzing

    public init(analyzer: MorphemeAnalyzing) {
        self.analyzer = analyzer
    }

    public func annotate(_ text: String) -> String {
        guard !text.isEmpty else { return "" }

        let morphemes: [Morpheme]
        do {
            morphemes = try analyzer.analyze(text)
        } catch {
            return htmlEscape(text)
        }

        var parts: [String] = []
        for morpheme in morphemes {
            let surface = morpheme.surface
            guard !surface.isEmpty else { continue }
            guard containsKanji(surface) else {
                parts.append(htmlEscape(surface))
                continue
            }
            guard let readingKatakana = morpheme.readingKatakana, !readingKatakana.isEmpty else {
                parts.append(htmlEscape(surface))
                continue
            }
            let readingHiragana = katakanaToHiragana(readingKatakana)
            parts.append("<ruby>\(htmlEscape(surface))<rt>\(htmlEscape(readingHiragana))</rt></ruby>")
        }
        return parts.joined()
    }

    /// Furigana-annotated HTML for Japanese, otherwise nil — port of
    /// `annotate_for`. Callers attach the result as a sibling `_html` field
    /// on outgoing messages; the UI falls back to the plain text field when nil.
    public func annotateFor(_ text: String, language: String) -> String? {
        guard language == "ja", !text.isEmpty else { return nil }
        return annotate(text)
    }
}
