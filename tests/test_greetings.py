from app.greetings import age_suffix, system_text

ALL_KEYS = [
    "greeting_new",
    "greeting_returning",
    "greeting_returning_topic",
    "onboarding_ask_name",
    "onboarding_ask_age",
    "sorry",
    "napping",
]


def test_greeting_new_english():
    text = system_text("greeting_new", "en", name="Lily", avatar="Nova")
    assert "Lily" in text
    assert "Nova" in text


def test_greeting_new_japanese():
    text = system_text("greeting_new", "ja", name="Yuki", avatar="Nova")
    assert "Yuki" in text
    assert "Nova" in text
    assert "はじめまして" in text


def test_unknown_language_falls_back_to_english():
    text = system_text("greeting_new", "fr", name="Lily", avatar="Nova")
    assert text == system_text("greeting_new", "en", name="Lily", avatar="Nova")


def test_all_keys_exist_for_en_and_ja():
    for key in ALL_KEYS:
        for lang in ("en", "ja"):
            fmt = {"name": "X", "avatar": "Y", "age_suffix": "", "topic": "Z"}
            assert system_text(key, lang, **fmt)


def test_age_suffix():
    assert age_suffix(None, "ja") == ""
    assert age_suffix(8, "ja") == "（8才）"
    assert age_suffix(8, "en") == " (age 8)"
