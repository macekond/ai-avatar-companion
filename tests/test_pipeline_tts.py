"""Tests for TTSPipeline backend lifecycle.

Focus on lazy backend construction: a fresh install whose first profile is
Japanese must not pay for the English Piper voice download at process startup.
The neural backends themselves need audio hardware and third-party packages, so
this test file exercises the facade via a patched _create_backend.
"""
from __future__ import annotations

from unittest.mock import MagicMock, patch

from app.config import Config, ChildConfig, TTSConfig
from app.pipeline.tts import TTSPipeline


def _config(language: str = "en", voice: str = "en_US-kristin-medium") -> Config:
    c = Config()
    c.child = ChildConfig(language=language)
    c.models.tts = TTSConfig(voice=voice)
    return c


class TestLazyBackend:
    def test_construction_does_not_build_backend(self):
        # The whole point: import + __init__ must be cheap; a Japanese-only
        # user shouldn't download the English Piper voice at startup.
        with patch("app.pipeline.tts._create_backend") as create:
            TTSPipeline(_config())
            create.assert_not_called()

    def test_current_voice_reports_intent_before_first_speak(self):
        # Server's _configure_active compares (voice, language) to decide
        # whether to reload — the pipeline must report its intended voice
        # without building the backend first.
        with patch("app.pipeline.tts._create_backend"):
            tts = TTSPipeline(_config(voice="en_US-joe-medium"))
            assert tts.current_voice == "en_US-joe-medium"
            assert tts.language == "en"

    def test_first_speak_triggers_backend_build(self):
        fake_backend = MagicMock()
        with patch("app.pipeline.tts._create_backend",
                   return_value=fake_backend) as create:
            tts = TTSPipeline(_config())
            tts.speak("Hello")
        create.assert_called_once_with(
            tts._config, "en", voice_override="en_US-kristin-medium",
        )
        fake_backend.speak.assert_called_once()

    def test_subsequent_speaks_reuse_the_same_backend(self):
        fake_backend = MagicMock()
        with patch("app.pipeline.tts._create_backend",
                   return_value=fake_backend) as create:
            tts = TTSPipeline(_config())
            tts.speak("one")
            tts.speak("two")
            tts.speak_streaming("three")
        # Backend built once; used three times.
        assert create.call_count == 1
        assert fake_backend.speak.call_count == 2
        fake_backend.speak_streaming.assert_called_once()

    def test_japanese_profile_never_triggers_english_piper(self):
        # The bug this closes: a fresh install whose first (and only) profile is
        # Japanese should never construct the English Piper backend — even
        # though config.yaml's seed default is en_US-kristin-medium.
        seen_languages: list[str] = []

        def _fake_create(_cfg, language, voice_override=None):
            seen_languages.append(language)
            return MagicMock()

        with patch("app.pipeline.tts._create_backend", side_effect=_fake_create):
            tts = TTSPipeline(_config(language="en", voice="en_US-kristin-medium"))
            # Server switches to a Japanese profile before anyone speaks.
            tts.reload_voice("jf_alpha", "ja")
            tts.speak("こんにちは")
        assert seen_languages == ["ja"], (
            f"Expected only a Japanese backend build, got {seen_languages}"
        )


class TestReloadVoice:
    def test_reload_updates_current_voice_and_language(self):
        with patch("app.pipeline.tts._create_backend",
                   return_value=MagicMock(voice_name="jf_alpha")):
            tts = TTSPipeline(_config())
            assert tts.reload_voice("jf_alpha", "ja") is True
        assert tts.current_voice == "jf_alpha"
        assert tts.language == "ja"

    def test_reload_defaults_language_to_current(self):
        with patch("app.pipeline.tts._create_backend",
                   return_value=MagicMock(voice_name="en_US-joe-medium")) as create:
            tts = TTSPipeline(_config(language="en"))
            tts.reload_voice("en_US-joe-medium")   # no explicit language
        # Still English.
        assert create.call_args.args[1] == "en"

    def test_reload_reports_system_fallback_as_empty_voice(self):
        # A SystemTTS fallback reports voice_name="" — current_voice must
        # surface that truthfully, not keep advertising the intended voice id.
        with patch("app.pipeline.tts._create_backend",
                   return_value=MagicMock(voice_name="")):
            tts = TTSPipeline(_config())
            tts.reload_voice("en_US-norman-medium")
        assert tts.current_voice == ""
