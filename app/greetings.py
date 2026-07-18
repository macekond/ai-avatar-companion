"""Per-language user-facing system text — the app's own strings, not
LLM output. Keeps Japanese profiles from hearing English greetings.
"""
from __future__ import annotations

_TEMPLATES: dict[str, dict[str, str]] = {
    "en": {
        "greeting_new": "Hi {name}! I'm {avatar}, your language practice friend. What did you do today?",
        "greeting_returning": "Welcome back, {name}{age_suffix}! I missed you! What did you get up to?",
        "greeting_returning_topic": "Welcome back, {name}{age_suffix}! Last time we talked about {topic}. What's new today?",
        "onboarding_ask_name": "Hi! I'm {avatar}, your practice friend! I'm so happy to meet you! What's your name?",
        "onboarding_ask_age": "What a lovely name, {name}! How old are you?",
        "sorry": "I didn't hear you — try again!",
        "napping": "My brain is napping — try again!",
    },
    "ja": {
        "greeting_new": "はじめまして、{name}さん！わたしは{avatar}だよ。今日はなにをしたの？",
        "greeting_returning": "また会えてうれしい、{name}さん{age_suffix}！今日はなにをしたの？",
        "greeting_returning_topic": "また会えてうれしい、{name}さん{age_suffix}！前は{topic}の話をしたね。今日はなにかあった？",
        "onboarding_ask_name": "はじめまして！わたしは{avatar}だよ。お名前はなに？",
        "onboarding_ask_age": "すてきな名前だね、{name}さん！なんさい？",
        "sorry": "うまくきこえなかったよ、もう一度おしえて！",
        "napping": "あたまがちょっと休みたいって、もう一度おねがい！",
    },
}


def age_suffix(age: int | None, language: str) -> str:
    """Language-appropriate parenthetical age note (empty when age unknown)."""
    if age is None:
        return ""
    if language == "ja":
        return f"（{age}才）"
    return f" (age {age})"


def system_text(key: str, language: str, **fmt) -> str:
    """Look up a system text key and format it. Unknown language → English."""
    lang = language if language in _TEMPLATES else "en"
    tpl = _TEMPLATES[lang].get(key) or _TEMPLATES["en"][key]
    return tpl.format(**fmt)
