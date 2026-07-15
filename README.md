# AI Avatar Companion

A local-first English-practice companion for children. A child speaks to an animated 3D avatar that listens, thinks, and replies — all running on-device. No cloud, no accounts, no ads.

> See [`ai-avatar-companion-design.md`](ai-avatar-companion-design.md) for the full design document.

---

## How it works

```
Space held → mic records → Whisper STT → Llama 3.2 (Ollama) → Piper TTS → avatar speaks
```

The LLM streams sentences to TTS as they generate, so the first word is heard in ~1–1.5 s. A WebSocket bridge connects the Python pipeline to the browser-rendered VRM avatar.

```
Browser (Vite + three.js + @pixiv/three-vrm)
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
| Piper `en_US-kristin-medium` | ~63 MB | First TTS use |

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
    voice: en_US-kristin-medium   # changeable in the Settings panel
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

## Settings

Tap the ⚙ gear (top-right) to open the settings panel:

- **Kid** — switch between child profiles, add a new one, or remove one (tap the ✕ next to a name). Each child has its own memory; the last remaining profile can't be removed.
- **Voice** — change the Piper voice; it reloads live (no restart) and is remembered.
- **English level** — Pre A / A / B / C1 / C2, adjusts vocabulary and correction intensity.

Voice and level are persisted to `~/.ai-avatar/settings.json` and applied on the next launch, so they survive restarts without editing `config.yaml`.

Tap the 📝 button (top-right) to open the **Conversation** panel — a running transcript of the session where each grammar fix is shown inline (e.g. ~~goed~~ → **went** *(past tense)*), so a parent or child can review what was gently corrected.

Nova also knows what she looks like — ask "what colour is your hair?" or "are you a boy?" and she answers in character, grounded in the avatar on screen.

Only permissively-licensed voices (public domain / CC0) are offered — see [Licence notes](#licence-notes).

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
│   │   ├── main.js        # state machine + three-vrm avatar + WebSocket client
│   │   └── style.css
│   └── public/
│       └── avatar/*.vrm   # VRM avatar models (VIPE Hero default)
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
- ✅ **Phase 3** — VRM avatar (three-vrm) + WebSocket bridge
- 🔶 **Phase 4** — Polish: ✅ Tauri shell / macOS bundle · ✅ settings panel (kid / voice / level) · ⬜ content filter, session limits, custom Nova model

---

## Building the macOS app (DMG)

One-time prerequisites:

```bash
xcode-select --install                                   # Apple CLT
curl --proto '=https' -sSf https://sh.rustup.rs | sh     # Rust toolchain
python3 -m venv .venv && .venv/bin/pip install -r requirements-dev.txt
npm --prefix ui install
```

Build:

```bash
make bundle
# → src-tauri/target/aarch64-apple-darwin/release/bundle/dmg/Nova_<version>_aarch64.dmg
```

The pipeline: `vite build` → PyInstaller freezes the Python server into a
sidecar binary → Tauri bundles both into `Nova.app` and packs a DMG.

Notes for recipients (Apple Silicon Macs only):

- The app is **ad-hoc signed** — the first launch needs right-click → Open
  (or `xattr -dr com.apple.quarantine /Applications/Nova.app`).
- **Ollama** must be installed separately from [ollama.com](https://ollama.com)
  with `ollama pull llama3.2:3b`. Nova shows a friendly setup screen until
  it's available.
- First launch downloads ~600 MB of voice models; later launches are offline.
- Config lives at `~/.ai-avatar/config.yaml` (seeded on first run); profiles
  and logs under `~/.ai-avatar/`.

---

## Licence notes

**Avatar (VRM):**
- **three.js / @pixiv/three-vrm** — MIT.
- **Default model — VIPE Hero #2707** ([Open Source Avatars](https://www.opensourceavatars.com/en/finder?avatar=vipe-hero-2707)) — **CC-BY**: free to use, modify, and redistribute *with attribution*. Attribution: *VIPE Heroes Genesis by VIPE ([vipe.io](https://vipe.io)), via opensourceavatars.com (ToxSam).*
- **Alternative — `Olivia.vrm`** (100 Avatars #056 by Polygonal Mind, via [Open Source Avatars](https://www.opensourceavatars.com/)) — **CC0** (verified in the file's own VRM metadata): public domain, free to use, modify, and redistribute, no attribution required.

**Voice (Piper):**
- **Piper engine** (`piper-tts`) — **GPL-3.0-or-later**. Bundling it in the distributed app makes the app carry GPL obligations; fine for this open-source project.
- **Shipped voices** are all permissively licensed: `kristin`, `ljspeech`, `norman` (public domain, LibriVox / LJ-Speech) and `joe` (CC0). The Blizzard-licensed `en_US-lessac` (research-use-only) is deliberately **not** offered.

**Everything else** — faster-whisper, Ollama client, websockets, etc. — is MIT / Apache 2.0 / BSD.

---

## Contributing

Contributions are welcome! A few notes:

- Run the tests before opening a PR: `.venv/bin/python -m pytest -q` (offline, no hardware needed — see [TESTING.md](TESTING.md)).
- Keep the local-first, privacy-first design: no telemetry leaves the device, audio never goes to the cloud.
- The UI avatar layer is intentionally not unit-tested (browser WebGL); verify visual changes manually via `python run.py`.
- Please describe *why* a change is needed, not just *what* it does.

Found a security issue? See [SECURITY.md](SECURITY.md) — don't file it as a public issue.

---

## Licence

This project is licensed under the **GNU General Public License v3.0** — see [LICENSE](LICENSE).

GPL-3.0 is used because the bundled Piper TTS engine is GPL-3.0-or-later, so
the distributed application is a combined GPL work. Third-party components
(avatar model, voices, ML libraries) retain their own licences as listed in
[Licence notes](#licence-notes) above.
