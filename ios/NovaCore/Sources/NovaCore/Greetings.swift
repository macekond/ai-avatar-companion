import Foundation

/// Per-language user-facing system text — the app's own strings, not LLM
/// output. Direct port of `app/greetings.py`, keeping Japanese profiles from
/// hearing English greetings.
private let greetingTemplates: [String: [String: String]] = [
    "en": [
        "greeting_new": "Hi {name}! I'm {avatar}, your language practice friend. What did you do today?",
        "greeting_returning": "Welcome back, {name}{age_suffix}! I missed you! What did you get up to?",
        "greeting_returning_topic": "Welcome back, {name}{age_suffix}! Last time we talked about {topic}. What's new today?",
        "onboarding_ask_name": "Hi! I'm {avatar}, your practice friend! I'm so happy to meet you! What's your name?",
        "onboarding_ask_age": "What a lovely name, {name}! How old are you?",
        "sorry": "I didn't hear you — try again!",
        "napping": "My brain is napping — try again!",
        "preview_sample": "Hello! I'm your practice friend. Let's have fun learning!",
    ],
    "ja": [
        "greeting_new": "はじめまして、{name}さん！わたしは{avatar}だよ。今日はなにをしたの？",
        "greeting_returning": "また会えてうれしい、{name}さん{age_suffix}！今日はなにをしたの？",
        "greeting_returning_topic": "また会えてうれしい、{name}さん{age_suffix}！前は{topic}の話をしたね。今日はなにかあった？",
        "onboarding_ask_name": "はじめまして！わたしは{avatar}だよ。お名前はなに？",
        "onboarding_ask_age": "すてきな名前だね、{name}さん！なんさい？",
        "sorry": "うまくきこえなかったよ、もう一度おしえて！",
        "napping": "あたまがちょっと休みたいって、もう一度おねがい！",
        "preview_sample": "こんにちは！わたしはあなたの練習の友だちです。楽しく勉強しよう！",
    ],
]

/// Language-appropriate parenthetical age note (empty when age unknown).
public func ageSuffix(_ age: Int?, language: String) -> String {
    guard let age else { return "" }
    if language == "ja" { return "（\(age)才）" }
    return " (age \(age))"
}

/// Look up a system text key and format its `{placeholder}`s. Unknown
/// language falls back to English.
public func systemText(_ key: String, language: String, _ fmt: [String: String]) -> String {
    let lang = greetingTemplates[language] != nil ? language : "en"
    let template = greetingTemplates[lang]?[key] ?? greetingTemplates["en"]![key]!
    var result = template
    for (placeholder, value) in fmt {
        result = result.replacingOccurrences(of: "{\(placeholder)}", with: value)
    }
    return result
}
