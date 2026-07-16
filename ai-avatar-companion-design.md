# AI Avatar Companion — Design Document

> ⚠️ **Historical snapshot — records the original intent, not the current system.**
> Kept for the *why* behind the product decisions, which still holds. The *how* has
> moved on: this document describes a Live2D/Cubism avatar stack that was replaced by
> VRM (three.js + @pixiv/three-vrm) because Cubism Core is proprietary and can't ship
> in an open-source repo — so its avatar, licensing, and file-layout sections are
> superseded. For how the system works today: [README](README.md) for the pipeline,
> `app/server.py`'s module docstring for the WebSocket protocol, [CLAUDE.md](CLAUDE.md)
> for cross-file invariants, and [TESTING.md](TESTING.md) for the test strategy.

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

The UI has exactly **five states**, shown both on the avatar and via a small label below:

| State | Avatar visual | Label | Appears when |
|---|---|---|---|
| **Idle** | Neutral smile, gentle breathing idle animation | "Tap to talk!" | Waiting for input |
| **Listening** | Avatar looks attentive, eyes focused, subtle lean-in | "Listening…" | Child is holding mic / Space is held |
| **Thinking** | Eyes slightly closed or looking up, subtle pause pose | "Hmm…" | STT done, LLM generating |
| **Speaking** | Mouth animation, expressive gestures | *(avatar's reply shown as text)* | TTS playing |
| **Didn't catch that** | Friendly puzzled head-tilt | "I didn't hear you — try again?" | STT returned nothing usable, or a pipeline stage failed |

The last state matters more than it looks: a child speaking non-native English into local STT
will produce empty or garbage transcripts *often*. It must feel like a friendly shrug, never an error.
The same pose (different label, e.g. "My brain is napping…") covers backend failures such as Ollama not running.

### 2.3 Avatar Character

- **Style:** 2D, warm, illustrated — think friendly cartoon rather than realistic
- **Single model only** — no switching characters (avoids choice paralysis, keeps asset count small)
- **Built in Live2D** (or Spine) so the same rig supports all five states
- **Expressions:** idle smile, listening attentive, thinking, happy speaking, friendly-puzzled — five expressions, each with looping animation

### 2.4 Controls

- **One control:** tap / click / hold `Space` = talk
- Release to stop recording and let the pipeline flow
- **Push-to-talk only in v1** — recording starts on press, ends on release. No VAD auto-stop
  (explicit and predictable for a child; hands-free VAD mode is a possible future addition)
- **Barge-in:** pressing Space while the avatar is speaking or thinking always interrupts —
  TTS stops immediately and the app transitions to listening. Kids will do this constantly.
- Nothing else to click
- Escape key: soft-stop current response, return to idle

### 2.5 Transcript Display

- After the avatar speaks, the last sentence appears in a gentle text bubble above or below the avatar
- Helps with reading comprehension, especially for language learning
- Fades out after a few seconds or on next interaction
- **Also show what the app heard:** after the child speaks, briefly flash the recognized
  transcript ("You said: …"). She sees her own English in writing, and mishears become
  visible instead of confusing.

### 2.6 Visual Style

- Soft pastel background, warm lighting feel
- Large avatar (takes ~60% of viewport height)
- Minimal chrome — no nav bars, no side panels
- Child-safe: no links, no ads, no external content

### 2.7 Window / Shell

- Single window, fixed aspect ratio (portrait 3:4 works well on screen)
- Optional: always-on-top mode, minimal title bar
- On iPad or tablet: fullscreen, no status bar intrusions

### 2.8 First-Run & Startup

The app has three startup phases on every launch; the UI reflects each one so the child (or parent) is never left staring at a blank screen.

**Phase A — Prerequisite check** (< 1 s, silent on success):
- Is Ollama reachable at `localhost:11434`? → if not: show *Setup screen* (see below)
- Is `llama3.2:3b` already pulled in Ollama? → if not: offer to pull it
- Are STT and TTS model files present on disk? → if not: trigger Phase B download

**Phase B — Model download** (first run only; skipped on subsequent launches):
- Per-model progress bars (STT model ~240 MB, LLM ~2 GB, TTS voice ~60 MB) with estimated time remaining
- Progress is polled from the Python sidecar; the Tauri webview updates without blocking
- Cancellable and resumable: Ollama pull is checkpointed; STT/TTS files use HTTP range requests
- After all assets are present: proceeds to Phase C automatically

**Phase C — Model warm-up** (5–15 s, every launch):
- Avatar shown in a dim, sleepy state with label *"Nova is waking up…"*
- Python sidecar sends a minimal no-op prompt to the LLM and discards the reply
- When the first token arrives: warm-up is complete → transition to Idle state
- The first real reply may still be 1–2 s slower than subsequent ones (model paging into GPU memory);
  a `cold_start: true` flag is written into the first JSONL log turn for latency debugging

**Setup screen** (shown when Phase A fails):
- Friendly illustration — no error codes or terminal output visible to the child
- Text: *"Nova needs Ollama to think. Please open Ollama and tap 'Try again'."*
- Single *"Try again"* button that re-runs Phase A
- A bundled `setup-guide.html` (local file, no internet required) explains Ollama installation
  in plain language; linked from this screen for the parent

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

All four stages run **locally by default**. Cloud fallbacks exist for LLM and TTS but are
**off by default and require explicit parent opt-in** in config. Raw audio **never** leaves
the machine under any setting — the child's voice is the one thing with no cloud path.

**End-to-end latency budget** (release Space → first audio heard), the number that actually
matters for a child's attention:

```
STT finalize transcript      ≤ 400 ms
LLM first sentence ready     ≤ 700 ms   (streamed — see below)
TTS first audio frame        ≤ 400 ms
─────────────────────────────────────
Total target                 ≤ 1.5 s
```

The key trick: the LLM **streams sentences** to TTS. The avatar starts speaking the first
sentence while the rest of the reply is still generating, so perceived latency is
time-to-first-sentence, not time-to-full-reply.

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
  faster-whisper small.en (or distil-whisper), device auto-detect (MPS on Apple Silicon)
  Recording window = while Space is held (push-to-talk; no VAD in v1)
  Streaming: fire partial transcript every ~1s so UI can show "I hear you…"
  Empty / low-confidence transcript → "didn't catch that" state, never a silent failure

  ⚠ Known risk: Whisper is measurably weaker on children's speech, and weaker again on
  non-native accents. Test with the actual child's voice EARLY (Phase 2 exit criterion).
  If small.en isn't good enough, try medium before reaching for anything exotic.

Mock (for UI dev without mic):
  returns preset transcripts from a small test list

Audio edge cases:

  Mic device:
    Default: OS default input device — works for built-in mic and most headsets.
    If multiple devices are present and the default is wrong, config.yaml accepts an
    optional audio.input_device key (substring-matched against system device names,
    e.g. "AirPods"). No in-app selector UI — device choice is a parent-level concern.

  Ambient noise / confidence:
    Whisper returns per-segment no_speech_prob. If no_speech_prob > 0.6 for the full
    recording, treat the result as empty → trigger "didn't catch that" instead of
    forwarding garbage text to the LLM. Threshold tunable via stt.no_speech_threshold
    in config. Background TV and music are the primary risk; test at the child's real
    environment in Phase 2 — this is easier to tune empirically than to predict.

  Echo during barge-in:
    When Space is pressed mid-TTS, the mic opens while the speaker is still audible
    for ~50–100 ms. Without cancellation, Whisper may transcribe the avatar's own voice.
    Mitigation layers (apply in order; stop when the problem is solved):
      1. Hard-stop audio playback before the mic opens — introduce a deliberate ~50 ms
         silent gap on every barge-in press so the speaker has settled
      2. Check whether OS-level AEC (acoustic echo cancellation) is already active —
         on macOS and Windows it is on by default via the system audio stack; verify
         this before implementing any software AEC
      3. Fallback: discard any transcript with Levenshtein similarity > 0.8 to the
         avatar's last utterance (cheap string check, catches verbatim echo)
```

#### LLM (`pipeline/llm/`)

```
Interface:
  chat(user_message, conversation_history) → yields sentences (streaming)

  Streaming, not blocking: tokens stream from Ollama, the pipeline cuts at each
  sentence boundary and hands the sentence onward (safety filter → TTS) while
  generation continues. This is the single biggest latency win in the whole app.

Implementation (local):
  Llama 3.2 3B Instruct via Ollama
  System prompt baked in at startup — defines:
    - Name, age, personality
    - Speaking style (short sentences, simple English)
    - Topic boundaries (no scary stuff, keep it light)
    - Gentle recasting: repeat the child's idea back in correct English naturally;
      NEVER say "that's wrong" or explicitly correct grammar
    - Never break character
  
  Conversation: short-term rolling buffer (last 6-8 exchanges)
  Temperature: 0.7 (slightly playful but coherent)
  Max tokens per response: 120, then trim to the last complete sentence before TTS
  (prompt for brevity; a hard 80-token cap chops replies mid-sentence)
  
  Content filter (safety/):
    - Blocked word list (child-inappropriate terms)
    - If LLM output contains a blocked word → replace with safe fallback
    - If filter fires → log it (local JSONL file) for parent review
```

#### TTS (`pipeline/tts/`)

```
Interface:
  speak(text) → yields audio chunks
  (no phoneme-timestamp contract — lip-sync is amplitude-driven, see Avatar below)

Implementation (local):
  Piper TTS, single warm voice (child-friendly pitch, e.g. "en_US-lessac-medium")
  length_scale slightly > 1.0 — a touch slower than native speed, for a learner
  Streaming synthesis: called per-sentence as the LLM streams; start audio
  (and avatar mouth) as soon as the first chunk is ready

  Latency target: < 400ms from first sentence available to first audio frame
  
  Fallback chain:
    1. Piper (fast, offline, decent quality)
    2. XTTS v2 (slower, better quality — use if Piper unavailable)
    3. ElevenLabs API — cloud, OFF by default; only if parent opt-in is set.
       Sends reply text only, never audio, never the child's words.
```

#### Avatar (`avatar/`)

```
Interface:
  set_state(state: idle / listening / thinking / speaking / didnt_catch)
  drive_from_audio(audio_stream)
  render(window)
  
Implementation:
  Live2D model rendered via WebGL in the app webview (pixi-live2d-display) —
  the Cubism SDK's practical targets are Web and C++; WebGL is the sane path
  with a Tauri/Electron shell.
  ⚠ Check Live2D Cubism SDK license terms before distributing, even for a free app.

  State machine drives expression + idle animation

  Lip-sync: amplitude-based, not viseme-based.
    Compute RMS energy over the playing audio → drive ParamMouthOpenY.
    This is the standard Live2D approach, looks perfectly fine to a child,
    and removes the phoneme-timestamp requirement from TTS entirely.
    (Viseme mapping = optional Phase 4+ polish, only if mouth motion feels flat.)

  Synchronization:
    - Audio playback position is the clock; mouth follows measured amplitude
    - On audio complete → smooth transition back to idle
```

### 3.4 Safety Layer

- Runs as a transparent middleware between LLM output and TTS input
- Operates **per sentence** (the LLM streams sentences — the filter must too)
- Two filters:
  1. **Blocklist** — hard-coded terms, instant replace. Treat as a tripwire, not the
     defense: it misses inappropriate content phrased in clean words and false-positives
     on innocent ones (Scunthorpe problem). The real defense is the system prompt plus
     the parent-review log.
  2. **Tone check** (optional, Phase 4) — a second cheap LLM call ("Is this reply
     appropriate and understandable for a young child? yes/no") rather than a custom
     classifier. Same local model, tiny prompt, runs on the full reply.
- Everything logged to `~/.ai-avatar/logs/` for parent review
- Log format: JSONL, one object per turn, includes user text, model reply, filter action
- Optional parental controls (config): daily session length limit, quiet hours

### 3.5 Configuration

`config.yaml`:

```yaml
child:
  name: "Lily"              # used in LLM system prompt

personality:
  avatar_name: "Nova"
  # {child_name} / {avatar_name} are filled in with str.format at startup
  system_prompt: |
    You are {child_name}'s English-learning friend, {avatar_name}.
    - Speak in short, simple English sentences
    - Be warm, curious, encouraging
    - Ask open-ended questions about her day
    - Keep replies under 2 sentences when possible
    - Never use complex vocabulary without explaining it
    - If she makes a mistake, naturally repeat her idea back in correct
      English; never point out that she was wrong

privacy:
  allow_cloud_fallback: false   # parent opt-in; even when true, audio never leaves the device

models:
  stt:
    engine: faster-whisper
    model: small.en
    no_speech_threshold: 0.6    # discard transcript if Whisper's no_speech_prob exceeds this
  llm:
    engine: ollama
    model: llama3.2:3b
    temperature: 0.7
    max_response_tokens: 120    # trimmed to last complete sentence before TTS
  tts:
    engine: piper
    voice: en_US-lessac-medium
    length_scale: 1.1           # slightly slower speech for a learner
    fallback:
      - engine: xtts-v2
      - engine: elevenlabs-api   # requires API key AND privacy.allow_cloud_fallback

audio:
  input_device: ""              # empty = OS default; substring-match to override (e.g. "AirPods")

avatar:
  model: nova/live2d/nova.model3.json
  lip_sync: amplitude            # RMS → mouth-open; visemes are a possible later upgrade

safety:
  blocklist_file: ./blocklist.txt
  log_path: ~/.ai-avatar/logs/conversations.jsonl
  session_limit_minutes: 30      # optional; omit for no limit
  # quiet_hours: "20:00-07:00"   # optional

app:
  window_title: "Nova"
  always_on_top: true
  recording_key: space
```

---

## 4. Phase Plan

### Phase 1 — Working Prototype

- Text-only LLM (no TTS, no avatar, no mic yet)
- Chat window with Nova personality, sentence-streaming from the start
  (the streaming pipeline is the backbone — build it now, not as a retrofit)
- Test conversations, tune prompt, tune temperature, verify recasting behavior
- Goal: good conversational quality

### Phase 2 — Full Voice Loop

- Add faster-whisper STT with push-to-talk (hold Space) **and** Piper TTS
- Complete hands-free-of-keyboard-except-Space loop: talk → hear reply. No avatar yet.
- This front-loads the two riskiest unknowns — end-to-end latency and
  STT accuracy on the child's actual speech — before any Live2D investment
- Exit criteria (both must pass):
  1. Release-Space → first audio ≤ 1.5 s
  2. STT recognizes the child's real speech acceptably (test with her, not with adult voices)

### Phase 3 — Avatar

- Add Live2D model with idle animation (WebGL in the app webview)
- Add the 5-state state machine, including "didn't catch that" and barge-in
- Amplitude-based lip-sync (RMS → mouth open)
- Goal: child can sit down, hold space, talk, and get a responsive animated reply

### Phase 4 — Polish

- Content filter (blocklist + LLM tone check)
- Conversation logging for parent review
- Session limits / quiet hours
- Package as standalone app (Tauri shell + Python sidecar)
- Optional: viseme-based lip-sync if amplitude motion feels flat

---

## 5. Open Questions

Decision needed before Phase 3:

| Question | Options | Recommendation |
|---|---|---|
| **App architecture** | Tauri + Python sidecar / Electron + Python sidecar / all-Rust (whisper-rs, piper-rs) / all-Python (PyQt) | Tauri shell + **Python sidecar** for the pipeline, talking over a local websocket. The pipeline tools (faster-whisper, Piper, Ollama client) are all easiest from Python; the Rust-native ports are less mature. Live2D renders in the webview either way. |
| **Avatar format** | Live2D (.model3) / Spine / custom WebGL | Live2D: largest asset library, easiest to find a free child-friendly model. Verify SDK license terms for distribution. |
| **LLM runtime** | Ollama / llama.cpp directly | Ollama: simplest API, easy model management, streaming out of the box |

Note the framework question is really a **process-boundary** question: the pipeline stack is
Python-flavored while Tauri's backend is Rust. The sidecar pattern resolves the tension without
rewriting anything.

---

## 6. Tech Stack Summary

| Layer | Local | Cloud fallback (parent opt-in only) |
|---|---|---|
| STT | faster-whisper (small.en) | — (audio never leaves the device) |
| LLM | Llama 3.2 3B via Ollama | GPT-4o-mini (text only) |
| TTS | Piper (lessac-medium) | ElevenLabs (reply text only) |
| Avatar | Live2D (WebGL in webview) | — |
| Framework | Tauri shell + Python sidecar | — |
| Logging | JSONL → parent-readable file | — |
