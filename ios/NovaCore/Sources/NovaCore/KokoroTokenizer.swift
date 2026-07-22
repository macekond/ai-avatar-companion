import Foundation

/// Direct port of `kokoro_onnx`'s tokenizer — the IPA-phoneme-to-int vocab
/// table (from its bundled `config.json`) and the token wrapping
/// `_create_audio` does before calling the ONNX session. Deliberately does
/// NOT port `Tokenizer.phonemize()` (English text -> phonemes via
/// espeak-ng/phonemizer) — that dependency is exactly what's stuck on
/// espeak-ng's autotools cross-compile (see
/// ios/spikes/03-tts-piper/README.md). The Japanese path this app needs
/// produces phonemes via `misaki`-equivalent logic (open_jtalk, already
/// bridged — Phase 6) and calls Kokoro with `is_phonemes=true`, which skips
/// `phonemize()` entirely in the Python original — so `tokenize()` (a pure
/// vocab lookup, no espeak involved) is all that's needed here.
public enum KokoroTokenizer {
    /// Matches kokoro_onnx/config.json's "vocab" table exactly (114 entries).
    public static let vocab: [Character: Int] = [
        ";": 1, ":": 2, ",": 3, ".": 4, "!": 5, "?": 6, "—": 9, "…": 10,
        "\"": 11, "(": 12, ")": 13, "\u{201C}": 14, "\u{201D}": 15, " ": 16,
        "\u{0303}": 17, "ʣ": 18, "ʥ": 19, "ʦ": 20, "ʨ": 21, "ᵝ": 22, "ꭧ": 23,
        "A": 24, "I": 25, "O": 31, "Q": 33, "S": 35, "T": 36, "W": 39, "Y": 41,
        "ᵊ": 42, "a": 43, "b": 44, "c": 45, "d": 46, "e": 47, "f": 48, "h": 50,
        "i": 51, "j": 52, "k": 53, "l": 54, "m": 55, "n": 56, "o": 57, "p": 58,
        "q": 59, "r": 60, "s": 61, "t": 62, "u": 63, "v": 64, "w": 65, "x": 66,
        "y": 67, "z": 68, "ɑ": 69, "ɐ": 70, "ɒ": 71, "æ": 72, "β": 75, "ɔ": 76,
        "ɕ": 77, "ç": 78, "ɖ": 80, "ð": 81, "ʤ": 82, "ə": 83, "ɚ": 85, "ɛ": 86,
        "ɜ": 87, "ɟ": 90, "ɡ": 92, "ɥ": 99, "ɨ": 101, "ɪ": 102, "ʝ": 103,
        "ɯ": 110, "ɰ": 111, "ŋ": 112, "ɳ": 113, "ɲ": 114, "ɴ": 115, "ø": 116,
        "ɸ": 118, "θ": 119, "œ": 120, "ɹ": 123, "ɾ": 125, "ɻ": 126, "ʁ": 128,
        "ɽ": 129, "ʂ": 130, "ʃ": 131, "ʈ": 132, "ʧ": 133, "ʊ": 135, "ʋ": 136,
        "ʌ": 138, "ɣ": 139, "ɤ": 140, "χ": 142, "ʎ": 143, "ʒ": 147, "ʔ": 148,
        "ˈ": 156, "ˌ": 157, "ː": 158, "ʰ": 162, "ʲ": 164, "↓": 169, "→": 171,
        "↗": 172, "↘": 173, "ᵻ": 177,
    ]

    /// Port of `[i for i in map(self.vocab.get, phonemes) if i is not None]`
    /// — characters outside the vocab are silently dropped, not an error.
    public static func tokenize(_ phonemes: String) -> [Int] {
        phonemes.compactMap { vocab[$0] }
    }

    /// Port of `tokens = [[0, *tokens, 0]]` in `_create_audio` — pads with
    /// the 0 token at both ends before feeding the ONNX session.
    public static func wrapWithPadding(_ tokens: [Int]) -> [Int] {
        [0] + tokens + [0]
    }
}
