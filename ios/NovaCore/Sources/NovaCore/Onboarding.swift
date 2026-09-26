import Foundation

/// Direct port of `app/server.py`'s onboarding name/age extraction
/// (`_extract_name`/`_extract_age`) — regex-based, best-effort parsing of a
/// spoken transcript into a usable first name and age.

private let onboardingFillerWords: Set<String> = [
    "my", "name", "is", "i'm", "i", "am", "it", "a", "the",
    "just", "hi", "hello", "hey", "its", "im",
]

private let onboardingWordNumbers: [String: Int] = [
    "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
    "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
    "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14,
    "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18,
]

private func stripNonAlpha(_ s: String) -> String {
    String(s.lowercased().unicodeScalars.filter { CharacterSet.lowercaseLetters.contains($0) })
}

private func stripNonDigits(_ s: String) -> String {
    String(s.unicodeScalars.filter { CharacterSet.decimalDigits.contains($0) })
}

/// First word that isn't filler, alphabetic, and at least 2 letters —
/// capitalized. `nil` if nothing usable was said.
public func extractName(from text: String) -> String? {
    for word in text.split(separator: " ") {
        let w = stripNonAlpha(String(word))
        if !w.isEmpty, !onboardingFillerWords.contains(w), w.count >= 2 {
            return w.prefix(1).uppercased() + w.dropFirst()
        }
    }
    return nil
}

/// A digit 1...18 anywhere in the text, else a spelled-out number word
/// (one...eighteen). Digits take priority over word-numbers, matching the
/// Python original's two-pass scan.
public func extractAge(from text: String) -> Int? {
    for word in text.split(separator: " ") {
        let digits = stripNonDigits(String(word))
        if !digits.isEmpty, let value = Int(digits), (1...18).contains(value) {
            return value
        }
    }
    for word in text.split(separator: " ") {
        let w = stripNonAlpha(String(word))
        if let value = onboardingWordNumbers[w] {
            return value
        }
    }
    return nil
}
