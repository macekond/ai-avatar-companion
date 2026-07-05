# AI Avatar Companion — Design Document

> **Goal:** A simple, single-character conversation app for a child to practice English with an AI avatar. Local-first, privacy-respecting, low-latency.

---

## 1. Product Concept

A child opens the app and sees **one friendly character** sitting in front of them.
They tap the character (or press Space) to talk.
The character listens, thinks, responds verbally, and animates while speaking.

There are no menus to get lost in. No chats to scroll through.
Just: listen → talk → repeat.

---

## 2. UI Design

### 2.1 Layout

```
┌─────────────────────────────────────────┐
│                                         │
│                                         │
│                                         │
│            [  AVATAR  ]                 │
│         (large, centered)               │
│                                         │
│        😊 idle  /  🎤 listening          │
│        💭 thinking /  🔊, speaking       │
│                                         │
│                                         │
│  "Hi! What did you do today?"           │
│  (last thing the avatar said)            │
│                                         │
│        [  tap or hold space  ]           │
│                                         │
└─────────────────────────────────────────┘
```

### 2.2 States

The UI has exactly **four states**, shown both on the avatar and via a small label below:

| State | Avatar visual | Label | Appears when |
|---|---|---|---|
| **Idle** | Neutral smile, gentle breathing idle animation | "Tap to talk!" | Waiting for input |
| **Listening** | Avatar looks attentive, eyes focused, subtle lean-in | "Listening…" | Child is holding mic / Space is held |
| **Thinking** | Eyes slightly closed or looking up, subtle pause pose | "Hmm…" | STT done, LLM generating |
| **Speaking** | Full lip-sync animation, expressive gestures | *(avatar's reply shown as text)* | TTS playing |

### 2.3 Avatar Character

- **Style:** 2D, warm, illustrated — think friendly cartoon rather than realistic
- **Single model only** — no switching characters (avoids choice paralysis, keeps asset count small)
- **Built in Live2D** (or Spine) so the same rig supports all four states
- **Expressions:** idle smile, listening attentive, thinking, happy speaking — four expressions, each with looping animation

### 2.4 Controls

- **One control:** tap / click / hold `Space` = talk
- Release to stop recording and let the pipeline flow
- Nothing else to click
- Escape key: soft-stop current response, return to idle

### 2.5 Transcript Display

- After the avatar speaks, the last sentence appears in a gentle text bubble above or below the avatar
- Helps with reading comprehension, especially for language learning
- Fades out after a few seconds or on next interaction

### 2.6 Visual Style

- Soft pastel background, warm lighting feel
- Large avatar (takes ~60% of viewport height)
- Minimal chrome — no nav bars, no side panels
- Child-safe: no links, no ads, no external content

### 2.7 Window / Shell

- Single window, fixed aspect ratio (portrait 3:4 works well on screen)
- Optional: always-on-top mode, minimal title bar
- On iPad or tablet: fullscreen, no status bar intrusions

---

## 3. Backend Architecture

### 3.1 Pipeline Overview

```
┌──────────┐    ┌──────────┐    ┌──────────┐    ┌──────────┐
│  STT     │───▶│   LLM    │───▶│   TTS    │───▶│  Output  │
│ (mic)    │    │ (brain)  │    │ (voice)  │    │ (avatar) │
└──────────┘    └──────────┘    └──────────┘    └──────────┘
     ▲                                                    │
     └────────────────────────────────────────────────────┘
                    (avatar drives lip-sync from TTS)
```

All four stages run **locally**. No data leaves the machine.

### 3.2 Service Boundaries

```
app/ ← single service, no microservices
├── ui/             ← window, rendering, input handling
├── pipeline/       ← orchestrates the STT→LLM→TTS flow
│   ├── stt/
│   ├── llm/
│   └── tts/
├── avatar/         ← Live2D model, expressions, lip-sync
├── safety/         ← content filtering layer
└── config.yaml     ← voices, personality, model paths
```

### 3.3 Each Stage in Detail

#### STT (`pipeline/stt/`)

```
Interface:
  start_listening()  → begins recording
  stop_listening()   → returns transcript (str)
  
Implementation (local):
  faster-whisper small, device auto-detect (MPS on Apple Silicon)
  VAD (voice activity detection) to auto-stop on silence
  Streaming: fire partial transcript every ~1s so UI can show "I hear you…"
  
Mock (for UI dev without mic):
  returns preset transcripts from a small test list
```

#### LLM (`pipeline/llm/`)

```
Interface:
  chat(user_message, conversation_history) → assistant_message (str)
  
Implementation (local):
  Llama 3.2 3B Instruct via Ollama
  System prompt baked in at startup — defines:
    - Name, age, personality
    - Speaking style (short sentences, simple English)
    - Topic boundaries (no scary stuff, keep it light)
    - Never break character
  
  Conversation: short-term rolling buffer (last 6-8 exchanges)
  Temperature: 0.7 (slightly playful but coherent)
  Max tokens per response: 80 (keeps replies short for TTS latency)
  
  Content filter (safety/):
    - Blocked word list (child-inappropriate terms)
    - If LLM output contains a blocked word → replace with safe fallback
    - If filter fires → log it (local JSONL file) for parent review
```

#### TTS (`pipeline/tts/`)

```
Interface:
  speak(text) → yields audio chunks + phoneme timestamps
  
Implementation (local):
  Piper TTS, single warm voice (child-friendly pitch, e.g. "en_US-lessac-medium")
  Streaming synthesis: as soon as first phoneme is ready, start avatar animation
  
  Latency target: < 400ms from LLM finish to first audio frame
  
  Fallback chain:
    1. Piper (fast, offline, decent quality)
    2. XTTS v2 (slower, better quality — use if Piper unavailable)
    3. ElevenLabs API (paid cloud fallback if both local fail)
```

#### Avatar (`avatar/`)

```
Interface:
  set_state(state: idle / listening / thinking / speaking)
  drive_from_audio(audio_stream, phoneme_timestamps)
  render(window)
  
Implementation:
  Live2D model rendered via OpenGL (or WebGL if using Electron/Tauri)
  
  State machine drives expression + idle animation
  During speaking: phoneme timestamps from TTS drive mouth visemes
    (map phoneme set → 5-8 key viseme shapes, interpolate between)
  
  Synchronization:
    - TTS yields (audio_chunk, timestamp_ms) pairs
    - Avatar advances mouth shape to match
    - On audio complete → smooth transition back to idle
```

### 3.4 Safety Layer

- Runs as a transparent middleware between LLM output and TTS input
- Two filters:
  1. **Blocklist** — hard-coded terms, instant replace
  2. **Tone check** (optional, Phase 2) — lightweight classifier that flags overly complex / confusing / upsetting replies
- Everything logged to `~/.ai-avatar/logs/` for parent review
- Log format: JSONL, one object per turn, includes user text, model reply, filter action

### 3.5 Configuration

`config.yaml`:

```yaml
child:
  name: "Lily"              # used in LLM system prompt

personality:
  system_prompt: |
    You are {child_name}'s English-learning friend.
    - Speak in short, simple English sentences
    - Be warm, curious, encouraging
    - Ask open-ended questions about her day
    - Keep replies under 2 sentences when possible
    - Never use complex vocabulary without explaining it
    avatar_name: "Nova"

models:
  stt:
    engine: faster-whisper
    model: small
  llm:
    engine: ollama
    model: llama3.2:3b
    temperature: 0.7
    max_response_tokens: 80
  tts:
    engine: piper
    voice: en_US-lessac-medium
    fallback:
      - engine: xtts-v2
      - engine: elevenlabs-api   # requires API key

avatar:
  model: nova/live2d/nova.model3.json
  lip_sync_visemes: true

safety:
  blocklist_file: ./blocklist.txt
  log_path: ~/.ai-avatar/logs/conversations.jsonl

app:
  window_title: "Nova"
  always_on_top: true
  recording_key: space
```

---

## 4. Phase Plan

### Phase 1 — Working Prototype

- Text-only LLM (no TTS, no avatar, no mic yet)
- Chat window with Nova personality
- Test conversations, tune prompt, tune temperature
- Goal: good conversational quality

### Phase 2 — Voice

- Add Piper TTS
- Replace chat window with audio playback on text reply
- Voice-only: PC speaker output, no avatar yet
- Goal: < 1s latency from text reply to spoken audio

### Phase 3 — Avatar

- Add Live2D model with idle animation
- Add the 4-state state machine
- Hook TTS timestamps to lip-sync visemes
- Add recording key (Space) for voice input
- Goal: child can sit down, hold space, talk, and get a responsive avatar reply

### Phase 4 — Polish

- Content filter
- Conversation logging for parent review
- Tune blocklist, add tone check
- Package as standalone app (Tauri or Electron)

---

## 5. Open Questions

Decision needed before Phase 3:

| Question | Options | Recommendation |
|---|---|---|
| **App framework** | Tauri (Rust) / Electron (JS) / Python (PyQt/GL) | Tauri: small binary, good native/game rendering, Rust backend fits well |
| **Avatar format** | Live2D (.model3) / Spine / custom WebGL | Live2D: largest asset library, easiest to find a free child-friendly model |
| **LLM runtime** | Ollama / llama.cpp directly | Ollama: simplest API, auto-updates models, GPT-4all-style UI out of the box |

---

## 6. Tech Stack Summary

| Layer | Local | Cloud fallback |
|---|---|---|
| STT | faster-whisper (small) | OpenAI Whisper API |
| LLM | Llama 3.2 3B via Ollama | GPT-4o-mini |
| TTS | Piper (lessac-medium) | ElevenLabs |
| Avatar | Live2D | — |
| Framework | Tauri (Rust) | — |
| Logging | JSONL → parent-readable file | — |
