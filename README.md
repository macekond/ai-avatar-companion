# AI Avatar Companion

A local-first English-practice companion for children. A child speaks to a Live2D animated avatar that listens, thinks, and replies — all running on-device. No cloud, no accounts, no ads.

> See [`ai-avatar-companion-design.md`](ai-avatar-companion-design.md) for the full design document.

---

## How it works

```
Space held → mic records → Whisper STT → Llama 3.2 (Ollama) → Piper TTS → avatar speaks
```

The LLM streams sentences to TTS as they generate, so the first word is heard in ~1–1.5 s. A WebSocket bridge connects the Python pipeline to the browser-rendered Live2D avatar.

```
Browser (Vite + pixi-live2d-display)
  └── WebSocket ws://localhost:8765
        └── Python server (asyncio + websockets)
              ├── faster-whisper  (STT, local)
              ├── Ollama          (LLM, local)
              └── Piper TTS       (TTS, local)
```

---

## Prerequisites

| Dependency | Version | Install |
|---|---|---|
| Python | 3.11+ | [python.org](https://www.python.org) |
| Node.js | 18+ | [nodejs.org](https://nodejs.org) |
| Ollama | latest | [ollama.com](https://ollama.com) |

**macOS only** for now (uses PortAudio via sounddevice; MPS acceleration auto-detected).

---

## Setup

### 1 — Clone and create a virtual environment

```bash
git clone <repo-url>
cd ai-avatar-companion
python3 -m venv .venv
source .venv/bin/activate
```

### 2 — Install Python dependencies

```bash
pip install -r requirements.txt
```

### 3 — Pull the LLM

```bash
ollama pull llama3.2:3b
```

Make sure Ollama is running (`ollama serve`) before starting the app.

### 4 — Install frontend dependencies

```bash
cd ui && npm install && cd ..
```

### 5 — (First run only) Models download automatically

| Model | Size | When |
|---|---|---|
| Whisper `small.en` | ~500 MB | First `--voice` or `run.py` run |
| Piper `en_US-lessac-medium` | ~63 MB | First TTS use |

Both are cached to `~/.cache/` / `~/.local/share/piper/` after the initial download.

---

## Running

### Full avatar UI (Phase 3)

```bash
source .venv/bin/activate
python run.py
```

Opens `http://localhost:5173` in your browser. **Hold Space** to talk, release to send.

### CLI — voice mode (Phase 2, no browser needed)

```bash
source .venv/bin/activate
python main.py --voice
```

**Press Space** to start recording, **press Space again** to send. Useful for quick pipeline testing without the browser.

### CLI — text mode (Phase 1, for prompt tuning)

```bash
source .venv/bin/activate
python main.py
```

Type and press Enter. No mic, no TTS. Good for iterating on the system prompt.

---

## Configuration

All settings live in `config.yaml`:

```yaml
child:
  name: "Lily"          # used in the system prompt

personality:
  avatar_name: "Nova"
  system_prompt: |      # edit to tune personality and rules

models:
  stt:
    model: small.en     # try base.en (faster) or medium.en (more accurate)
    no_speech_threshold: 0.6
  llm:
    model: llama3.2:3b  # any Ollama model
    temperature: 0.7
    max_response_tokens: 120
  tts:
    voice: en_US-lessac-medium
    length_scale: 1.1   # > 1 = slower speech

audio:
  input_device: ""      # empty = OS default; e.g. "AirPods" to pin a device
```

### Optional: cloud fallback

Add API keys to `.env` (never commit this file):

```bash
cp .env.example .env
# edit .env and set ELEVENLABS_API_KEY or OPENAI_API_KEY
```

Then set `privacy.allow_cloud_fallback: true` in `config.yaml`. Audio never leaves the device regardless.

---

## Project structure

```
.
├── app/
│   ├── config.py          # typed config dataclasses + YAML loader
│   ├── server.py          # asyncio WebSocket server (Phase 3 sidecar)
│   └── pipeline/
│       ├── llm.py         # Ollama streaming → sentence iterator
│       ├── stt.py         # faster-whisper + push-to-talk recording
│       └── tts.py         # Piper synthesis + amplitude streaming
├── ui/
│   ├── index.html
│   ├── src/
│   │   ├── main.js        # state machine + Live2D + WebSocket client
│   │   └── style.css
│   └── public/
│       ├── avatar/Hiyori/ # Live2D model (placeholder for Nova)
│       └── cubism/        # Live2D Cubism Core JS
├── config.yaml            # all runtime settings
├── main.py                # CLI entry point (text + voice modes)
├── run.py                 # Phase 3 launcher (server + Vite + browser)
└── requirements.txt
```

---

## Five avatar states

| State | Trigger | Visual |
|---|---|---|
| **Idle** | Waiting for input | Breathing idle animation |
| **Listening** | Space held | Slight lean-in, label "🎤 Listening…" |
| **Thinking** | STT done, LLM generating | Eyes up, label "💭 Hmm…" |
| **Speaking** | TTS playing | Mouth driven by audio amplitude |
| **Didn't catch that** | Empty transcript | Head tilt, "I didn't hear you — try again?" |

Background colour shifts with each state.

---

## Phase plan

- ✅ **Phase 1** — Text chat, sentence-streaming LLM pipeline
- ✅ **Phase 2** — Voice loop: faster-whisper STT + Piper TTS
- ✅ **Phase 3** — Live2D avatar (Hiyori placeholder) + WebSocket bridge
- ⬜ **Phase 4** — Polish: Tauri shell, content filter, session logging, custom Nova model

---

## Licence notes

- **Live2D Cubism SDK** — free for non-commercial / free apps. Review [Live2D's licence terms](https://www.live2d.com/en/terms/cubism-sdk-release-license/) before distributing.
- **Hiyori model** — Live2D free sample data. [Sample data licence](https://www.live2d.com/en/terms/cubism-editor-free-usage/).
- All other dependencies are MIT / Apache 2.0 / BSD.
