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


class TestPreview:
    """TTSPipeline.preview(): the ▶ button behind a voice chip — must never
    touch the active backend/voice, regardless of which path it takes."""

    def test_same_language_kokoro_reuses_live_backend(self):
        # Kokoro takes a voice per synthesis call, so previewing another JP
        # voice while JP is already active should reuse the built backend
        # rather than constructing a temporary one. Built via __new__ (a real
        # _KokoroBackend, not a MagicMock) so TTSPipeline.preview's isinstance
        # check succeeds without needing the real kokoro_onnx/misaki deps.
        from app.pipeline.tts import _KokoroBackend
        backend = _KokoroBackend.__new__(_KokoroBackend)
        backend.speak_streaming = MagicMock()
        with patch("app.pipeline.tts._create_backend", return_value=backend) as create:
            tts = TTSPipeline(_config(language="ja", voice="jf_alpha"))
            tts._language = "ja"
            tts.preview("hello", "jm_kumo", "ja")
        create.assert_called_once()   # only the initial _ensure_backend() build
        backend.speak_streaming.assert_called_once_with(
            "hello", None, None, voice="jm_kumo")

    def test_different_language_builds_temporary_backend(self):
        # English preview while the session is Japanese-active: must not
        # disturb the live (Kokoro) backend.
        live_backend = MagicMock(voice_name="jf_alpha")
        temp_backend = MagicMock()
        calls = [live_backend, temp_backend]
        with patch("app.pipeline.tts._create_backend",
                   side_effect=lambda *a, **kw: calls.pop(0)) as create:
            tts = TTSPipeline(_config(language="ja", voice="jf_alpha"))
            tts.speak("konnichiwa")   # builds+uses live_backend
            tts.preview("hello", "en_US-joe-medium", "en")
        assert create.call_count == 2
        assert create.call_args.kwargs == {"voice_override": "en_US-joe-medium"}
        assert create.call_args.args[1] == "en"
        temp_backend.speak_streaming.assert_called_once_with("hello", None, None)
        # The live backend is untouched — reused for the next real utterance.
        assert tts._backend is live_backend

    def test_piper_same_language_still_builds_temporary_backend(self):
        # Piper is per-voice even within English, so a same-language English
        # preview must still use a throwaway backend, not the live one.
        live_backend = MagicMock(voice_name="en_US-kristin-medium")
        temp_backend = MagicMock()
        calls = [live_backend, temp_backend]
        with patch("app.pipeline.tts._create_backend",
                   side_effect=lambda *a, **kw: calls.pop(0)):
            tts = TTSPipeline(_config(language="en", voice="en_US-kristin-medium"))
            tts.speak("hi")
            tts.preview("hello", "en_US-joe-medium", "en")
        temp_backend.speak_streaming.assert_called_once_with("hello", None, None)
        assert tts._backend is live_backend

    def test_empty_text_is_skipped(self):
        with patch("app.pipeline.tts._create_backend") as create:
            tts = TTSPipeline(_config())
            tts.preview("   ", "en_US-joe-medium", "en")
        create.assert_not_called()


class TestKokoroBackend:
    """The regression pins: all 4 Japanese voices ended up sounding identical
    because a misaki API change (0.9+ returns a plain phonemes string, not the
    old (phonemes, tokens) tuple) made every JP utterance raise before Kokoro
    saw anything — the exception silently dropped speech back to macOS 'say
    -v Kyoko' for every voice pick. Both scenarios are pinned here.
    """

    def _make_backend(self, g2p_return, voice_name="jf_alpha"):
        from app.pipeline.tts import _KokoroBackend
        backend = _KokoroBackend.__new__(_KokoroBackend)
        backend._kokoro = MagicMock()
        backend._kokoro.create.return_value = (
            [0.0] * 8, 24_000,   # (samples, sample_rate)
        )
        backend._g2p = MagicMock(return_value=g2p_return)
        backend.voice_name = voice_name
        backend._sample_rate = 24_000
        backend._speed = 1.0
        return backend

    def test_new_misaki_string_return_is_accepted(self):
        # 0.9.x: JAG2P() returns a plain string. Must NOT raise a
        # too-many-values-to-unpack ValueError.
        backend = self._make_backend(g2p_return="koɲɲiʨiβa")
        with patch("app.pipeline.tts._play_float_audio"):
            backend.speak_streaming("こんにちは")
        # Whatever the g2p shape, the raw phoneme string must reach Kokoro.
        assert backend._kokoro.create.call_args.args[0] == "koɲɲiʨiβa"

    def test_legacy_misaki_tuple_return_still_works(self):
        # <0.9: returned (phonemes, tokens). Kept working defensively so a
        # downgrade doesn't break the app.
        backend = self._make_backend(g2p_return=("koɲɲiʨiβa", ["mock-tokens"]))
        with patch("app.pipeline.tts._play_float_audio"):
            backend.speak_streaming("こんにちは")
        assert backend._kokoro.create.call_args.args[0] == "koɲɲiʨiβa"

    def test_voice_name_is_forwarded_to_kokoro_create(self):
        # If the voice id isn't actually threaded through, chip picks look
        # like they change something but every voice sounds identical — the
        # original user-visible bug behind this test class.
        backend = self._make_backend(g2p_return="koɲɲiʨiβa",
                                     voice_name="jf_nezumi")
        with patch("app.pipeline.tts._play_float_audio"):
            backend.speak_streaming("こんにちは")
        assert backend._kokoro.create.call_args.kwargs["voice"] == "jf_nezumi"
