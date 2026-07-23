import Foundation
import Network
import NovaCore

/// open_jtalk's dictionary isn't bundled/downloaded yet (Phase 9 — see
/// OpenJTalkMorphemeAnalyzer's doc comment), so this analyzer always fails
/// until one is present, and `FuriganaFormatter` takes its documented
/// fallback path (plain escaped text) for Japanese profiles instead of
/// producing `<ruby>` markup.
private struct UnavailableMorphemeAnalyzer: MorphemeAnalyzing {
    func analyze(_ text: String) throws -> [Morpheme] {
        throw CocoaError(.featureUnsupported)
    }
}

/// In-process WebSocket server replacing the Python `app/server.py` sidecar
/// (Phase 1/2 of the iOS port plan). Listens on loopback so the bundled
/// `ui/src/main.js` — unmodified — can open its existing `ws://localhost:8765`
/// connection.
///
/// This class owns only the transport (accept connections, frame messages).
/// Protocol decoding/state-machine logic lives in `NovaCore` so it stays
/// testable without a live network stack; see `ProtocolMessages` and
/// `SessionStateMachine`.
@MainActor
public final class NovaWebSocketServer: ObservableObject {
    public enum ServerError: Error {
        case invalidPort
    }

    private let port: UInt16
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]

    /// One state machine per connection — each browser tab/session is
    /// independent, mirroring `app/server.py`'s per-connection `_session`.
    private var stateMachines: [ObjectIdentifier: SessionStateMachine] = [:]

    /// Active profile memory + the manager that owns it, per connection —
    /// mirrors `app/server.py`'s per-session `mem_mgr`/`memory` (Phase 7).
    /// Loaded/created on `avatarLoaded` (mirroring the desktop app loading
    /// the default profile right after connect).
    private var memoryManagers: [ObjectIdentifier: MemoryManager] = [:]
    private var memories: [ObjectIdentifier: ChildMemory] = [:]

    /// Conversation history (`TranscriptStore`, NovaCore) per connection —
    /// port of app/server.py's `transcript_store`/`conv_turn_n`. Persisted
    /// separately from `ChildMemory` (raw child↔Nova text + corrections,
    /// vs. extracted topics/problems), replayed to the UI on every
    /// connect/profile-switch so the panel survives a reload.
    private var transcriptStores: [ObjectIdentifier: TranscriptStore] = [:]
    private var convTurnIds: [ObjectIdentifier: Int] = [:]

    /// Port of app/server.py's `has_greeted` — see the `.start` case.
    private var hasGreeted: [ObjectIdentifier: Bool] = [:]
    private static func transcriptsDir() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("transcripts")
    }

    /// Port of `_load_transcript`: resets the UI's history panel, then
    /// replays every stored turn (+ corrections) for `slug` — `conv_turn_n`
    /// (here `convTurnIds`) continues past the last stored id so a live
    /// turn never collides with a replayed one.
    private func loadTranscript(slug: String, for connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        send(.conversationReset, on: connection)
        let store = TranscriptStore(transcriptsDir: Self.transcriptsDir(), slug: slug)
        transcriptStores[id] = store
        let language = memories[id]?.profile.language ?? "en"
        let formatter = furiganaFormatter()
        for turn in store.load() {
            send(.conversationTurn(
                id: turn.id, you: turn.you, nova: turn.nova,
                youHtml: formatter.annotateFor(turn.you, language: language),
                novaHtml: formatter.annotateFor(turn.nova, language: language)
            ), on: connection)
            for correction in turn.corrections {
                send(.conversationCorrection(
                    id: turn.id, kind: correction.kind, wrong: correction.wrong, right: correction.right,
                    wrongHtml: formatter.annotateFor(correction.wrong, language: language),
                    rightHtml: formatter.annotateFor(correction.right, language: language)
                ), on: connection)
            }
        }
        convTurnIds[id] = store.lastId()
    }

    /// Guards `replyAndContinue`'s fire-and-forget LLM generation task
    /// against landing after the connection's active profile has moved on
    /// (a `switch_profile`/`delete_profile` mid-generation) — port of the
    /// object-identity check `app/server.py`'s `_apply_extracted_memory`
    /// uses for the same "async work outliving its validity window"
    /// problem (see `_swap_profile`'s doc comment in the root CLAUDE.md).
    /// Advanced on every profile change; a stale token's `speakSentences`
    /// call becomes a silent no-op instead of speaking/displaying an old
    /// profile's reply under the new profile's session.
    private var generationGuards: [ObjectIdentifier: GenerationGuard] = [:]
    private func generationGuard(for connection: NWConnection) -> GenerationGuard {
        let id = ObjectIdentifier(connection)
        if let existing = generationGuards[id] { return existing }
        let newGuard = GenerationGuard()
        generationGuards[id] = newGuard
        return newGuard
    }

    /// Two-turn spoken onboarding (name, then age) for a brand-new profile —
    /// port of `_run_onboarding` in app/server.py. `nil` for a connection
    /// means onboarding isn't in progress (either finished, or not needed
    /// because the profile already existed). `onboardingNames` holds the
    /// name collected in step 1 until step 2 completes the profile.
    private enum OnboardingStep {
        case askingName
        case askingAge
    }
    private var onboardingSteps: [ObjectIdentifier: OnboardingStep] = [:]
    private var onboardingNames: [ObjectIdentifier: String] = [:]

    private static func profilesDir() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("profiles")
    }

    /// One persistent mic recorder for the whole process — the Python
    /// original scopes `_MicRecorder` per-session, but this app only ever
    /// hosts a single local WKWebView connection at a time, so process
    /// lifetime and session lifetime coincide in practice.
    private let recorder = MicRecorder()

    /// Nil until a model file exists (Phase 9: on-demand download — nothing
    /// is bundled yet). `WhisperEngine` itself is verified correct (see
    /// ios/spikes/01-stt-whisper/README.md's Status section); this wiring is
    /// real but inert until a model is actually present on disk.
    private var whisperEngine: WhisperEngine?

    /// Same story as `whisperEngine` — see ios/spikes/02-llm-llama/README.md.
    private var llamaEngine: LlamaEngine?

    /// Real once open_jtalk's dictionary directory exists on disk (Phase 9 —
    /// the dictionary itself isn't bundled, only the library is vendored),
    /// else `UnavailableMorphemeAnalyzer`'s documented fallback applies.
    private var morphemeAnalyzer: MorphemeAnalyzing = UnavailableMorphemeAnalyzer()
    private func furiganaFormatter() -> FuriganaFormatter { FuriganaFormatter(analyzer: morphemeAnalyzer) }

    private let modelDownloader = ModelDownloader()
    /// Interim direct-from-HuggingFace URLs — Phase 9's plan calls for
    /// mirroring these to a CDN the app controls rather than depending on a
    /// live third-party fetch from a shipped App Store app; not done yet.
    /// Filenames match what `Self.modelPath` looks for.
    /// "llm.gguf" here is SmolLM2-135M (small enough to verify the download
    /// mechanism itself without exhausting this environment's disk/bandwidth)
    /// — NOT one of the real candidates (Llama-3.2-3B / Qwen2.5-3B) Spike 2
    /// still needs to A/B on a physical device.
    private static let modelSpecs = [
        ModelSpec(filename: "ggml-small.bin", urlString: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin"),
        ModelSpec(filename: "llm.gguf", urlString: "https://huggingface.co/QuantFactory/SmolLM2-135M-Instruct-GGUF/resolve/main/SmolLM2-135M-Instruct.Q4_K_M.gguf"),
        ModelSpec(filename: "kokoro-v1.0.onnx", urlString: "https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/kokoro-v1.0.onnx"),
        ModelSpec(filename: "voices-v1.0.bin", urlString: "https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/voices-v1.0.bin"),
        // ljspeech: trained on the public-domain LJSpeech dataset (per its
        // Hugging Face MODEL_CARD) — NOT fine-tuned from lessac, unlike
        // several other rhasspy/piper-voices English voices (amy, joe,
        // jenny_dioco all say "Finetuned from U.S. English lessac voice").
        // `en_US-lessac` was already flagged in the root CLAUDE.md as a
        // research-only voice removed from the desktop app on licensing
        // grounds; picking a voice derived from the same underlying data
        // for this iOS wiring would quietly reintroduce that same problem.
        // ljspeech/norman/kristin (LibriVox, public domain) are all safe
        // alternatives; ljspeech was chosen arbitrarily among those three.
        ModelSpec(filename: "piper-en.onnx", urlString: "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/ljspeech/medium/en_US-ljspeech-medium.onnx"),
        ModelSpec(filename: "piper-en.onnx.json", urlString: "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/ljspeech/medium/en_US-ljspeech-medium.onnx.json"),
    ]
    private var setupPhase = "ready"

    /// Guaranteed fallback (no model download needed) — see SystemTTSEngine's
    /// doc comment. Used for English when Piper isn't loaded or fails, and
    /// for Japanese when Kokoro isn't loaded or fails.
    private let ttsEngine = SystemTTSEngine()

    /// Real once espeak-ng's compiled data directory, a Piper voice model,
    /// and its `.onnx.json` config all exist on disk (Phase 9 on-demand
    /// download). See ios/spikes/03-tts-piper/README.md's espeak-ng update:
    /// the cross-compile that blocked this is done.
    private var espeakPhonemizer: EspeakPhonemizer?
    private var piperEngine: PiperEngine?
    private var piperConfig: PiperConfig?
    private let piperPlayer = KokoroPlayer()

    /// Real once both the Kokoro ONNX model and voices archive exist on disk
    /// (Phase 9 on-demand download — not bundled). See
    /// ios/spikes/04-tts-kokoro-openjtalk/README.md and
    /// ios/spikes/03-tts-piper/README.md's Kokoro updates: this engine and
    /// its voice-styling/tokenizer plumbing are verified against real models,
    /// but weren't wired into the live reply flow until now.
    private var kokoroEngine: KokoroEngine?
    private var kokoroVoiceStore: KokoroVoiceStore?
    private let kokoroPlayer = KokoroPlayer()
    /// `af_alloy` is the voice this engine's Kokoro integration has actually
    /// been verified against (see the spike README's real-voice-synthesis
    /// update) — arbitrary otherwise, no per-profile voice picker yet.
    private static let kokoroVoiceName = "af_alloy"

    /// Set by `stopSpeak` (barge-in) so `speakSentences`'s recursion stops
    /// dead instead of continuing to the next sentence — stopping the active
    /// engine alone only cancels the *current* utterance; its onFinish
    /// callback still fires and would otherwise keep the reply going.
    private var speechInterrupted = false

    /// Port of `app/appearance.py`'s `AppearanceStore` — resolves the
    /// current avatar's appearance description (curated for the two
    /// bundled VRMs; the derived-from-region-colours cache path isn't
    /// exercised by either, so `cacheDir` need not exist yet). Refreshed by
    /// `avatarLoaded`'s `key`, fed into every reply's `PromptBuilder`.
    private lazy var appearanceStore = AppearanceStore(cacheDir: Self.appearanceCacheDir())
    private var currentAppearance: String?
    private static func appearanceCacheDir() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("appearance_cache")
    }

    /// Base personality prompt — placeholder until Config (config.yaml's
    /// `personality.system_prompt`) is ported; PromptBuilder's own load-bearing
    /// assembly order (teaching frame -> level -> memory -> appearance ->
    /// LANGUAGE_LOCK last) is real and unaffected by this placeholder.
    private static let placeholderBasePrompt = "You are Nova, a warm and encouraging language-practice companion for children."

    public init(port: UInt16) {
        self.port = port
        // Matches app/server.py's `_apply_appearance(DEFAULT_AVATAR_KEY)`
        // right after construction — a sane default before any
        // `avatarLoaded` has arrived (in practice it always does, first,
        // per protocol, but a reply generated before then should still get
        // an appearance line rather than silently omitting that prompt block).
        currentAppearance = appearanceStore.get(key: defaultAvatarKey)?.description
    }

    /// Where a downloaded model would live under Application Support,
    /// mirroring the desktop app's `~/.ai-avatar/` layout under the app's
    /// own sandboxed directory.
    private static func modelPath(_ filename: String) -> String? {
        guard let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let path = dir.appendingPathComponent("models/\(filename)").path
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    /// Instantiates whichever engines have their model file already present.
    /// Safe to call again after a download completes to pick up newly
    /// arrived files. Construction (Metal shader compilation for the LLM
    /// engine especially) is a genuinely slow blocking call — done via
    /// `Task.detached` so it never stalls the main actor, which also runs
    /// this app's WebSocket networking (a real bug caught by testing: engine
    /// construction on the main actor stalled ping/receive handling long
    /// enough that a connected client's socket timed out and closed).
    private func loadAvailableEngines() async {
        // Logs the memory footprint after each engine loads — Phase 0's
        // riskiest open question is whether all engines coexist within a
        // real device's memory budget (the LLM alone was flagged as
        // "the single biggest memory risk in the app" in the port plan),
        // so a running total here is exactly what a physical-device run
        // needs to answer it.
        if whisperEngine == nil, let modelPath = Self.modelPath("ggml-small.bin") {
            whisperEngine = await Task.detached { try? WhisperEngine(modelPath: modelPath) }.value
            Diagnostics.log("engine_loaded", ["engine": "whisper", "memory_mb": String(Diagnostics.memoryFootprintMB())])
        }
        if llamaEngine == nil, let modelPath = Self.modelPath("llm.gguf") {
            llamaEngine = await Task.detached { try? LlamaEngine(modelPath: modelPath) }.value
            Diagnostics.log("engine_loaded", ["engine": "llama", "memory_mb": String(Diagnostics.memoryFootprintMB())])
        }
        if morphemeAnalyzer is UnavailableMorphemeAnalyzer, let dictDir = Self.dictionaryDirectory() {
            let loaded: OpenJTalkMorphemeAnalyzer? = await Task.detached {
                try? OpenJTalkMorphemeAnalyzer(dictDir: dictDir)
            }.value
            if let loaded {
                morphemeAnalyzer = loaded
                Diagnostics.log("engine_loaded", ["engine": "openjtalk", "memory_mb": String(Diagnostics.memoryFootprintMB())])
            }
        }
        if kokoroEngine == nil, let modelPath = Self.modelPath("kokoro-v1.0.onnx") {
            kokoroEngine = await Task.detached { try? KokoroEngine(modelPath: modelPath) }.value
            Diagnostics.log("engine_loaded", ["engine": "kokoro", "memory_mb": String(Diagnostics.memoryFootprintMB())])
        }
        if kokoroVoiceStore == nil, let voicesPath = Self.modelPath("voices-v1.0.bin") {
            kokoroVoiceStore = await Task.detached {
                (try? Data(contentsOf: URL(fileURLWithPath: voicesPath))).flatMap { try? KokoroVoiceStore(data: $0) }
            }.value
        }
        if espeakPhonemizer == nil, let dataDir = Self.espeakDataDirectory() {
            // Voice is set per-synthesis from the loaded PiperConfig's own
            // `espeak.voice` field (see `speak(_:language:...)`) rather than
            // here — different Piper voices specify different espeak voice
            // names (e.g. ljspeech's config says "en", not "en-us").
            espeakPhonemizer = await Task.detached { try? EspeakPhonemizer(dataDir: dataDir) }.value
        }
        if piperEngine == nil, let modelPath = Self.modelPath("piper-en.onnx") {
            piperEngine = await Task.detached { try? PiperEngine(modelPath: modelPath) }.value
            Diagnostics.log("engine_loaded", ["engine": "piper", "memory_mb": String(Diagnostics.memoryFootprintMB())])
        }
        if piperConfig == nil, let configPath = Self.modelPath("piper-en.onnx.json") {
            piperConfig = await Task.detached {
                (try? Data(contentsOf: URL(fileURLWithPath: configPath))).flatMap { try? PiperConfig(json: $0) }
            }.value
        }
    }

    /// espeak-ng's compiled dictionary/intonation data (Phase 9: not bundled
    /// — see `build-espeak-ng-ios.sh`'s `build-apple/espeak-ng-data` output).
    private static func espeakDataDirectory() -> String? {
        guard let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let path = dir.appendingPathComponent("models/espeak-ng-data").path
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue ? path : nil
    }

    /// The compiled naist-jdic directory — not bundled in git (Phase 9: it's
    /// ~50-100MB of `.dic`/`.bin` files, sourced from pyopenjtalk's own wheel
    /// distribution, same on-demand pattern as the other models).
    private static func dictionaryDirectory() -> String? {
        guard let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let path = dir.appendingPathComponent("models/openjtalk_dic").path
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue ? path : nil
    }

    /// Downloads whatever's missing (Phase 9), broadcasting `setup_status`
    /// progress to every connected client along the way — mirrors
    /// app/server.py's `setup_state`/`setup_watchers` broadcast pattern
    /// (lines ~1412-1468), just without the multi-watcher plumbing since
    /// this app only ever has one local WKWebView client.
    private func downloadMissingModelsThenLoad() async {
        await modelDownloader.downloadMissing(Self.modelSpecs) { [weak self] fraction in
            guard let self else { return }
            let percent = Int(fraction * 100)
            self.broadcast(.setupStatus(phase: "downloading_models", detail: "\(percent)%"))
        }
        await loadAvailableEngines()
        setupPhase = "ready"
        broadcast(.setupStatus(phase: "ready", detail: ""))
    }

    /// Port of app/server.py's `_send_settings`: the Settings-panel state
    /// (language, levels + voices for that language, current selections) for
    /// the connection's active profile. Sent alongside every `init`.
    ///
    /// `voices` is a single hardcoded entry per language — this app has no
    /// per-language voice catalog yet (Piper/Kokoro are each wired to one
    /// voice; see ios/spikes/03-tts-piper/README.md), unlike the desktop
    /// app's `_voices_for()` which lists every downloadable voice.
    /// This app's only voice per language — Piper (`ljspeech`) for English,
    /// Kokoro (`af_alloy`) for Japanese. Real multi-voice support (like
    /// desktop's `_voices_for`/per-voice on-demand download) doesn't exist
    /// yet; a single-entry catalog is the honest reflection of that, not a
    /// placeholder to expand later without further model-download work.
    private func voiceCatalog(for language: String) -> [VoiceOption] {
        language == "ja"
            ? [VoiceOption(id: "af_alloy", label: "Alloy")]
            : [VoiceOption(id: "ljspeech", label: "LJSpeech")]
    }

    private func sendSettings(for connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        guard let profile = memories[id]?.profile else { return }
        let voices = voiceCatalog(for: profile.language)
        send(.settings(
            language: profile.language,
            languages: Levels.languages,
            levels: Levels.levelsFor(profile.language),
            level: profile.level,
            voices: voices,
            voice: profile.voice.isEmpty ? voices.first?.id ?? "" : profile.voice
        ), on: connection)
    }

    private func broadcast(_ message: ServerMessage) {
        for connection in connections.values {
            send(message, on: connection)
        }
    }

    public func start() throws {
        try recorder.start()
        setupPhase = "loading_models"
        Task {
            await loadAvailableEngines()
            if whisperEngine == nil || llamaEngine == nil {
                setupPhase = "downloading_models"
                await downloadMissingModelsThenLoad()
            } else {
                setupPhase = "ready"
                broadcast(.setupStatus(phase: "ready", detail: ""))
            }
        }
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw ServerError.invalidPort
        }
        let params = NWParameters.tcp
        let wsOptions = NWProtocolWebSocket.Options()
        wsOptions.autoReplyPing = true
        params.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)
        // Loopback-only: this server exists to talk to the WKWebView hosted
        // in the same app, never to accept remote connections. (Setting
        // requiredLocalEndpoint's port here conflicts with the `on: nwPort`
        // passed to NWListener below — "cannot override to <port>" — so
        // loopback restriction goes through the interface type instead.)
        params.requiredInterfaceType = .loopback

        let listener = try NWListener(using: params, on: nwPort)
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.accept(connection) }
        }
        listener.start(queue: .main)
        self.listener = listener
    }

    public func stop() {
        for connection in connections.values {
            connection.cancel()
        }
        connections.removeAll()
        stateMachines.removeAll()
        listener?.cancel()
        listener = nil
    }

    private func accept(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        connections[id] = connection
        stateMachines[id] = SessionStateMachine()

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                Task { @MainActor in self?.drop(connection) }
            default:
                break
            }
        }
        connection.start(queue: .main)
        receiveLoop(connection)
    }

    private func drop(_ connection: NWConnection) {
        // Every per-connection dictionary must be cleaned up here — this app
        // only ever has one *active* WKWebView client, but the WebView can
        // reconnect many times over a long session (reload, backgrounding
        // recovery), and each old NWConnection's ObjectIdentifier stays a
        // valid dictionary key forever otherwise: an unbounded leak, not
        // just an unused-memory nuisance, since a stale entry surviving here
        // is exactly the kind of "state that should have moved on" bug this
        // codebase's other invariants (GenerationGuard, the delete-tombstone
        // pattern) exist to prevent elsewhere.
        let id = ObjectIdentifier(connection)
        connections.removeValue(forKey: id)
        stateMachines.removeValue(forKey: id)
        generationGuards.removeValue(forKey: id)
        memoryManagers.removeValue(forKey: id)
        memories.removeValue(forKey: id)
        onboardingSteps.removeValue(forKey: id)
        onboardingNames.removeValue(forKey: id)
        transcriptStores.removeValue(forKey: id)
        convTurnIds.removeValue(forKey: id)
        hasGreeted.removeValue(forKey: id)
    }

    private func receiveLoop(_ connection: NWConnection) {
        connection.receiveMessage { [weak self] data, context, isComplete, error in
            Task { @MainActor in
                guard let self else { return }
                if let data, let context, isComplete {
                    self.handle(data: data, context: context, on: connection)
                }
                if error == nil {
                    self.receiveLoop(connection)
                } else {
                    self.drop(connection)
                }
            }
        }
    }

    private func handle(data: Data, context: NWConnection.ContentContext, on connection: NWConnection) {
        guard let metadata = context.protocolMetadata.first(where: { $0 is NWProtocolWebSocket.Metadata })
            as? NWProtocolWebSocket.Metadata, metadata.opcode == .text
        else { return }

        guard let message = try? JSONDecoder().decode(ClientMessage.self, from: data) else {
            return
        }
        let id = ObjectIdentifier(connection)
        var machine = stateMachines[id] ?? SessionStateMachine()
        dispatch(message, machine: &machine, connection: connection)
        stateMachines[id] = machine
    }

    /// Applies a decoded client message to the session state machine and
    /// sends the resulting `state` message back. Real STT/LLM/TTS wiring
    /// (Phases 3-5 of the plan) replaces the placeholder transitions here —
    /// this is deliberately just enough to prove the protocol/state-machine
    /// plumbing end-to-end (Phase 2) before any native inference is wired up.
    private func dispatch(_ message: ClientMessage, machine: inout SessionStateMachine, connection: NWConnection) {
        switch message {
        case .avatarLoaded(let key):
            // main.js sends this immediately on socket open and waits for
            // `init` to hide its "Connecting…" overlay (see ws.onopen /
            // markServerReady in ui/src/main.js). A connection that lands
            // mid-download gets the current phase immediately, same as
            // app/server.py sending `setup_state` right away rather than
            // making a late-joining client wait for the next progress tick.
            send(.setupStatus(phase: setupPhase, detail: ""), on: connection)
            // Port of app/server.py's `_apply_appearance`: refresh the
            // appearance description PromptBuilder feeds the LLM (a
            // load-bearing block in its prompt assembly order) so Nova can
            // answer "what do you look like?" in character. Global, not
            // per-connection, matching desktop's single shared `llm`
            // pipeline — this app only ever has one active WKWebView client.
            currentAppearance = appearanceStore.get(key: key)?.description
            let (memory, isNewProfile) = loadOrCreateDefaultProfile(for: connection)
            if isNewProfile {
                startOnboarding(for: connection)
                return
            }
            let manager = memoryManagers[ObjectIdentifier(connection)]!
            send(.profiles(list: manager.listProfiles(), active: manager.slug), on: connection)
            send(.memoryLoaded(name: memory.profile.name, age: memory.profile.age, language: memory.profile.language, level: memory.profile.level), on: connection)
            send(.initMessage(level: memory.profile.level, language: memory.profile.language), on: connection)
            sendSettings(for: connection)
            loadTranscript(slug: manager.slug, for: connection)
            // app/server.py sends this right after connect too (line 771) —
            // without it the state label never leaves its static HTML
            // placeholder text, since applyState() only fires on a `state`
            // message and nothing else updates that element.
            send(.state(machine.state), on: connection)
            return
        case .start:
            machine.start()
            let id = ObjectIdentifier(connection)
            // Port of app/server.py's `has_greeted` — the spoken greeting
            // fires once per profile-session (reset on every profile
            // switch, see `switchProfile`), triggered by the child (or a
            // parent) tapping "Say hi to Nova!" while in `awaiting_start`.
            if hasGreeted[id] != true {
                hasGreeted[id] = true
                sendGreeting(for: connection)
            }
        case .pttStart:
            machine.pttStart()
            recorder.pttStart()
        case .pttStop:
            // hasAudio mirrors app/pipeline/stt.py's MIN_DURATION_S floor
            // (STTConstants.hasEnoughAudio).
            let (hasAudio, samples) = recorder.pttStop()
            if let step = onboardingSteps[ObjectIdentifier(connection)] {
                // Onboarding has its own explicit state sends (matching the
                // Python original) rather than routing through the general
                // session state machine.
                if hasAudio, let engine = whisperEngine {
                    transcribeForOnboarding(samples: samples, engine: engine, step: step, connection: connection)
                } else {
                    continueOnboarding(transcript: nil, step: step, connection: connection)
                }
                return
            }
            machine.pttStop(hasAudio: hasAudio)
            if hasAudio, let engine = whisperEngine {
                transcribeAndContinue(samples: samples, engine: engine, connection: connection)
            }
        case .stopSpeak:
            speechInterrupted = true
            ttsEngine.stop()
            kokoroPlayer.stop()
            piperPlayer.stop()
            machine.stopSpeak()
        case .replay(let text):
            // Re-speak a stored line — port of app/server.py's `replay`
            // handler (_speak_interruptible): pure playback through the same
            // TTS router as a live reply, no transcript entry, no memory
            // extraction.
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                replay(trimmed, for: connection)
            }
        case .setLevel(let level):
            // Port of app/server.py's `set_level`: reject a level outside
            // the active profile's language taxonomy (a CEFR level for a
            // Japanese profile would blank the prompt), else persist it.
            let id = ObjectIdentifier(connection)
            guard var memory = memories[id] else { break }
            let language = memory.profile.language
            guard Levels.levelsFor(language).contains(level) else { break }
            memory.profile.level = level
            memories[id] = memory
            memoryManagers[id]?.save(memory)
        case .setLanguage(let language):
            // Port of app/server.py's `set_language`: reject an unknown
            // language, else reset level + voice to that language's
            // defaults (a level/voice picked for one language is
            // meaningless in another) and resend `settings` so the UI's
            // panel reflects the new language's level/voice catalog.
            let id = ObjectIdentifier(connection)
            guard var memory = memories[id] else { break }
            guard Levels.languages.contains(language) else { break }
            memory.profile.language = language
            memory.profile.level = Levels.defaultLevel(for: language)
            memory.profile.voice = ""
            memories[id] = memory
            memoryManagers[id]?.save(memory)
            sendSettings(for: connection)
        case .setVoice(let voice):
            // Port of app/server.py's `set_voice`: validate against the
            // ACTIVE language's catalog, silently ignore otherwise. This
            // app has exactly one voice per language (no per-voice download
            // to wait on), so `loading`/`downloading` collapses to an
            // immediate `ready` — still sent as two messages to match the
            // wire shape main.js already expects.
            let id = ObjectIdentifier(connection)
            guard var memory = memories[id] else { break }
            guard voiceCatalog(for: memory.profile.language).contains(where: { $0.id == voice }) else { break }
            send(.voiceStatus(state: "loading", voice: voice), on: connection)
            memory.profile.voice = voice
            memories[id] = memory
            memoryManagers[id]?.save(memory)
            send(.voiceStatus(state: "ready", voice: voice), on: connection)
        case .previewVoice(let voice):
            // Port of app/server.py's `preview_voice`: speak a fixed sample
            // line in the requested voice, active profile voice untouched.
            // An unknown voice id is ignored silently, same as set_voice.
            // Since this app has only one voice per language, "any voice
            // id" only ever resolves to that language's own voice — this
            // still exercises the full protocol round-trip for when a real
            // multi-voice catalog exists.
            guard let language = ["en", "ja"].first(where: { voiceCatalog(for: $0).contains { $0.id == voice } }) else { break }
            send(.previewStatus(state: "loading", voice: voice), on: connection)
            let sample = systemText("preview_sample", language: language, [:])
            // "ready" is sent only once playback actually finishes (matches
            // desktop's `await asyncio.to_thread(tts.preview, ...)` blocking
            // until done, then sending ready) — not right after starting it.
            speak(sample, language: language) { [weak self] amplitude in
                self?.send(.amplitude(value: amplitude), on: connection)
            } onFinish: { [weak self] in
                guard let self else { return }
                self.send(.amplitude(value: 0.0), on: connection)
                self.send(.previewStatus(state: "ready", voice: voice), on: connection)
            }
        case .switchProfile(let slug, let language, let level):
            switchProfile(slug: slug, language: language, level: level, for: connection)
        case .deleteProfile(let slug):
            // Refuses to delete the last remaining profile — mirrors
            // app/server.py's delete_profile guard (a parent must always
            // have at least one child profile to fall back to).
            let id = ObjectIdentifier(connection)
            generationGuard(for: connection).advance()
            hasGreeted.removeValue(forKey: id)
            let safeSlug = nameToSlug(slug, fallback: "")
            let isActiveProfile = !safeSlug.isEmpty && memoryManagers[id]?.slug == safeSlug
            // Delete through the connection's own live manager instance when
            // it's the active profile — MemoryManager's delete-tombstone is
            // an instance property, so deleting via a throwaway instance
            // would leave the live one un-tombstoned and able to resurrect
            // the file on its next save() (the same bug class the tombstone
            // pattern exists to prevent).
            let manager = isActiveProfile ? memoryManagers[id]! : MemoryManager(profilesDir: Self.profilesDir(), slug: slug)

            if manager.listProfiles().count <= 1 {
                send(.profileError(message: "Can't remove the only child."), on: connection)
            } else {
                _ = manager.deleteProfile(slug: slug)
                TranscriptStore(transcriptsDir: Self.transcriptsDir(), slug: slug).delete()
                if isActiveProfile {
                    // The active profile is gone — fall back to another
                    // remaining profile (or create a fresh default if
                    // somehow none exist) rather than leaving this
                    // connection pointed at a deleted one.
                    memories.removeValue(forKey: id)
                    memoryManagers.removeValue(forKey: id)
                    let remaining = manager.listProfiles()
                    let fallback: ChildMemory
                    if let nextSlug = remaining.first {
                        let nextManager = MemoryManager(profilesDir: Self.profilesDir(), slug: nextSlug)
                        fallback = nextManager.load() ?? ChildMemory(profile: ChildProfile(name: nextSlug))
                        memoryManagers[id] = nextManager
                        memories[id] = fallback
                    } else {
                        fallback = loadOrCreateDefaultProfile(for: connection).memory
                    }
                    let fallbackManager = memoryManagers[id]!
                    send(.profiles(list: fallbackManager.listProfiles(), active: fallbackManager.slug), on: connection)
                    send(.memoryLoaded(name: fallback.profile.name, age: fallback.profile.age, language: fallback.profile.language, level: fallback.profile.level), on: connection)
                    send(.initMessage(level: fallback.profile.level, language: fallback.profile.language), on: connection)
                    sendSettings(for: connection)
                    loadTranscript(slug: fallbackManager.slug, for: connection)
                } else if let activeManager = memoryManagers[id] {
                    send(.profiles(list: activeManager.listProfiles(), active: activeManager.slug), on: connection)
                }
            }
        default:
            break
        }
        send(.state(machine.state), on: connection)
    }

    /// Loads the connection's active profile (creating one on first run) —
    /// mirrors `app/server.py` loading the default child profile right after
    /// connect. Returns whether a profile file already existed (`false`
    /// means this is a brand-new profile that still needs spoken onboarding,
    /// per `app/server.py`'s "no profile file exists" trigger).
    private func loadOrCreateDefaultProfile(for connection: NWConnection) -> (memory: ChildMemory, isNew: Bool) {
        let id = ObjectIdentifier(connection)
        if let existing = memories[id] { return (existing, false) }

        let manager = MemoryManager(profilesDir: Self.profilesDir(), slug: "child")
        memoryManagers[id] = manager
        if let existing = manager.load() {
            memories[id] = existing
            return (existing, false)
        }
        // Not saved yet — onboarding (startOnboarding) fills in the real
        // name/age and saves once both turns complete, mirroring
        // _run_onboarding's mem_mgr.save(memory) at the end, not before.
        let placeholder = ChildMemory(profile: ChildProfile(name: "child"))
        memories[id] = placeholder
        return (placeholder, true)
    }

    /// Kicks off the two-turn spoken onboarding — port of `_run_onboarding`.
    /// Speaks the "what's your name?" question directly via `ttsEngine`
    /// (onboarding has its own explicit state sends in the Python original
    /// rather than going through the general session state machine).
    private func startOnboarding(for connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        onboardingSteps[id] = .askingName
        send(.onboardingStart, on: connection)
        speakOnboardingPrompt(systemText("onboarding_ask_name", language: "en", ["avatar": "Nova"]), on: connection)
    }

    private func speakOnboardingPrompt(_ text: String, on connection: NWConnection) {
        send(.state(.speaking), on: connection)
        send(.sentence(text: text, textHtml: nil), on: connection)
        ttsEngine.speak(text, language: "en") { [weak self] amplitude in
            self?.send(.amplitude(value: amplitude), on: connection)
        } onFinish: { [weak self] in
            self?.send(.state(.idle), on: connection)
        }
    }

    /// Handles one onboarding turn's transcript — advances from asking the
    /// name to asking the age, or (after age) finalizes the real profile and
    /// sends the normal post-connect profiles/memory_loaded/init sequence,
    /// exactly mirroring `_run_onboarding`'s two `_one_ptt_turn` calls.
    private func continueOnboarding(transcript: String?, step: OnboardingStep, connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        switch step {
        case .askingName:
            let name = transcript.flatMap { extractName(from: $0) } ?? "Friend"
            onboardingNames[id] = name
            onboardingSteps[id] = .askingAge
            speakOnboardingPrompt(systemText("onboarding_ask_age", language: "en", ["name": name]), on: connection)
        case .askingAge:
            let age = transcript.flatMap { extractAge(from: $0) }
            let name = onboardingNames[id] ?? "Friend"
            onboardingNames.removeValue(forKey: id)
            onboardingSteps.removeValue(forKey: id)

            let memory = ChildMemory(profile: ChildProfile(name: name, age: age))
            memoryManagers[id]?.save(memory)
            memories[id] = memory

            guard let manager = memoryManagers[id] else { return }
            send(.profiles(list: manager.listProfiles(), active: manager.slug), on: connection)
            send(.memoryLoaded(name: memory.profile.name, age: memory.profile.age, language: memory.profile.language, level: memory.profile.level), on: connection)
            send(.initMessage(level: memory.profile.level, language: memory.profile.language), on: connection)
            sendSettings(for: connection)
            loadTranscript(slug: manager.slug, for: connection)
            send(.state((stateMachines[id] ?? SessionStateMachine()).state), on: connection)
        }
    }

    /// Handles `switch_profile` — loads an existing profile by slug, or (when
    /// `language`/`level` are supplied, mirroring the "create from the modal"
    /// path in app/server.py) creates a new one. Re-sanitizes the slug the
    /// same way `MemoryManager` itself does, so a crafted slug can't escape
    /// the profiles directory.
    private func switchProfile(slug rawSlug: String, language: String?, level: String?, for connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        generationGuard(for: connection).advance()
        hasGreeted.removeValue(forKey: id)
        let safeSlug = nameToSlug(rawSlug, fallback: "child")
        let manager = MemoryManager(profilesDir: Self.profilesDir(), slug: safeSlug)

        let memory: ChildMemory
        if let existing = manager.load() {
            memory = existing
        } else if let language, let level {
            memory = ChildMemory(profile: ChildProfile(name: safeSlug, language: language, level: level))
            manager.save(memory)
        } else {
            memory = ChildMemory(profile: ChildProfile(name: safeSlug))
            manager.save(memory)
        }

        memoryManagers[id] = manager
        memories[id] = memory
        stateMachines[id] = SessionStateMachine()

        send(.profiles(list: manager.listProfiles(), active: manager.slug), on: connection)
        send(.memoryLoaded(name: memory.profile.name, age: memory.profile.age, language: memory.profile.language, level: memory.profile.level), on: connection)
        send(.initMessage(level: memory.profile.level, language: memory.profile.language), on: connection)
        sendSettings(for: connection)
        loadTranscript(slug: manager.slug, for: connection)
    }

    /// Onboarding counterpart to `transcribeAndContinue` — same off-main-actor
    /// whisper_full call, but hands the result to `continueOnboarding`
    /// instead of the LLM reply flow.
    private func transcribeForOnboarding(samples: [Float], engine: WhisperEngine, step: OnboardingStep, connection: NWConnection) {
        Task.detached {
            let text = try? engine.transcribe(samples: samples, language: "en")
            await MainActor.run { [weak self] in
                self?.continueOnboarding(transcript: text, step: step, connection: connection)
            }
        }
    }

    /// Runs whisper_full off the main actor (it's a blocking C call) and,
    /// once done, feeds the result back into that connection's state machine
    /// — mirrors app/server.py's listening -> thinking -> transcript flow.
    /// Continues into LLM generation (below) when both a transcript and an
    /// engine are available; otherwise stays in `.thinking` with no further
    /// progress, same as before whisper.cpp was wired in.
    private func transcribeAndContinue(samples: [Float], engine: WhisperEngine, connection: NWConnection) {
        let language = memories[ObjectIdentifier(connection)]?.profile.language ?? "en"
        Task.detached {
            let text = try? engine.transcribe(samples: samples, language: language)
            await MainActor.run { [weak self] in
                guard let self else { return }
                let id = ObjectIdentifier(connection)
                var machine = self.stateMachines[id] ?? SessionStateMachine()
                let trimmed = text?.trimmingCharacters(in: .whitespaces)
                let hasText = trimmed?.isEmpty == false
                machine.transcribed(hasText ? trimmed : nil)
                self.stateMachines[id] = machine
                if hasText, let trimmed {
                    let textHtml = furiganaFormatter().annotateFor(trimmed, language: language)
                    self.send(.transcript(text: trimmed, textHtml: textHtml), on: connection)
                }
                self.send(.state(machine.state), on: connection)

                if hasText, let trimmed, let llama = self.llamaEngine {
                    self.replyAndContinue(userMessage: trimmed, engine: llama, connection: connection)
                }
            }
        }
    }

    /// Runs llama_decode off the main actor to get the full reply (segmented
    /// into sentences via NovaCore's SentenceSegmenter, inside LlamaEngine),
    /// then hands each sentence to `speakSentences` in turn — mirrors
    /// app/pipeline/llm.py's streaming boundary crossed with
    /// app/pipeline/tts.py's speak_streaming: each sentence becomes both a
    /// `sentence` text message and real spoken audio with live amplitude,
    /// one at a time, exactly like the desktop app's per-sentence handoff.
    private func replyAndContinue(userMessage: String, engine: LlamaEngine, connection: NWConnection) {
        var machine = stateMachines[ObjectIdentifier(connection)] ?? SessionStateMachine()
        machine.beginSpeaking()
        stateMachines[ObjectIdentifier(connection)] = machine
        send(.state(machine.state), on: connection)

        let profile = memories[ObjectIdentifier(connection)]?.profile
        let language = profile?.language ?? "en"
        var builder = PromptBuilder(basePrompt: Self.placeholderBasePrompt, language: language, level: profile?.level ?? "A")
        builder.memory = memories[ObjectIdentifier(connection)]
        builder.appearance = currentAppearance
        let systemPrompt = builder.build()
        let prompt = "\(systemPrompt)\n\nChild: \(userMessage)\nNova:"
        let generationToken = generationGuard(for: connection).currentToken()

        Task.detached {
            var sentences: [String] = []
            try? engine.generate(prompt: prompt) { sentence in sentences.append(sentence) }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.generationGuard(for: connection).apply(generationToken) {
                    self.speechInterrupted = false
                    self.speakSentences(sentences, index: 0, language: language, connection: connection)
                    let turnId = self.recordTurn(transcript: userMessage, replySentences: sentences, language: language, connection: connection)
                    self.extractMemory(transcript: userMessage, replySentences: sentences, engine: engine, connection: connection, token: generationToken, turnId: turnId)
                }
            }
        }
    }

    /// Port of app/server.py's per-turn `conv_turn_n`/`transcript_store`
    /// bookkeeping: assigns the next turn id, sends `conversation_turn`, and
    /// appends it to the connection's `TranscriptStore` (display-only
    /// history — never fed back into the LLM prompt, unlike `ChildMemory`).
    /// Returns the assigned id so `extractMemory` can attach a correction to
    /// the same turn.
    @discardableResult
    private func recordTurn(transcript: String, replySentences: [String], language: String, connection: NWConnection) -> Int? {
        guard !replySentences.isEmpty else { return nil }
        let id = ObjectIdentifier(connection)
        guard let store = transcriptStores[id] else { return nil }
        let turnId = (convTurnIds[id] ?? 0) + 1
        convTurnIds[id] = turnId
        let fullReply = replySentences.joined(separator: " ")
        let formatter = furiganaFormatter()
        send(.conversationTurn(
            id: turnId, you: transcript, nova: fullReply,
            youHtml: formatter.annotateFor(transcript, language: language),
            novaHtml: formatter.annotateFor(fullReply, language: language)
        ), on: connection)
        store.appendTurn(id: turnId, you: transcript, nova: fullReply)
        return turnId
    }

    /// Port of `app/memory_extractor.py`'s post-turn extraction: a small
    /// focused LLM call (fire-and-forget, after the reply itself) pulls a
    /// topic keyword and any grammar problem out of the exchange, saves them
    /// onto the profile's memory, and (if a problem was found) sends a
    /// `conversation_correction` + appends it to the transcript so the
    /// history panel can highlight what was gently fixed — the actual
    /// mechanism behind Nova "remembering" what a child talked about across
    /// sessions.
    ///
    /// Scoped down from the desktop original: extracts from the *full*
    /// generated reply rather than tracking exactly which sentences were
    /// spoken before a possible `stop_speak` barge-in (that needs threading
    /// a partial-speech accumulator through `speakSentences`' recursion —
    /// not done here). Silent on any failure (no engine, empty reply) —
    /// matches the "never blocks the conversation" guarantee
    /// `MemoryExtractor.extract` provides on desktop.
    private func extractMemory(transcript: String, replySentences: [String], engine: LlamaEngine, connection: NWConnection, token: GenerationGuard.Token, turnId: Int?) {
        guard !replySentences.isEmpty else { return }
        let fullReply = replySentences.joined(separator: " ")
        Task.detached { [weak self] in
            let result = MemoryExtractor.extract(transcript: transcript, reply: fullReply, engine: engine)
            await MainActor.run {
                guard let self else { return }
                // Re-checked after the extraction call itself (a second,
                // shorter async gap a profile swap could also land in) —
                // not just the token captured before the reply's own
                // generation, though `replyAndContinue`'s caller already
                // guarded that outer gap.
                self.generationGuard(for: connection).apply(token) {
                    let id = ObjectIdentifier(connection)
                    guard let manager = self.memoryManagers[id], var memory = self.memories[id] else { return }
                    if let topic = result.topic {
                        manager.update(&memory, topic: topic)
                    }
                    if let problem = result.parseProblem() {
                        manager.update(&memory, problemType: problem.type, example: problem.example, correction: problem.correction)
                        if let turnId, let store = self.transcriptStores[id] {
                            let language = memory.profile.language
                            let formatter = self.furiganaFormatter()
                            self.send(.conversationCorrection(
                                id: turnId, kind: problem.type, wrong: problem.example, right: problem.correction,
                                wrongHtml: formatter.annotateFor(problem.example, language: language),
                                rightHtml: formatter.annotateFor(problem.correction, language: language)
                            ), on: connection)
                            store.appendCorrection(id: turnId, kind: problem.type, wrong: problem.example, right: problem.correction)
                        }
                    }
                    self.memories[id] = memory
                    manager.save(memory)
                }
            }
        }
    }

    /// Port of app/server.py's `_send_greeting` — the spoken "Welcome back!"
    /// (or, for a returning profile with a recent topic, one that names it)
    /// a child hears the moment they tap "Say hi to Nova!". Picks the most
    /// recently-mentioned topic the same way desktop does (sort by
    /// `lastMentioned` descending, take the first).
    private func sendGreeting(for connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        guard let profile = memories[id]?.profile else { return }
        let language = profile.language
        let ageNote = ageSuffix(profile.age, language: language)
        let text: String
        if let recentTopic = memories[id]?.topics.max(by: { $0.lastMentioned < $1.lastMentioned })?.keyword {
            text = systemText("greeting_returning_topic", language: language, ["name": profile.name, "age_suffix": ageNote, "topic": recentTopic])
        } else {
            text = systemText("greeting_returning", language: language, ["name": profile.name, "age_suffix": ageNote])
        }
        replay(text, for: connection)
    }

    /// Re-speaks `text` outside the normal reply flow — port of
    /// app/server.py's `_speak_interruptible`: `speaking` -> `sentence` ->
    /// TTS with live amplitude (barge-in-able via `stopSpeak`, same as a
    /// live reply) -> `amplitude: 0` -> `idle`. No transcript, no memory.
    private func replay(_ text: String, for connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        var machine = stateMachines[id] ?? SessionStateMachine()
        machine.beginSpeaking()
        stateMachines[id] = machine
        send(.state(machine.state), on: connection)

        let language = memories[id]?.profile.language ?? "en"
        let textHtml = furiganaFormatter().annotateFor(text, language: language)
        send(.sentence(text: text, textHtml: textHtml), on: connection)

        speechInterrupted = false
        speak(text, language: language) { [weak self] amplitude in
            self?.send(.amplitude(value: amplitude), on: connection)
        } onFinish: { [weak self] in
            guard let self else { return }
            self.send(.amplitude(value: 0.0), on: connection)
            var machine = self.stateMachines[id] ?? SessionStateMachine()
            machine.finishSpeaking()
            self.stateMachines[id] = machine
            self.send(.state(machine.state), on: connection)
        }
    }

    /// Speaks `sentences[index...]` one at a time via `ttsEngine`, sending
    /// the text as a `sentence` message right before each one starts and
    /// streaming `amplitude` messages while it plays (drives the avatar's
    /// lip-sync in ui/src/main.js, same wire shape as the desktop app).
    /// Recurses to the next sentence on finish; transitions to `.idle` once
    /// all sentences have been spoken (or the barge-in path via
    /// `stopSpeak`/`ttsEngine.stop()` cut it short).
    private func speakSentences(_ sentences: [String], index: Int, language: String, connection: NWConnection) {
        guard !speechInterrupted, index < sentences.count else {
            let id = ObjectIdentifier(connection)
            var machine = stateMachines[id] ?? SessionStateMachine()
            machine.finishSpeaking()
            stateMachines[id] = machine
            send(.state(machine.state), on: connection)
            return
        }
        let textHtml = furiganaFormatter().annotateFor(sentences[index], language: language)
        send(.sentence(text: sentences[index], textHtml: textHtml), on: connection)
        speak(sentences[index], language: language) { [weak self] amplitude in
            self?.send(.amplitude(value: amplitude), on: connection)
        } onFinish: { [weak self] in
            self?.speakSentences(sentences, index: index + 1, language: language, connection: connection)
        }
    }

    /// Builds the hiragana reading open_jtalk's morpheme analysis produces
    /// for `text` — the input `JapanesePhonemizer.phonemize` expects, per its
    /// documented contract (an already-resolved kana reading, not raw
    /// orthographic text). Falls back to a morpheme's surface when it has no
    /// reading (matches `FuriganaFormatter`'s same fallback).
    private func japaneseReading(for text: String) throws -> String {
        let morphemes = try morphemeAnalyzer.analyze(text)
        return morphemes.map { katakanaToHiragana($0.readingKatakana ?? $0.surface) }.joined()
    }

    /// TTS dispatch by language (Phase 5's `TTSRouter`): Japanese text goes
    /// through open_jtalk -> `JapanesePhonemizer` -> Kokoro; English goes
    /// through `EspeakPhonemizer` -> `PiperPhonemeIds` -> `PiperEngine`. Both
    /// need their respective model/data files loaded, and any failure along
    /// either path (missing files, a throw, empty output) falls back to
    /// `ttsEngine` (`AVSpeechSynthesizer`), mirroring the "never hard-fail"
    /// guarantee `_SystemTTSBackend` provides on desktop.
    private func speak(_ text: String, language: String, onAmplitude: @escaping (Double) -> Void, onFinish: @escaping () -> Void) {
        if language == "ja", let kokoroEngine, let kokoroVoiceStore, !(morphemeAnalyzer is UnavailableMorphemeAnalyzer) {
            Task.detached { [weak self] in
                guard let self else { return }
                do {
                    let hiragana = try await self.japaneseReading(for: text)
                    let phonemes = JapanesePhonemizer.phonemize(hiragana: hiragana)
                    let tokenCount = KokoroTokenizer.tokenize(phonemes).count
                    let style = try kokoroVoiceStore.styleVector(voice: Self.kokoroVoiceName, tokenCount: tokenCount)
                    let (samples, elapsedMs) = try Diagnostics.measureMs { try kokoroEngine.synthesize(phonemes: phonemes, style: style) }
                    Diagnostics.log("tts_latency", ["engine": "kokoro", "ms": String(elapsedMs), "memory_mb": String(Diagnostics.memoryFootprintMB())])
                    await MainActor.run {
                        self.kokoroPlayer.play(samples: samples, sampleRate: KokoroEngine.sampleRate, onAmplitude: onAmplitude, onFinish: onFinish)
                    }
                } catch {
                    await MainActor.run {
                        self.ttsEngine.speak(text, language: language, onAmplitude: onAmplitude, onFinish: onFinish)
                    }
                }
            }
            return
        }
        if language == "en", let espeakPhonemizer, let piperEngine, let piperConfig {
            Task.detached { [weak self] in
                guard let self else { return }
                do {
                    try espeakPhonemizer.setVoice(piperConfig.espeakVoice)
                    let clauses = espeakPhonemizer.phonemize(text)
                    let allPhonemes = clauses.map { $0.phonemes + $0.terminator }.joined()
                    let ids = PiperPhonemeIds.phonemesToIds(allPhonemes, idMap: piperConfig.phonemeIdMap)
                    // Phase 0 Spike 3's go/no-go: <300-500ms end-to-end for a
                    // ~1-sentence utterance.
                    let (samples, elapsedMs) = try Diagnostics.measureMs { try piperEngine.synthesize(phonemeIds: ids, config: piperConfig) }
                    Diagnostics.log("tts_latency", ["engine": "piper", "ms": String(elapsedMs), "memory_mb": String(Diagnostics.memoryFootprintMB())])
                    await MainActor.run {
                        self.piperPlayer.play(samples: samples, sampleRate: piperConfig.sampleRate, onAmplitude: onAmplitude, onFinish: onFinish)
                    }
                } catch {
                    await MainActor.run {
                        self.ttsEngine.speak(text, language: language, onAmplitude: onAmplitude, onFinish: onFinish)
                    }
                }
            }
            return
        }
        ttsEngine.speak(text, language: language, onAmplitude: onAmplitude, onFinish: onFinish)
    }

    private func send(_ message: ServerMessage, on connection: NWConnection) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let data = try? encoder.encode(message) else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
    }
}
