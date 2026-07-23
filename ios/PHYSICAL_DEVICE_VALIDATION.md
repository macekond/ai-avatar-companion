# Physical-device validation checklist

Every engine (whisper.cpp, llama.cpp, Kokoro, Piper, open_jtalk) has been verified
**functionally correct** against real models/data in iOS Simulator (see `ios/README.md` and
`ios/spikes/*/README.md`). What Simulator numbers cannot answer — Metal/NEON performance,
thermal throttling, and jetsam memory limits are not faithfully reproduced in Simulator — is
Phase 0's actual go/no-go question from the port plan: **can whisper.cpp + llama.cpp +
Kokoro/Piper/open_jtalk coexist fast enough, and within memory budget, on real iPhone hardware?**

This can only be answered by running the app on a physical device — no environment without one
can produce this data, this one included (`xcrun devicectl list devices` here shows zero attached
physical devices, only this Mac and Simulators). What *can* be done without a device is make that
run a single mechanical checklist instead of open-ended investigation. `DiagnosticsLogging.swift`
(`Diagnostics.log`/`measureMs`/`memoryFootprintMB`) instruments exactly the numbers below at
exactly the points that matter, verified firing correctly in Simulator (see git history) — a real
device run is: build, run one conversation turn, read the log.

## How to run this

1. Connect a physical iPhone (iOS 17+) via USB or network, select it as the run destination in
   Xcode (`ios/Nova.xcodeproj`, scheme `Nova`), and Run.
2. Ensure real model files exist under the app's Application Support `models/` directory (Phase
   9's on-demand download isn't pointed at a real CDN yet — see `ios/README.md` — so for this
   checklist, copy real files in directly via Xcode's Devices window or `xcrun devicectl device
   copy` before first launch, matching the filenames `NovaWebSocketServer.modelSpecs` expects).
3. Do one full conversation turn (hold-to-talk, speak, wait for the reply) in English, then one
   in Japanese.
4. Open Console.app, select the device, filter by process `Nova` and subsystem
   `com.novaapp.nova`, category `diagnostics` (or `xcrun devicectl device log` if scripting this).
5. Read off each `event=` line below against its threshold from the original port plan.

## Go/no-go thresholds (from the Phase 0 plan)

| Event | Field | Threshold | Spike |
|---|---|---|---|
| `event=stt_latency` | `ms` | < 1500ms for `audio_s` ≈ 3s | Spike 1 (whisper.cpp) |
| `event=stt_latency` | `memory_mb` | < 600MB | Spike 1 |
| `event=llm_generation` | `first_token_ms` | < 1000ms | Spike 2 (llama.cpp) |
| `event=llm_generation` | `tokens_per_sec` | ≥ 15 | Spike 2 |
| `event=llm_generation` | `memory_mb` | < 2500-3000MB | Spike 2 |
| `event=tts_latency` (`engine=piper`) | `ms` | < 300-500ms for ~1 sentence | Spike 3 (Piper) |
| `event=tts_latency` (`engine=kokoro`) | `ms` | no hard number in the plan — judge against Piper's | Spike 4 (Kokoro) |
| `event=engine_loaded` | `memory_mb` (cumulative, in load order: whisper → llama → openjtalk → kokoro → piper) | the *last* value is the worst-case resident footprint with every engine loaded at once — this is the single number Phase 0 flagged as highest-risk ("must coexist with STT/TTS engines during a live turn") | Cross-cutting |

## Not covered by this instrumentation (still needs manual judgment on a real run)

- **Thermal throttling / sustained-session behavior**: the plan calls for a 15-20 minute
  sustained-conversation test on the lowest supported device tier. No automatic pass/fail here —
  watch Xcode's Debug Navigator thermal state gauge (or `ProcessInfo.thermalState`, not currently
  logged) across that session and note whether generation/synthesis measurably slows down partway
  through.
- **Spoken-audio quality judgment**: Piper/Kokoro producing audio in-budget doesn't mean it sounds
  *good* — that's a human listening judgment, not a number this file can check for you.
- **Device tier spread**: the memory numbers above are pass/fail on whichever device you test;
  the plan calls this out as the real risk on *lower-RAM* devices specifically, so a pass on a
  Pro-tier phone doesn't clear this — retest on the lowest device tier Nova intends to support.

## Recording the result

Once run, append the actual numbers (device model, iOS version, each metric above) to this file
under a `## Results` heading, or open a PR discussion referencing this checklist — either way,
turns this from "unresolved" into a dated, attributable data point future work can build on.
