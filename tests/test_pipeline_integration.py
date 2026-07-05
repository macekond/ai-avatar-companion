"""Integration tests for the STT→LLM→TTS pipeline composition.

Tests the direct wiring between components without WebSocket or server overhead.
`run_pipeline()` mirrors the _run_pipeline() closure in server.py and is
the unit under test here — it lets us verify behaviour without asyncio.

No hardware required; all I/O is mocked.
"""
from __future__ import annotations

import threading
from unittest.mock import MagicMock, call, patch

import pytest

from app.config import Config, ChildConfig, PersonalityConfig, LLMConfig
from app.pipeline.llm import LLMPipeline
from app.pipeline.stt import STTPipeline, SAMPLE_RATE
from app.pipeline.tts import TTSPipeline


# ── Helpers ────────────────────────────────────────────────────────────────

def make_config(level: str = "A") -> Config:
    config = Config()
    config.child = ChildConfig(name="TestKid", level=level)
    config.personality = PersonalityConfig(
        avatar_name="Nova",
        system_prompt="Hi {child_name}! I am {avatar_name}.",
    )
    config.models.llm = LLMConfig(conversation_buffer_exchanges=6)
    return config


def run_pipeline(
    transcript: str,
    llm,
    tts,
    amplitude_calls: list[float],
    stop: threading.Event | None = None,
) -> list[str]:
    """Mirrors the _run_pipeline() logic in server.py.

    Returns the sentences that were actually passed to TTS.
    """
    if stop is None:
        stop = threading.Event()

    def amplitude_cb(value: float) -> None:
        amplitude_calls.append(value)

    spoken: list[str] = []
    for sentence in llm.chat(transcript):
        if stop.is_set():
            break
        spoken.append(sentence)
        tts.speak_streaming(sentence, amplitude_cb, stop)
    return spoken


# ── LLM → TTS handoff ─────────────────────────────────────────────────────

class TestLLMToTTSHandoff:
    def test_each_sentence_calls_tts_once(self):
        llm = MagicMock(spec=LLMPipeline)
        llm.chat.return_value = iter(["S1.", "S2.", "S3."])
        tts = MagicMock(spec=TTSPipeline)

        run_pipeline("hi", llm, tts, [])

        assert tts.speak_streaming.call_count == 3

    def test_sentences_spoken_in_order(self):
        llm = MagicMock(spec=LLMPipeline)
        sentences = ["First.", "Second.", "Third."]
        llm.chat.return_value = iter(sentences)
        tts = MagicMock(spec=TTSPipeline)

        spoken = run_pipeline("hi", llm, tts, [])

        assert spoken == sentences

    def test_correct_text_passed_to_tts(self):
        llm = MagicMock(spec=LLMPipeline)
        llm.chat.return_value = iter(["Football is fun!"])
        tts = MagicMock(spec=TTSPipeline)

        run_pipeline("hi", llm, tts, [])

        first_call_text = tts.speak_streaming.call_args_list[0][0][0]
        assert first_call_text == "Football is fun!"

    def test_empty_llm_response_skips_tts(self):
        llm = MagicMock(spec=LLMPipeline)
        llm.chat.return_value = iter([])
        tts = MagicMock(spec=TTSPipeline)

        run_pipeline("hi", llm, tts, [])

        tts.speak_streaming.assert_not_called()

    def test_transcript_forwarded_to_llm(self):
        llm = MagicMock(spec=LLMPipeline)
        llm.chat.return_value = iter(["Response."])
        tts = MagicMock(spec=TTSPipeline)

        run_pipeline("I went to school", llm, tts, [])

        llm.chat.assert_called_once_with("I went to school")

    def test_amplitude_callback_passed_to_tts(self):
        llm = MagicMock(spec=LLMPipeline)
        llm.chat.return_value = iter(["Hello."])
        tts = MagicMock(spec=TTSPipeline)

        run_pipeline("hi", llm, tts, [])

        # The second positional arg (or amplitude_cb kwarg) must be a callable
        args = tts.speak_streaming.call_args_list[0][0]
        cb = args[1]  # amplitude_cb is the second arg
        assert callable(cb)

    def test_stop_event_passed_to_tts(self):
        llm = MagicMock(spec=LLMPipeline)
        llm.chat.return_value = iter(["Hello."])
        tts = MagicMock(spec=TTSPipeline)
        stop = threading.Event()

        run_pipeline("hi", llm, tts, [], stop=stop)

        args = tts.speak_streaming.call_args_list[0][0]
        assert args[2] is stop


# ── Amplitude callback wiring ─────────────────────────────────────────────

class TestAmplitudeWiring:
    def _tts_with_callbacks(self, values: list[float]) -> MagicMock:
        """A TTS mock that fires the amplitude callback with given values."""
        tts = MagicMock(spec=TTSPipeline)
        def speak(text, amplitude_cb=None, stop=None):
            if amplitude_cb:
                for v in values:
                    amplitude_cb(v)
        tts.speak_streaming.side_effect = speak
        return tts

    def test_amplitude_values_collected(self):
        llm = MagicMock(spec=LLMPipeline)
        llm.chat.return_value = iter(["Hi!"])
        tts = self._tts_with_callbacks([0.2, 0.6, 0.0])

        collected: list[float] = []
        run_pipeline("hi", llm, tts, collected)

        assert collected == [0.2, 0.6, 0.0]

    def test_amplitude_fired_for_each_sentence(self):
        llm = MagicMock(spec=LLMPipeline)
        llm.chat.return_value = iter(["One.", "Two."])
        tts = self._tts_with_callbacks([0.5])  # one call per sentence

        collected: list[float] = []
        run_pipeline("hi", llm, tts, collected)

        assert len(collected) == 2  # one per sentence

    def test_amplitude_values_in_unit_range(self):
        llm = MagicMock(spec=LLMPipeline)
        llm.chat.return_value = iter(["Test sentence."])
        tts = self._tts_with_callbacks([0.0, 0.1, 0.5, 0.9, 1.0])

        collected: list[float] = []
        run_pipeline("hi", llm, tts, collected)

        assert all(0.0 <= v <= 1.0 for v in collected), \
            f"Out-of-range amplitudes: {[v for v in collected if not 0.0 <= v <= 1.0]}"

    def test_amplitude_callback_not_required(self):
        """Pipeline runs fine even if TTS ignores the amplitude callback."""
        llm = MagicMock(spec=LLMPipeline)
        llm.chat.return_value = iter(["Hello!"])
        tts = MagicMock(spec=TTSPipeline)  # ignores callback

        # Must not raise
        run_pipeline("hi", llm, tts, [])


# ── Stop event ────────────────────────────────────────────────────────────

class TestStopEvent:
    def test_pre_set_stop_prevents_any_speaking(self):
        stop = threading.Event()
        stop.set()

        llm = MagicMock(spec=LLMPipeline)
        llm.chat.return_value = iter(["Should be skipped."])
        tts = MagicMock(spec=TTSPipeline)

        spoken = run_pipeline("hi", llm, tts, [], stop=stop)

        assert spoken == []
        tts.speak_streaming.assert_not_called()

    def test_stop_mid_pipeline_halts_remaining_sentences(self):
        stop = threading.Event()

        llm = MagicMock(spec=LLMPipeline)
        llm.chat.return_value = iter(["First.", "Second.", "Third."])

        def speak_and_stop(text, amplitude_cb=None, stop=None):
            if stop:
                stop.set()  # stop after first sentence

        tts = MagicMock(spec=TTSPipeline)
        tts.speak_streaming.side_effect = speak_and_stop

        spoken = run_pipeline("hi", llm, tts, [], stop=stop)

        assert "First." in spoken
        assert "Second." not in spoken
        assert "Third." not in spoken

    def test_fresh_stop_event_allows_full_run(self):
        stop = threading.Event()  # not set

        llm = MagicMock(spec=LLMPipeline)
        llm.chat.return_value = iter(["One.", "Two.", "Three."])
        tts = MagicMock(spec=TTSPipeline)

        spoken = run_pipeline("hi", llm, tts, [], stop=stop)

        assert len(spoken) == 3


# ── Level → prompt content ─────────────────────────────────────────────────

class TestLevelIntegration:
    """Verifies that the level setting flows through to the LLM system prompt."""

    def test_level_a_instruction_in_prompt(self):
        config = make_config(level="A")
        llm = LLMPipeline(config)
        assert "A1/A2" in llm._system_prompt

    def test_level_c2_instruction_in_prompt(self):
        config = make_config(level="C2")
        llm = LLMPipeline(config)
        assert "C2" in llm._system_prompt

    def test_pre_a_prompt_has_gentlest_correction(self):
        config = make_config(level="Pre A")
        llm = LLMPipeline(config)
        prompt = llm._system_prompt.lower()
        assert "silent" in prompt or "never draw attention" in prompt

    def test_c2_prompt_has_most_explicit_correction(self):
        config = make_config(level="C2")
        llm = LLMPipeline(config)
        prompt = llm._system_prompt.lower()
        assert "directly" in prompt or "language partner" in prompt

    def test_switching_level_changes_prompt(self):
        config = make_config(level="A")
        llm = LLMPipeline(config)
        prompt_a = llm._system_prompt
        llm.set_level("B")
        assert llm._system_prompt != prompt_a
        assert "B1/B2" in llm._system_prompt

    def test_base_prompt_preserved_after_level_switch(self):
        config = make_config(level="A")
        llm = LLMPipeline(config)
        llm.set_level("C1")
        assert "TestKid" in llm._system_prompt
        assert "Nova" in llm._system_prompt

    def test_correction_present_at_every_level(self):
        for level in ["Pre A", "A", "B", "C1", "C2"]:
            config = make_config(level=level)
            llm = LLMPipeline(config)
            assert "orrection" in llm._system_prompt, \
                f"No correction guidance in prompt for level {level}"


# ── STT → pipeline: confidence thresholds interact correctly ──────────────

class TestSTTThresholdIntegration:
    """STTPipeline filtering integrates with config threshold values."""

    def _make_stt(self, threshold: float = 0.6) -> STTPipeline:
        import numpy as np
        from app.config import STTConfig
        config = make_config()
        config.models.stt = STTConfig(no_speech_threshold=threshold)
        stt = STTPipeline.__new__(STTPipeline)
        stt._config = config
        stt._model = MagicMock()
        return stt

    def _seg(self, text: str, no_speech_prob: float, logprob: float = -0.3):
        s = MagicMock()
        s.text, s.no_speech_prob, s.avg_logprob = text, no_speech_prob, logprob
        return s

    def test_good_speech_reaches_pipeline(self):
        """When STT produces a valid transcript, it should flow to LLM."""
        import numpy as np
        stt = self._make_stt()
        seg = self._seg("Hello!", no_speech_prob=0.1)
        stt._model.transcribe.return_value = ([seg], MagicMock())

        audio = np.zeros(SAMPLE_RATE, dtype=np.float32)
        result = stt.transcribe(audio)

        assert result == "Hello!"

    def test_noisy_audio_blocked_before_pipeline(self):
        """High no_speech_prob must prevent the transcript from reaching LLM."""
        import numpy as np
        stt = self._make_stt(threshold=0.6)
        seg = self._seg("noise", no_speech_prob=0.8)
        stt._model.transcribe.return_value = ([seg], MagicMock())

        audio = np.zeros(SAMPLE_RATE, dtype=np.float32)
        result = stt.transcribe(audio)

        assert result == ""  # blocked — LLM would receive ""

    def test_threshold_from_config_is_used(self):
        """Config threshold change is reflected in filtering behaviour."""
        import numpy as np
        # With a very low threshold (0.1), even slightly uncertain audio is blocked
        stt = self._make_stt(threshold=0.1)
        seg = self._seg("maybe", no_speech_prob=0.15)
        stt._model.transcribe.return_value = ([seg], MagicMock())

        audio = np.zeros(SAMPLE_RATE, dtype=np.float32)
        result = stt.transcribe(audio)

        assert result == ""
