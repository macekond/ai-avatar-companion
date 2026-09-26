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
   `cz.macek.nova`, category `diagnostics` (or `xcrun devicectl device log` if scripting this).
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

## Preliminary memory-budget risk analysis (Simulator numbers + real file sizes, not a device run)

This can't substitute for a real measurement, but it's arithmetic against real numbers rather than
a guess, and it points at a specific, likely real risk worth watching for on the actual run.

**Real cumulative Simulator footprint measured this session** (via `Diagnostics.log("engine_loaded", ...)`,
loading in order): whisper 596MB → llama (interim SmolLM2-135M) 709MB → open_jtalk 709MB (dictionary
load is small) → Kokoro 1383MB → Piper 1494MB. That's **~1.5GB with every engine loaded**, using the
135M-parameter placeholder LLM the plan itself flags as "NOT one of the real candidates" (`llm.gguf`'s
own doc comment in `NovaWebSocketServer.swift`) — small enough (105MB on disk) to verify the
download/load mechanism without exhausting this environment's disk, not a stand-in for real quality
or real memory pressure.

**The real candidates are Llama-3.2-3B-Instruct or Qwen2.5-3B-Instruct**, both ~3B parameters. A
Q4_K_M-quantized GGUF for a 3B model is commonly ~1.8-2.2GB on disk (roughly `3.2e9 params ×
~4.6 bits/param ÷ 8`, consistent with the 135M interim model's own ratio: 105MB on disk for 135M
params scales to ~2.2GB for 3B at the same bits-per-param). Runtime footprint (weights + KV cache +
Metal buffers) typically runs somewhat *above* the on-disk GGUF size, not below it.

**Rough extrapolation**: swap the ~100MB interim LLM's Simulator contribution for a ~2-2.5GB real
one and the same load order gives a cumulative footprint in the **~3.2-3.7GB range** — before
accounting for Simulator vs. real-device differences (real Metal buffer allocation, real KV cache
growth over a long conversation, real audio-engine buffers) in either direction.

**Why this matters concretely**: iOS's per-app jetsam foreground memory limit varies by device RAM
tier — roughly ~1-1.6GB on 2-3GB-RAM devices, ~2-2.5GB on 4GB-RAM devices (iPhone 12/13/14 base
tier), and higher (~3-4GB+) only on 6GB+-RAM Pro-tier devices. A ~3.2-3.7GB cumulative estimate
would plausibly **exceed budget on anything but the highest-RAM current iPhones** — which is
exactly the "must coexist with STT/TTS engines during a live turn" risk the original port plan
already flagged as this app's single biggest memory risk, now with real numbers behind the concern
instead of just a plan-stage hunch.

**What this means for the physical-device run**: don't just test on whichever device is on hand.
Test on the *lowest RAM tier* Nova intends to support specifically, with the *real* 3B LLM (not
the SmolLM2-135M interim one) — that combination is where this estimate suggests jetsam
termination becomes a real possibility, not just a device-badge-independent pass/fail check.

## Recording the result

Once run, append the actual numbers (device model, iOS version, each metric above) to this file
under a `## Results` heading, or open a PR discussion referencing this checklist — either way,
turns this from "unresolved" into a dated, attributable data point future work can build on.
