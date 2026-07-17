"""Tests for the Settings panel backend: voice list, set_voice, persistence."""
from __future__ import annotations

import json
from unittest.mock import MagicMock, patch

import numpy as np
import pytest

from app.memory import ChildMemory, ChildProfile, MemoryManager
from app.pipeline.llm import LLMPipeline
from app.pipeline.stt import STTPipeline
from app.pipeline.tts import TTSPipeline
from app.server import _session, AVAILABLE_VOICES, _VOICE_IDS
from tests.conftest import MockWebSocket, make_fake_recorder


DUMMY_AUDIO = np.zeros(16_000, dtype=np.float32)


def _mock_stt() -> MagicMock:
    stt = MagicMock(spec=STTPipeline)
    stt.transcribe.return_value = "hello"
    return stt


def _mock_llm() -> MagicMock:
    llm = MagicMock(spec=LLMPipeline)
    llm.chat.side_effect = lambda _t: iter(["Hi!"])
    return llm


def _mock_tts(reload_ok: bool = True, current: str = "en_US-kristin-medium",
              language: str = "en") -> MagicMock:
    tts = MagicMock(spec=TTSPipeline)
    tts.reload_voice.return_value = reload_ok
    # spec=TTSPipeline exposes current_voice/language as properties; set them so
    # _configure_active() sees "already on this voice+language" and doesn't fire
    # a spurious connect-time reload (which would double the reload count).
    type(tts).current_voice = property(lambda self: current)
    type(tts).language = property(lambda self: language)
    tts.speak_streaming.side_effect = lambda t, cb=None, stop=None: cb(0.0) if cb else None
    return tts


@pytest.fixture(autouse=True)
def _no_mic():
    with patch("app.server._MicRecorder",
               return_value=make_fake_recorder(DUMMY_AUDIO)):
        yield


# ── on-connect settings message ────────────────────────────────────────────

class TestSettingsOnConnect:
    async def test_settings_message_sent_with_voices_and_level(self, base_config):
        ws = MockWebSocket([])
        await _session(ws, base_config, _mock_stt(), _mock_llm(), _mock_tts())
        s = ws.sent_of_type("settings")
        assert len(s) == 1
        # Per-language now: the active language plus its levels + voices.
        assert s[0]["language"] == "en"
        assert s[0]["voices"] == AVAILABLE_VOICES["en"]
        assert s[0]["level"] == base_config.child.level
        assert s[0]["levels"] == ["Pre A", "A", "B", "C1", "C2"]
        assert "ja" in s[0]["languages"]
        assert "voice" in s[0]

    async def test_voice_list_only_permissive_licenses(self):
        # Strict allowlist: every shipped English voice must be public-domain/CC0.
        # Adding any voice here without confirming its license fails the test.
        # Verified licenses (rhasspy/piper-voices MODEL_CARD):
        #   kristin  public domain   ljspeech public domain
        #   joe      CC0             norman   public domain
        PERMISSIVE = {
            "en_US-kristin-medium",
            "en_US-ljspeech-medium",
            "en_US-joe-medium",
            "en_US-norman-medium",
        }
        ids = {v["id"] for v in AVAILABLE_VOICES["en"]}
        assert ids <= PERMISSIVE, f"unvetted voice(s): {ids - PERMISSIVE}"
        # lessac is Blizzard-licensed (research only) — must never return.
        assert "en_US-lessac-medium" not in ids

    async def test_japanese_voices_are_kokoro(self):
        # Japanese voices are Kokoro (Apache-2.0) ids, not Piper ja_JP-* ids.
        ids = {v["id"] for v in AVAILABLE_VOICES["ja"]}
        assert ids == {"jf_alpha", "jf_gongitsune", "jf_nezumi", "jm_kumo"}


# ── set_voice handler ──────────────────────────────────────────────────────

class TestSetVoice:
    async def test_valid_voice_triggers_reload(self, base_config):
        ws = MockWebSocket([json.dumps({"type": "set_voice",
                                        "voice": "en_US-joe-medium"})])
        # Mock reports it's already on the config default (kristin/en) so the
        # connect-time _configure_active() doesn't add a reload — set_voice is
        # then the only reload call.
        tts = _mock_tts(reload_ok=True)
        with patch("app.server.voice_is_cached", return_value=True):
            await _session(ws, base_config, _mock_stt(), _mock_llm(), tts)
        # Voice reload now carries the active language so the backend routes
        # correctly (Piper for en, Kokoro for ja).
        tts.reload_voice.assert_called_once_with("en_US-joe-medium", "en")
        statuses = ws.sent_of_type("voice_status")
        assert statuses[0]["state"] == "loading"
        assert statuses[-1]["state"] == "ready"

    async def test_valid_voice_persists_to_profile(self, base_config, tmp_path):
        # Voice is per-profile now (voices are language-scoped): the chosen id
        # lands on the child's profile file, not global settings.json.
        profiles_dir = tmp_path / "profiles"
        profiles_dir.mkdir()
        base_config.memory.profiles_dir = str(profiles_dir)
        mem_mgr = MemoryManager(profiles_dir, "lily")
        mem_mgr.save(ChildMemory(profile=ChildProfile(name="Lily", language="en")))

        ws = MockWebSocket([json.dumps({"type": "set_voice",
                                        "voice": "en_US-joe-medium"})])
        tts = _mock_tts(reload_ok=True, current="en_US-joe-medium")
        with patch("app.server.voice_is_cached", return_value=True):
            await _session(ws, base_config, _mock_stt(), _mock_llm(), tts, mem_mgr)
        assert MemoryManager(profiles_dir, "lily").load().profile.voice == "en_US-joe-medium"

    async def test_cached_voice_reports_loading(self, base_config):
        ws = MockWebSocket([json.dumps({"type": "set_voice",
                                        "voice": "en_US-joe-medium"})])
        tts = _mock_tts(reload_ok=True, current="en_US-joe-medium")
        with patch("app.server.voice_is_cached", return_value=True):
            await _session(ws, base_config, _mock_stt(), _mock_llm(), tts)
        assert ws.sent_of_type("voice_status")[0]["state"] == "loading"

    async def test_uncached_voice_reports_downloading(self, base_config):
        ws = MockWebSocket([json.dumps({"type": "set_voice",
                                        "voice": "en_US-norman-medium"})])
        tts = _mock_tts(reload_ok=True, current="en_US-norman-medium")
        with patch("app.server.voice_is_cached", return_value=False):
            await _session(ws, base_config, _mock_stt(), _mock_llm(), tts)
        statuses = ws.sent_of_type("voice_status")
        assert statuses[0]["state"] == "downloading"
        assert statuses[-1]["state"] == "ready"

    async def test_unknown_voice_ignored(self, base_config):
        ws = MockWebSocket([json.dumps({"type": "set_voice",
                                        "voice": "../evil"})])
        tts = _mock_tts()
        await _session(ws, base_config, _mock_stt(), _mock_llm(), tts)
        tts.reload_voice.assert_not_called()
        assert ws.sent_of_type("voice_status") == []

    async def test_reload_failure_reports_error(self, base_config, tmp_path):
        # A failed reload must not persist the voice onto the profile.
        profiles_dir, mem_mgr = _profile(tmp_path, base_config, language="en")
        ws = MockWebSocket([json.dumps({"type": "set_voice",
                                        "voice": "en_US-norman-medium"})])
        tts = _mock_tts(reload_ok=False, current="en_US-kristin-medium")
        await _session(ws, base_config, _mock_stt(), _mock_llm(), tts, mem_mgr)
        assert MemoryManager(profiles_dir, "lily").load().profile.voice == ""
        assert ws.sent_of_type("voice_status")[-1]["state"] == "error"


# ── set_level now persists ─────────────────────────────────────────────────

class TestLevelPersistence:
    async def test_set_level_persists_to_profile(self, base_config, tmp_path):
        # Level is per-profile now: set_level writes the child's profile file.
        profiles_dir = tmp_path / "profiles"
        profiles_dir.mkdir()
        base_config.memory.profiles_dir = str(profiles_dir)
        mem_mgr = MemoryManager(profiles_dir, "lily")
        mem_mgr.save(ChildMemory(profile=ChildProfile(name="Lily",
                                                       language="en", level="A")))
        ws = MockWebSocket([json.dumps({"type": "set_level", "level": "C1"})])
        await _session(ws, base_config, _mock_stt(), _mock_llm(), _mock_tts(), mem_mgr)
        assert MemoryManager(profiles_dir, "lily").load().profile.level == "C1"

    async def test_out_of_taxonomy_level_ignored(self, base_config, tmp_path):
        # A JLPT level for an English profile must be rejected (would blank the
        # level prompt), leaving the stored level unchanged.
        profiles_dir = tmp_path / "profiles"
        profiles_dir.mkdir()
        base_config.memory.profiles_dir = str(profiles_dir)
        mem_mgr = MemoryManager(profiles_dir, "lily")
        mem_mgr.save(ChildMemory(profile=ChildProfile(name="Lily",
                                                      language="en", level="A")))
        ws = MockWebSocket([json.dumps({"type": "set_level", "level": "N5"})])
        llm = _mock_llm()
        await _session(ws, base_config, _mock_stt(), llm, _mock_tts(), mem_mgr)
        assert MemoryManager(profiles_dir, "lily").load().profile.level == "A"
        llm.set_level.assert_not_called()


# ── set_language handler ────────────────────────────────────────────────────

def _profile(tmp_path, base_config, slug="lily", **kw):
    profiles_dir = tmp_path / "profiles"
    profiles_dir.mkdir(exist_ok=True)
    base_config.memory.profiles_dir = str(profiles_dir)
    mgr = MemoryManager(profiles_dir, slug)
    mgr.save(ChildMemory(profile=ChildProfile(name=slug.title(), **kw)))
    return profiles_dir, mgr


class TestSetLanguage:
    async def test_switch_to_japanese_resets_level_and_reconfigures(
            self, base_config, tmp_path):
        profiles_dir, mem_mgr = _profile(tmp_path, base_config,
                                         language="en", level="B")
        ws = MockWebSocket([json.dumps({"type": "set_language", "language": "ja"})])
        llm = _mock_llm()
        tts = _mock_tts()
        await _session(ws, base_config, _mock_stt(), llm, tts, mem_mgr)

        prof = MemoryManager(profiles_dir, "lily").load().profile
        assert prof.language == "ja"
        assert prof.level == "N5"          # reset to the JLPT default
        assert prof.voice == ""            # reset to language default
        llm.set_language_level.assert_any_call("ja", "N5")
        assert any(c.args[1] == "ja" for c in tts.reload_voice.call_args_list)
        s = ws.sent_of_type("settings")[-1]
        assert s["language"] == "ja"
        assert s["levels"] == ["N5", "N4", "N3", "N2", "N1"]

    async def test_unknown_language_ignored(self, base_config, tmp_path):
        profiles_dir, mem_mgr = _profile(tmp_path, base_config, language="en")
        ws = MockWebSocket([json.dumps({"type": "set_language", "language": "zz"})])
        await _session(ws, base_config, _mock_stt(), _mock_llm(), _mock_tts(), mem_mgr)
        assert MemoryManager(profiles_dir, "lily").load().profile.language == "en"


class TestJapaneseProfile:
    async def test_connect_configures_pipeline_for_japanese(
            self, base_config, tmp_path):
        _, mem_mgr = _profile(tmp_path, base_config, slug="yuki",
                              language="ja", level="N4")
        ws = MockWebSocket([])
        llm = _mock_llm()
        tts = _mock_tts()
        await _session(ws, base_config, _mock_stt(), llm, tts, mem_mgr)
        # LLM + TTS both configured for Japanese on connect.
        llm.set_language_level.assert_any_call("ja", "N4")
        assert any(c.args[1] == "ja" for c in tts.reload_voice.call_args_list)
        s = ws.sent_of_type("settings")[-1]
        assert s["language"] == "ja"
        assert s["voice"] in {"jf_alpha", "jf_gongitsune", "jf_nezumi", "jm_kumo"}

    async def test_transcript_replay_gets_furigana_html_for_ja(
            self, base_config, tmp_path):
        # A Japanese profile's stored conversation must be replayed with
        # furigana HTML alongside the plain text — else the panel shows raw
        # kanji at N5 where the child can't read it yet.
        from app.transcript import TranscriptStore
        _, mem_mgr = _profile(tmp_path, base_config, slug="yuki",
                              language="ja", level="N5")
        transcripts_dir = tmp_path / "transcripts"
        transcripts_dir.mkdir(exist_ok=True)
        store = TranscriptStore(transcripts_dir, "yuki")
        store.append_turn(1, "ねこがすきです", "私もねこがすき！")

        # Point base_config at the tmp profiles dir so _session finds our
        # transcript store beside profiles/.
        base_config.memory.profiles_dir = str(tmp_path / "profiles")
        ws = MockWebSocket([])
        await _session(ws, base_config, _mock_stt(), _mock_llm(), _mock_tts(), mem_mgr)

        turns = ws.sent_of_type("conversation_turn")
        assert turns, "no conversation_turn replayed"
        t = turns[0]
        assert t["you"] == "ねこがすきです"
        assert t["nova"] == "私もねこがすき！"
        # Furigana html sits alongside plain text. Because pyopenjtalk may not
        # be installed in CI (imports lazily and falls back), the html field
        # may equal the escaped plain text; the invariant we pin is only that
        # the key is PRESENT for a JA profile — the UI's fallback code path
        # then handles either richness.
        assert "nova_html" in t, "nova_html missing on JA profile"
        assert "you_html" in t, "you_html missing on JA profile"

    async def test_english_profile_gets_no_furigana_fields(
            self, base_config, tmp_path):
        # English replay must NOT carry html fields — that would be dead
        # weight over the wire and confuse the UI's html/text branch.
        from app.transcript import TranscriptStore
        _, mem_mgr = _profile(tmp_path, base_config, slug="lily", language="en")
        transcripts_dir = tmp_path / "transcripts"
        transcripts_dir.mkdir(exist_ok=True)
        store = TranscriptStore(transcripts_dir, "lily")
        store.append_turn(1, "I like cats", "Me too!")
        base_config.memory.profiles_dir = str(tmp_path / "profiles")
        ws = MockWebSocket([])
        await _session(ws, base_config, _mock_stt(), _mock_llm(), _mock_tts(), mem_mgr)
        turns = ws.sent_of_type("conversation_turn")
        assert turns
        t = turns[0]
        assert "nova_html" not in t
        assert "you_html" not in t


class TestModalProfileCreation:
    async def test_switch_with_language_creates_and_skips_onboarding(
            self, base_config, tmp_path):
        profiles_dir, mem_mgr = _profile(tmp_path, base_config, slug="lily")
        ws = MockWebSocket([json.dumps({
            "type": "switch_profile", "slug": "yuki",
            "language": "ja", "level": "N4",
        })])
        await _session(ws, base_config, _mock_stt(), _mock_llm(), _mock_tts(), mem_mgr)
        created = MemoryManager(profiles_dir, "yuki").load()
        assert created is not None
        assert created.profile.language == "ja"
        assert created.profile.level == "N4"
        assert created.profile.name == "yuki"
        # Parent typed the name + picked language/level → no spoken onboarding.
        assert ws.sent_of_type("onboarding_start") == []

    async def test_new_kid_appears_in_final_profiles_message(
            self, base_config, tmp_path):
        # Regression pin (reported bug: "created a new kid, but it is not
        # visible"): every 'profiles' broadcast sent DURING or AFTER the create
        # flow must list the new slug — a stale list means the chip can't
        # render and the child disappears from the picker.
        _, mem_mgr = _profile(tmp_path, base_config, slug="lily")
        ws = MockWebSocket([json.dumps({
            "type": "switch_profile", "slug": "yuki",
            "language": "ja", "level": "N5",
        })])
        await _session(ws, base_config, _mock_stt(), _mock_llm(), _mock_tts(), mem_mgr)

        profiles_msgs = ws.sent_of_type("profiles")
        assert profiles_msgs, "no profiles message sent"
        # The last profiles message must include the newly-created child,
        # otherwise the UI never renders their chip.
        assert "yuki" in profiles_msgs[-1]["list"]
        assert profiles_msgs[-1]["active"] == "yuki"

    async def test_switch_without_language_still_onboards(
            self, base_config, tmp_path):
        profiles_dir, mem_mgr = _profile(tmp_path, base_config, slug="lily")
        ws = MockWebSocket([json.dumps({"type": "switch_profile", "slug": "newkid"})])
        # No mic input queued after → onboarding's first _await_ptt drains and
        # the session ends; we only assert onboarding was entered.
        await _session(ws, base_config, _mock_stt(), _mock_llm(), _mock_tts(), mem_mgr)
        assert ws.sent_of_type("onboarding_start") != []
