"""Tests for config dataclasses and YAML loading."""

import textwrap
import pytest
from app.config import (
    Config, ChildConfig, PersonalityConfig, LLMConfig, STTConfig,
    _filter, _fields,
)

FULL_YAML = textwrap.dedent("""\
    child:
      name: "TestKid"
      level: "B"
    personality:
      avatar_name: "Testy"
      system_prompt: "Hello {child_name}, I am {avatar_name}."
    privacy:
      allow_cloud_fallback: false
    models:
      stt:
        engine: faster-whisper
        model: small.en
        no_speech_threshold: 0.5
      llm:
        engine: ollama
        model: llama3.2:3b
        temperature: 0.8
        max_response_tokens: 100
        conversation_buffer_exchanges: 4
      tts:
        engine: piper
        voice: en_US-lessac-medium
        length_scale: 1.2
        fallback:
          - engine: xtts-v2
    audio:
      input_device: "AirPods"
    safety:
      blocklist_file: ./blocklist.txt
      log_path: ~/.ai-avatar/logs/conversations.jsonl
    app:
      window_title: "Testy"
      always_on_top: false
      recording_key: space
""")


@pytest.fixture
def config_file(tmp_path):
    f = tmp_path / "config.yaml"
    f.write_text(FULL_YAML)
    return str(f)


# ── _filter helper ─────────────────────────────────────────────────────────

class TestFilter:
    def test_known_keys_pass_through(self):
        result = _filter(ChildConfig, {"name": "Alice", "level": "A"})
        assert result == {"name": "Alice", "level": "A"}

    def test_unknown_keys_are_silently_dropped(self):
        result = _filter(ChildConfig, {"name": "Alice", "future_key": "oops"})
        assert "future_key" not in result
        assert result["name"] == "Alice"

    def test_empty_dict_returns_empty(self):
        assert _filter(ChildConfig, {}) == {}

    def test_only_unknown_keys_returns_empty(self):
        result = _filter(ChildConfig, {"completely_unknown": True})
        assert result == {}


# ── ChildConfig defaults ───────────────────────────────────────────────────

class TestChildConfig:
    def test_default_level_is_a(self):
        c = ChildConfig()
        assert c.level == "A"

    def test_default_name(self):
        c = ChildConfig()
        assert c.name == "Lily"

    def test_custom_level(self):
        c = ChildConfig(name="Alice", level="C1")
        assert c.level == "C1"
        assert c.name == "Alice"


# ── Config.load ────────────────────────────────────────────────────────────

class TestConfigLoad:
    def test_loads_child_name(self, config_file):
        config = Config.load(config_file)
        assert config.child.name == "TestKid"

    def test_loads_child_level(self, config_file):
        config = Config.load(config_file)
        assert config.child.level == "B"

    def test_loads_avatar_name(self, config_file):
        config = Config.load(config_file)
        assert config.personality.avatar_name == "Testy"

    def test_loads_stt_threshold(self, config_file):
        config = Config.load(config_file)
        assert config.models.stt.no_speech_threshold == 0.5

    def test_loads_llm_temperature(self, config_file):
        config = Config.load(config_file)
        assert config.models.llm.temperature == 0.8

    def test_loads_llm_buffer_exchanges(self, config_file):
        config = Config.load(config_file)
        assert config.models.llm.conversation_buffer_exchanges == 4

    def test_loads_tts_length_scale(self, config_file):
        config = Config.load(config_file)
        assert config.models.tts.length_scale == 1.2

    def test_loads_tts_fallback_list(self, config_file):
        config = Config.load(config_file)
        assert len(config.models.tts.fallback) == 1
        assert config.models.tts.fallback[0].engine == "xtts-v2"

    def test_loads_audio_input_device(self, config_file):
        config = Config.load(config_file)
        assert config.audio.input_device == "AirPods"

    def test_loads_app_always_on_top(self, config_file):
        config = Config.load(config_file)
        assert config.app.always_on_top is False

    def test_unknown_yaml_keys_ignored(self, tmp_path):
        yaml = FULL_YAML + "\nsome_future_feature: true\n"
        f = tmp_path / "config.yaml"
        f.write_text(yaml)
        config = Config.load(str(f))   # must not raise
        assert config.child.name == "TestKid"

    def test_missing_optional_keys_use_defaults(self, tmp_path):
        minimal = "child:\n  name: \"Alice\"\n"
        f = tmp_path / "config.yaml"
        f.write_text(minimal)
        config = Config.load(str(f))
        assert config.child.level == "A"           # default
        assert config.models.llm.temperature == 0.7  # default
        assert config.privacy.allow_cloud_fallback is False  # default


# ── format_system_prompt ───────────────────────────────────────────────────

class TestFormatSystemPrompt:
    def test_substitutes_child_name(self, config_file):
        config = Config.load(config_file)
        prompt = config.format_system_prompt()
        assert "TestKid" in prompt
        assert "{child_name}" not in prompt

    def test_substitutes_avatar_name(self, config_file):
        config = Config.load(config_file)
        prompt = config.format_system_prompt()
        assert "Testy" in prompt
        assert "{avatar_name}" not in prompt

    def test_both_placeholders_replaced(self, tmp_path):
        yaml = textwrap.dedent("""\
            child:
              name: "Mia"
            personality:
              avatar_name: "Spark"
              system_prompt: "Hi {child_name}! I am {avatar_name}."
        """)
        f = tmp_path / "config.yaml"
        f.write_text(yaml)
        config = Config.load(str(f))
        prompt = config.format_system_prompt()
        assert prompt == "Hi Mia! I am Spark."
