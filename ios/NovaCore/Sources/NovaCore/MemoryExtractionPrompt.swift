import Foundation

/// Builds the small, focused prompt `MemoryExtractor.extract` sends after
/// each turn. Split out as a pure function so the language-aware wording can
/// be TDD'd without `LlamaEngine`. The output format (`TOPIC:`/`PROBLEM:`/
/// `ENGAGED:`, parsed by `MemoryExtraction.parse`) is identical for every
/// language — only the framing and, for Japanese, the requested topic
/// language and example change, so a Japanese topic never ends up expressed
/// in English inside an otherwise-Japanese sentence.
public enum MemoryExtractionPrompt {
    public static func build(transcript: String, reply: String, language: String) -> String {
        let child = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let avatar = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        let template = language == "ja" ? japaneseTemplate : englishTemplate
        return template
            .replacingOccurrences(of: "%CHILD%", with: child)
            .replacingOccurrences(of: "%AVATAR%", with: avatar)
    }

    private static let englishTemplate = """
    Analyze this English learning conversation turn.

    Child said: "%CHILD%"
    Avatar replied: "%AVATAR%"

    Reply in EXACTLY this format (3 lines, nothing else):
    TOPIC: <main topic keyword 1-3 words, or none>
    PROBLEM: <error_type: child_said -> correction, or none>
    ENGAGED: <yes or no>

    Examples:
    TOPIC: football
    PROBLEM: past_tense: goed -> went
    ENGAGED: yes

    TOPIC: none
    PROBLEM: none
    ENGAGED: no
    """

    private static let japaneseTemplate = """
    Analyze this Japanese learning conversation turn.

    Child said: "%CHILD%"
    Avatar replied: "%AVATAR%"

    Reply in EXACTLY this format (3 lines, nothing else). Write the TOPIC keyword in Japanese:
    TOPIC: <main topic keyword 1-3 words in Japanese, or none>
    PROBLEM: <error_type: child_said -> correction, or none>
    ENGAGED: <yes or no>

    Examples:
    TOPIC: サッカー
    PROBLEM: past_tense: goed -> went
    ENGAGED: yes

    TOPIC: none
    PROBLEM: none
    ENGAGED: no
    """
}
