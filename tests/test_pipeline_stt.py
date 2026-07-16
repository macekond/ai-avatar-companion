"""Tests for STT pipeline transcription filtering.

No mic or Whisper model download required — WhisperModel is mocked.
"""

import numpy as np
import pytest
from unittest.mock import MagicMock

from app.config import Config, ChildConfig, STTConfig
from app.pipeline.stt import (
    STTPipeline, SAMPLE_RATE, MIN_DURATION_S, whisper_is_cached,
)


# ── Helpers ────────────────────────────────────────────────────────────────

def make_stt(threshold: float = 0.6) -> STTPipeline:
    """Create an STTPipeline with a mock WhisperModel (no download)."""
    config = Config()
    config.child = ChildConfig()
    config.models.stt = STTConfig(
        engine="faster-whisper",
        model="small.en",
        no_speech_threshold=threshold,
    )
    stt = STTPipeline.__new__(STTPipeline)
    stt._config = config
    stt._model = MagicMock()
    return stt


def mock_segment(text: str, no_speech_prob: float = 0.1, avg_logprob: float = -0.5):
    seg = MagicMock()
    seg.text = text
    seg.no_speech_prob = no_speech_prob
    seg.avg_logprob = avg_logprob
    return seg


def audio(seconds: float = 1.0) -> np.ndarray:
    return np.zeros(int(SAMPLE_RATE * seconds), dtype=np.float32)


# ── Constants ─────────────────────────────────────────────────────────────

class TestConstants:
    def test_sample_rate_is_16_khz(self):
        assert SAMPLE_RATE == 16_000

    def test_min_duration_is_positive(self):
        assert MIN_DURATION_S > 0

    def test_min_duration_less_than_one_second(self):
        # Should be a short guard, not a long wait
        assert MIN_DURATION_S < 1.0


# ── Length guard ───────────────────────────────────────────────────────────

class TestLengthGuard:
    def test_empty_array_returns_empty_string(self):
        stt = make_stt()
        assert stt.transcribe(np.zeros(0, dtype=np.float32)) == ""

    def test_too_short_returns_empty_string(self):
        stt = make_stt()
        too_short = np.zeros(int(SAMPLE_RATE * MIN_DURATION_S) - 1, dtype=np.float32)
        assert stt.transcribe(too_short) == ""
        stt._model.transcribe.assert_not_called()

    def test_exactly_min_duration_passes_to_model(self):
        stt = make_stt()
        stt._model.transcribe.return_value = ([], MagicMock())
        ok = np.zeros(int(SAMPLE_RATE * MIN_DURATION_S), dtype=np.float32)
        stt.transcribe(ok)
        stt._model.transcribe.assert_called_once()


# ── Cache detection (used by the setup screen) ──────────────────────────────

class TestWhisperIsCached:
    def _seed(self, cache_dir, model_id="small.en"):
        repo = f"Systran/faster-whisper-{model_id}"
        snap = cache_dir / ("models--" + repo.replace("/", "--")) / "snapshots" / "abc123"
        snap.mkdir(parents=True)
        (snap / "model.bin").write_bytes(b"x")

    def test_returns_false_when_not_downloaded(self, tmp_path):
        assert whisper_is_cached("small.en", cache_dir=tmp_path) is False

    def test_returns_true_when_snapshot_present(self, tmp_path):
        self._seed(tmp_path, "small.en")
        assert whisper_is_cached("small.en", cache_dir=tmp_path) is True

    def test_empty_snapshots_dir_is_not_cached(self, tmp_path):
        # A bare models--…/snapshots dir with nothing in it means an interrupted
        # or failed download — treat it as not cached so we still say downloading.
        (tmp_path / "models--Systran--faster-whisper-small.en" / "snapshots").mkdir(parents=True)
        assert whisper_is_cached("small.en", cache_dir=tmp_path) is False

    def test_distinct_model_ids_do_not_collide(self, tmp_path):
        self._seed(tmp_path, "small.en")
        assert whisper_is_cached("medium.en", cache_dir=tmp_path) is False


# ── no_speech_prob filtering ───────────────────────────────────────────────

class TestNoSpeechFiltering:
    def test_segment_below_threshold_is_accepted(self):
        stt = make_stt(threshold=0.6)
        seg = mock_segment("Hello!", no_speech_prob=0.1)
        stt._model.transcribe.return_value = ([seg], MagicMock())
        result = stt.transcribe(audio())
        assert result == "Hello!"

    def test_segment_at_threshold_is_rejected(self):
        """Boundary: no_speech_prob == threshold should be rejected (>= check)."""
        stt = make_stt(threshold=0.6)
        seg = mock_segment("garbage", no_speech_prob=0.6)
        stt._model.transcribe.return_value = ([seg], MagicMock())
        assert stt.transcribe(audio()) == ""

    def test_segment_above_threshold_is_rejected(self):
        stt = make_stt(threshold=0.6)
        seg = mock_segment("noise", no_speech_prob=0.9)
        stt._model.transcribe.return_value = ([seg], MagicMock())
        assert stt.transcribe(audio()) == ""

    def test_custom_threshold_respected(self):
        stt = make_stt(threshold=0.3)
        # Should be rejected at 0.4 with threshold 0.3
        seg = mock_segment("text", no_speech_prob=0.4)
        stt._model.transcribe.return_value = ([seg], MagicMock())
        assert stt.transcribe(audio()) == ""


# ── avg_logprob filtering ──────────────────────────────────────────────────

class TestLogProbFiltering:
    def test_low_confidence_segment_rejected(self):
        """avg_logprob below -1.0 indicates garbled output."""
        stt = make_stt()
        seg = mock_segment("mumble", no_speech_prob=0.1, avg_logprob=-1.5)
        stt._model.transcribe.return_value = ([seg], MagicMock())
        assert stt.transcribe(audio()) == ""

    def test_boundary_logprob_accepted(self):
        """avg_logprob exactly -1.0 is the boundary — should pass (> check, not >=)."""
        stt = make_stt()
        seg = mock_segment("boundary", no_speech_prob=0.1, avg_logprob=-1.0)
        stt._model.transcribe.return_value = ([seg], MagicMock())
        # -1.0 should be rejected (condition: avg_logprob < -1.0 → reject; so -1.0 passes)
        result = stt.transcribe(audio())
        assert result == "boundary"

    def test_high_confidence_segment_accepted(self):
        stt = make_stt()
        seg = mock_segment("Clear speech!", no_speech_prob=0.05, avg_logprob=-0.2)
        stt._model.transcribe.return_value = ([seg], MagicMock())
        assert stt.transcribe(audio()) == "Clear speech!"


# ── Multi-segment handling ─────────────────────────────────────────────────

class TestMultiSegment:
    def test_multiple_good_segments_joined(self):
        stt = make_stt()
        segs = [
            mock_segment("Hello", no_speech_prob=0.1, avg_logprob=-0.3),
            mock_segment("World", no_speech_prob=0.1, avg_logprob=-0.3),
        ]
        stt._model.transcribe.return_value = (segs, MagicMock())
        result = stt.transcribe(audio())
        assert "Hello" in result
        assert "World" in result

    def test_bad_segment_filtered_good_segment_kept(self):
        stt = make_stt()
        segs = [
            mock_segment("Good part",    no_speech_prob=0.1, avg_logprob=-0.3),
            mock_segment("garbage part", no_speech_prob=0.9, avg_logprob=-0.3),  # rejected
        ]
        stt._model.transcribe.return_value = (segs, MagicMock())
        result = stt.transcribe(audio())
        assert "Good part" in result
        assert "garbage part" not in result

    def test_empty_segment_list_returns_empty_string(self):
        stt = make_stt()
        stt._model.transcribe.return_value = ([], MagicMock())
        assert stt.transcribe(audio()) == ""

    def test_whitespace_only_segments_filtered(self):
        stt = make_stt()
        seg = mock_segment("   ", no_speech_prob=0.1, avg_logprob=-0.3)
        stt._model.transcribe.return_value = ([seg], MagicMock())
        assert stt.transcribe(audio()) == ""
