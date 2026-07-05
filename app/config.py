"""Configuration dataclasses and YAML loader for the AI Avatar Companion."""
from __future__ import annotations

import dataclasses
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional

import yaml


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _fields(cls) -> set[str]:
    """Return the set of field names for a dataclass."""
    return {f.name for f in dataclasses.fields(cls)}


def _filter(cls, data: dict) -> dict:
    """Drop dict keys that are not fields of *cls* (unknown YAML keys)."""
    return {k: v for k, v in data.items() if k in _fields(cls)}


# ---------------------------------------------------------------------------
# Leaf config sections
# ---------------------------------------------------------------------------

@dataclass
class ChildConfig:
    name: str = "Lily"
    level: str = "A"   # CEFR level: Pre A | A | B | C1 | C2


@dataclass
class PersonalityConfig:
    avatar_name: str = "Nova"
    system_prompt: str = (
        "You are {child_name}'s English-learning friend, {avatar_name}.\n"
        "- Speak in short, simple English sentences\n"
        "- Be warm, curious, and encouraging\n"
        "- Ask open-ended questions about her day\n"
        "- Keep replies under 2 sentences when possible\n"
        "- Never use complex vocabulary without explaining it\n"
        "- If she makes a mistake, naturally repeat her idea back in correct "
        "English; never point out that she was wrong\n"
        "- Never break character"
    )


@dataclass
class PrivacyConfig:
    allow_cloud_fallback: bool = False


@dataclass
class STTConfig:
    engine: str = "faster-whisper"
    model: str = "small.en"
    no_speech_threshold: float = 0.6


@dataclass
class LLMConfig:
    engine: str = "ollama"
    model: str = "llama3.2:3b"
    temperature: float = 0.7
    max_response_tokens: int = 120
    conversation_buffer_exchanges: int = 6


@dataclass
class TTSFallback:
    engine: str = ""


@dataclass
class TTSConfig:
    engine: str = "piper"
    voice: str = "en_US-lessac-medium"
    length_scale: float = 1.1
    fallback: list[TTSFallback] = field(default_factory=list)


@dataclass
class ModelsConfig:
    stt: STTConfig = field(default_factory=STTConfig)
    llm: LLMConfig = field(default_factory=LLMConfig)
    tts: TTSConfig = field(default_factory=TTSConfig)


@dataclass
class AudioConfig:
    input_device: str = ""


@dataclass
class AvatarConfig:
    model: str = "nova/live2d/nova.model3.json"
    lip_sync: str = "amplitude"


@dataclass
class SafetyConfig:
    blocklist_file: str = "./blocklist.txt"
    log_path: str = "~/.ai-avatar/logs/conversations.jsonl"
    session_limit_minutes: Optional[int] = 30


@dataclass
class AppSettings:
    window_title: str = "Nova"
    always_on_top: bool = True
    recording_key: str = "space"


# ---------------------------------------------------------------------------
# Root config
# ---------------------------------------------------------------------------

@dataclass
class Config:
    child: ChildConfig = field(default_factory=ChildConfig)
    personality: PersonalityConfig = field(default_factory=PersonalityConfig)
    privacy: PrivacyConfig = field(default_factory=PrivacyConfig)
    models: ModelsConfig = field(default_factory=ModelsConfig)
    audio: AudioConfig = field(default_factory=AudioConfig)
    avatar: AvatarConfig = field(default_factory=AvatarConfig)
    safety: SafetyConfig = field(default_factory=SafetyConfig)
    app: AppSettings = field(default_factory=AppSettings)

    def format_system_prompt(self) -> str:
        """Return the system prompt with {child_name} and {avatar_name} filled in."""
        return self.personality.system_prompt.format(
            child_name=self.child.name,
            avatar_name=self.personality.avatar_name,
        )

    @classmethod
    def load(cls, path: str = "config.yaml") -> "Config":
        """Load and validate config from a YAML file."""
        with open(path) as f:
            raw = yaml.safe_load(f) or {}

        # --- personality ---
        pers_raw = raw.get("personality", {})
        personality = PersonalityConfig(**_filter(PersonalityConfig, pers_raw))

        # --- models ---
        m = raw.get("models", {})

        tts_raw = dict(m.get("tts", {}))
        tts_fallback = [
            TTSFallback(**_filter(TTSFallback, fb))
            for fb in tts_raw.pop("fallback", [])
        ]
        tts = TTSConfig(fallback=tts_fallback, **_filter(TTSConfig, tts_raw))

        models = ModelsConfig(
            stt=STTConfig(**_filter(STTConfig, m.get("stt", {}))),
            llm=LLMConfig(**_filter(LLMConfig, m.get("llm", {}))),
            tts=tts,
        )

        return cls(
            child=ChildConfig(**_filter(ChildConfig, raw.get("child", {}))),
            personality=personality,
            privacy=PrivacyConfig(**_filter(PrivacyConfig, raw.get("privacy", {}))),
            models=models,
            audio=AudioConfig(**_filter(AudioConfig, raw.get("audio", {}))),
            avatar=AvatarConfig(**_filter(AvatarConfig, raw.get("avatar", {}))),
            safety=SafetyConfig(**_filter(SafetyConfig, raw.get("safety", {}))),
            app=AppSettings(**_filter(AppSettings, raw.get("app", {}))),
        )
