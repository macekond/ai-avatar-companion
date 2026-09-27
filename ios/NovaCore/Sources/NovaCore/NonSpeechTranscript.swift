import Foundation

/// True when `text` is not real child speech — empty, or only whisper's
/// non-speech annotations (`[Music]`, `[BLANK_AUDIO]`, `(音楽)`, `(拍手)`,
/// `♪`, ...) and/or whitespace/punctuation around them. Whisper emits these
/// on silence instead of an empty string, and treating them as speech used to
/// make Nova reply to, transcribe, and save silence as if the child had
/// spoken.
///
/// After stripping any bracketed/parenthesised group (ASCII and fullwidth),
/// real speech is whatever's left containing at least one letter or digit
/// (Unicode `alphanumerics`, which covers kana/kanji) — an annotation alone,
/// or a lone music symbol with no bracket at all (bare `♪`), has none.
public func isNonSpeechTranscript(_ text: String) -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return true }
    let bracketPattern = "\\[[^\\]]*\\]|\\([^)]*\\)|（[^）]*）|【[^】]*】"
    let withoutAnnotations = trimmed.replacingOccurrences(of: bracketPattern, with: "", options: .regularExpression)
    return !withoutAnnotations.unicodeScalars.contains(where: CharacterSet.alphanumerics.contains)
}
