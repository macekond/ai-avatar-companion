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
///
/// **Single-connection assumption.** Most mutable state here is correctly
/// scoped per connection (`[ObjectIdentifier: ...]` dictionaries — see
/// `drop(_:)`), because a stale value from one session must never leak into
/// another's. A handful of properties are deliberately *not* per-connection
/// — `setupPhase`, `speechInterrupted`, `currentAppearance`, `ttsEngine`,
/// `piperPlayer`, `kokoroPlayer` — because this app only ever hosts one
/// local WKWebView connection at a time (same assumption `MicRecorder`
/// documents for itself). That assumption isn't enforced anywhere: if a
/// WKWebView reload ever created a new `NWConnection` before the old one's
/// `.failed`/`.cancelled` fired and `drop(_:)` ran, both would briefly
/// coexist in `connections`, and e.g. a `stop_speak` from the dying
/// connection would cut off audio for the live one. Not attacker-exploitable
/// (there's no remote party to race), but real if this app ever grows a
/// second concurrent client — enforce (reject a second connection) or
/// re-scope these properties per-connection before that happens, rather than
/// relying on this comment alone.
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

    /// Port of `LLMPipeline`'s rolling `_history` (NovaCore, TDD'd) — this
    /// session's short-term conversational memory, cleared on every profile
    /// swap (matching `clear_history()`) so a new profile never inherits
    /// the previous child's in-session context.
    private var conversationHistories: [ObjectIdentifier: ConversationHistory] = [:]
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
    /// The LLM is Qwen2.5-1.5B-Instruct (Apache-2.0, multilingual incl.
    /// Japanese); it replaced an English-only SmolLM2-135M placeholder saved
    /// as "llm.gguf", hence the new filename (see `removeStaleModelFile`).
    private static let modelSpecs = [
        ModelSpec(filename: "ggml-small.bin", urlString: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin"),
        ModelSpec(filename: "llm-qwen2.5-1.5b-instruct-q4_k_m.gguf", urlString: "https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/main/qwen2.5-1.5b-instruct-q4_k_m.gguf"),
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
    /// Kokoro is only used for Japanese here, so this is one of Kokoro's
    /// native Japanese voices (the English `af_*` voices mangle Japanese).
    /// `nonisolated` because it's read from inside `speak`'s `Task.detached`
    /// Kokoro branch — a plain immutable constant is safe off the main
    /// actor, but static members of a `@MainActor` type are actor-isolated
    /// by default, which Swift 6's strict concurrency checking now enforces
    /// (this compiled as an implicit warning, not an error, under this
    /// project's current language mode, but is a real bug regardless).
    private static nonisolated let kokoroVoiceName = "jf_alpha"

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

    /// Deletes a device's previously-downloaded `llm.gguf` (the old
    /// SmolLM2-135M placeholder — see `modelSpecs`'s comment) if present,
    /// so it doesn't sit around as ~100MB of dead weight once every device
    /// has moved on to the new filename.
    private static func removeStaleModelFile() {
        guard let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let stalePath = dir.appendingPathComponent("models/llm.gguf")
        try? FileManager.default.removeItem(at: stalePath)
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
        if llamaEngine == nil, let modelPath = Self.modelPath("llm-qwen2.5-1.5b-instruct-q4_k_m.gguf") {
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
        let allSucceeded = await modelDownloader.downloadMissing(Self.modelSpecs) { [weak self] progress in
            self?.broadcast(.setupStatus(phase: "downloading_models", detail: progress.detail, progress: progress.fraction))
        }
        // Loading a freshly downloaded 1.1 GB LLM takes a while; don't leave a finished bar on screen meanwhile.
        setupPhase = "loading_models"
        broadcast(.setupStatus(phase: "loading_models", detail: ""))
        await loadAvailableEngines()
        // A silently-failed download used to still flip to "ready" here —
        // the app would look fully loaded while a required engine (usually
        // whisper or llama, the two gating this whole path — see `start()`)
        // stayed permanently nil, so PTT/replies just quietly did nothing.
        // Surface it as a real, distinct failure state instead.
        guard allSucceeded, whisperEngine != nil, llamaEngine != nil else {
            setupPhase = "download_failed"
            broadcast(.setupStatus(phase: "download_failed", detail: ""))
            return
        }
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
    /// Kokoro (`jf_alpha`) for Japanese. Real multi-voice support (like
    /// desktop's `_voices_for`/per-voice on-demand download) doesn't exist
    /// yet; a single-entry catalog is the honest reflection of that, not a
    /// placeholder to expand later without further model-download work.
    private func voiceCatalog(for language: String) -> [VoiceOption] {
        language == "ja"
            ? [VoiceOption(id: "jf_alpha", label: "Alpha")]
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
            // A voice saved before a catalog change (e.g. the old af_alloy) falls back to the default.
            voice: voices.contains(where: { $0.id == profile.voice }) ? profile.voice : voices.first?.id ?? ""
        ), on: connection)
    }

    /// Loads each listed profile just far enough to describe it on the wire
    /// (I1/I6/I9) — a slug alone mangles a display name like "Zoë" or "Mia
    /// Rose" client-side and carries no language. Falls back to the slug
    /// itself / "en" for a profile file that won't load rather than dropping
    /// it from the list the client already has from `list`/`active`.
    private func kidsInfo(for slugs: [String]) -> [KidInfo] {
        slugs.map { slug in
            let profile = MemoryManager(profilesDir: Self.profilesDir(), slug: slug).load()?.profile
            return KidInfo(slug: slug, name: profile?.name ?? slug, language: profile?.language ?? "en")
        }
    }

    private func broadcast(_ message: ServerMessage) {
        for connection in connections.values {
            send(message, on: connection)
        }
    }

    public func start() throws {
        Self.removeStaleModelFile()
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
        transcriptStores.removeValue(forKey: id)
        convTurnIds.removeValue(forKey: id)
        hasGreeted.removeValue(forKey: id)
        conversationHistories.removeValue(forKey: id)
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
            let id = ObjectIdentifier(connection)
            guard let memory = memories[id], let manager = memoryManagers[id] else {
                // No active profile for this connection yet — the picker
                // (choose_profile) replaces the old spoken onboarding; the
                // user must pick an existing kid or create one via
                // switch_profile before Nova appears.
                let list = MemoryManager(profilesDir: Self.profilesDir(), slug: "").listProfiles()
                send(.chooseProfile(list: list, kids: kidsInfo(for: list)), on: connection)
                return
            }
            send(.profiles(list: manager.listProfiles(), active: manager.slug, kids: kidsInfo(for: manager.listProfiles())), on: connection)
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
            // No active profile yet (picker still showing) — nothing to
            // greet, and no `state` frame either, matching every other
            // profile-gated message below.
            guard memories[ObjectIdentifier(connection)] != nil else { return }
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
            // No active profile yet — never start recording; `pttStop`
            // mirrors this so a stray turn never captures or transcribes
            // audio for a session that isn't tied to any child.
            guard memories[ObjectIdentifier(connection)] != nil else { return }
            machine.pttStart()
            recorder.pttStart()
        case .pttStop:
            guard memories[ObjectIdentifier(connection)] != nil else { return }
            // hasAudio mirrors app/pipeline/stt.py's MIN_DURATION_S floor
            // (STTConstants.hasEnoughAudio).
            let (hasAudio, samples) = recorder.pttStop()
            machine.pttStop(hasAudio: hasAudio)
            if hasAudio, let engine = whisperEngine {
                transcribeAndContinue(samples: samples, engine: engine, connection: connection)
            } else if !hasAudio {
                // Too little audio to even attempt STT — same "didn't catch
                // that" feedback as an empty transcript, so the talk button
                // never dies from a too-short tap (C3).
                speakDidntCatch(for: connection)
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
            guard memories[ObjectIdentifier(connection)] != nil else { return }
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
            memory.profile.levelByLanguage[language] = level
            memories[id] = memory
            memoryManagers[id]?.save(memory)
        case .setLanguage(let language):
            // Port of app/server.py's `set_language`: reject an unknown
            // language, else move to that language's own level — the last
            // one used for it (I8), so a switch away and back doesn't lose
            // progress, or its default when it has none yet — and reset
            // voice (a voice picked for one language is meaningless in
            // another) and resend `settings` so the UI's panel reflects the
            // new language's level/voice catalog.
            let id = ObjectIdentifier(connection)
            guard var memory = memories[id] else { break }
            guard Levels.languages.contains(language) else { break }
            let languageChanged = memory.profile.language != language
            memory.profile.levelByLanguage[memory.profile.language] = memory.profile.level
            memory.profile.language = language
            if let rememberedLevel = memory.profile.levelByLanguage[language], Levels.levelsFor(language).contains(rememberedLevel) {
                memory.profile.level = rememberedLevel
            } else {
                memory.profile.level = Levels.defaultLevel(for: language)
            }
            memory.profile.voice = ""
            memories[id] = memory
            memoryManagers[id]?.save(memory)
            if languageChanged {
                // Old-language history pulls a small model straight back to that language.
                conversationHistories.removeValue(forKey: id)
                generationGuard(for: connection).advance()
                // A reply dropped by the guard never reaches finishSpeaking, so leave speaking here or the session wedges.
                speechInterrupted = true
                ttsEngine.stop()
                kokoroPlayer.stop()
                piperPlayer.stop()
                machine.stopSpeak()
            }
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
            guard memories[ObjectIdentifier(connection)] != nil else { break }
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
            switchProfile(slug: slug, language: language, level: level, machine: &machine, for: connection)
        case .deleteProfile(let slug):
            // Refuses to delete the last remaining profile — mirrors
            // app/server.py's delete_profile guard (a parent must always
            // have at least one child profile to fall back to).
            let id = ObjectIdentifier(connection)
            let safeSlug = nameToSlug(slug, fallback: "")
            let isActiveProfile = !safeSlug.isEmpty && memoryManagers[id]?.slug == safeSlug
            // Delete through the connection's own live manager instance when
            // it's the active profile — MemoryManager's delete-tombstone is
            // an instance property, so deleting via a throwaway instance
            // would leave the live one un-tombstoned and able to resurrect
            // the file on its next save() (the same bug class the tombstone
            // pattern exists to prevent).
            let manager = isActiveProfile ? memoryManagers[id]! : MemoryManager(profilesDir: Self.profilesDir(), slug: safeSlug)

            // safeSlug (never the raw, untrusted `slug`) is what reaches
            // every filesystem-touching call below — a raw slug like
            // "../../../../Library/SomethingElse" used to reach
            // TranscriptStore unsanitized (it builds its path directly from
            // whatever slug it's given, unlike MemoryManager, which
            // re-sanitizes internally). Also mirrors app/server.py's
            // delete_profile guard: an empty or unknown slug is silently
            // ignored (`continue`), not turned into a deletion of whatever
            // an unsanitized path happens to resolve to.
            guard !safeSlug.isEmpty, manager.listProfiles().contains(safeSlug) else { break }

            if manager.listProfiles().count <= 1 {
                send(.profileError(message: "Can't remove the only child."), on: connection)
            } else {
                _ = manager.deleteProfile(slug: safeSlug)
                TranscriptStore(transcriptsDir: Self.transcriptsDir(), slug: safeSlug).delete()
                if isActiveProfile {
                    // The active profile is gone — fall back to another
                    // remaining profile (or create a fresh default if
                    // somehow none exist) rather than leaving this
                    // connection pointed at a deleted one. app/server.py
                    // does this same fallback via `_swap_profile`, which
                    // resets state to awaiting_start for exactly this
                    // reason — mirrored here rather than leaving whatever
                    // state the connection was in before the deletion
                    // (e.g. still "listening"/"speaking") incorrectly
                    // carried over into the fallback profile's session.
                    //
                    // These three resets belong here, not above the
                    // isActiveProfile check: app/server.py only resets this
                    // session state in the `target == mem_mgr.slug` branch of
                    // its delete_profile handler — deleting an unrelated,
                    // inactive profile shouldn't wipe the greeting flag,
                    // conversation history, or in-flight generation for a
                    // completely different, still-active session.
                    generationGuard(for: connection).advance()
                    hasGreeted.removeValue(forKey: id)
                    conversationHistories.removeValue(forKey: id)
                    machine = SessionStateMachine()
                    memories.removeValue(forKey: id)
                    memoryManagers.removeValue(forKey: id)
                    let remaining = manager.listProfiles()
                    guard let nextSlug = remaining.first else {
                        // Unreachable in practice (deleting the last profile
                        // is refused above), but coherent: no profile left
                        // for this connection, so fall back to the same
                        // no-profile picker state avatarLoaded uses, rather
                        // than resurrecting a "child" default.
                        send(.chooseProfile(list: [], kids: []), on: connection)
                        return
                    }
                    let nextManager = MemoryManager(profilesDir: Self.profilesDir(), slug: nextSlug)
                    let fallback = nextManager.load() ?? ChildMemory(profile: ChildProfile(name: nextSlug))
                    memoryManagers[id] = nextManager
                    memories[id] = fallback
                    send(.profiles(list: nextManager.listProfiles(), active: nextManager.slug, kids: kidsInfo(for: nextManager.listProfiles())), on: connection)
                    send(.memoryLoaded(name: fallback.profile.name, age: fallback.profile.age, language: fallback.profile.language, level: fallback.profile.level), on: connection)
                    send(.initMessage(level: fallback.profile.level, language: fallback.profile.language), on: connection)
                    sendSettings(for: connection)
                    loadTranscript(slug: nextManager.slug, for: connection)
                } else if let activeManager = memoryManagers[id] {
                    send(.profiles(list: activeManager.listProfiles(), active: activeManager.slug, kids: kidsInfo(for: activeManager.listProfiles())), on: connection)
                }
            }
            // No `default:` — every ClientMessage case is already handled
            // explicitly above (Xcode correctly flags an extra `default`
            // here as dead code, since the switch is already exhaustive).
        }
        send(.state(machine.state), on: connection)
    }

    /// Handles `switch_profile` — loads an existing profile by slug, or (when
    /// `language`/`level` are supplied, matching the profile-picker's "new
    /// kid" form, or any missing language defaulting to "en") creates one.
    /// Re-sanitizes the slug the same way `MemoryManager` itself does, so a
    /// crafted slug can't escape the profiles directory. A name that
    /// sanitizes to an empty slug (no ASCII letters/digits, e.g. "李明") is
    /// rejected with `profile_error` rather than silently collapsing onto a
    /// shared "child" profile — see the root CLAUDE.md's `name_to_slug` note.
    ///
    /// `machine` is `dispatch`'s own `inout` parameter, not a fresh
    /// `stateMachines[id]` lookup — this used to write straight to
    /// `stateMachines[id]` instead, which `handle()`'s post-dispatch
    /// `stateMachines[id] = machine` then immediately clobbered with
    /// whatever `machine` held from *before* the switch (`dispatch` sends
    /// `machine.state` unconditionally at the end of its switch too), so a
    /// switch silently reverted itself: the client was told the outgoing
    /// profile's stale state, and the persisted machine was never actually
    /// reset. The Python original explicitly sends `state: awaiting_start`
    /// after `_swap_profile` for exactly this reason ("parks back in
    /// awaiting_start rather than auto-greeting, consistent with the initial
    /// connect") — mutating the same `inout` the caller already sends from
    /// achieves the same thing without a second explicit send.
    private func switchProfile(slug rawSlug: String, language: String?, level: String?, machine: inout SessionStateMachine, for connection: NWConnection) {
        // `profileSlug` (not plain `nameToSlug`) so a name with no ASCII
        // letters/digits at all (e.g. "はな") still gets a real slug (C1)
        // instead of being rejected outright — it only falls through to
        // `nameToSlug`'s own empty-fallback rejection for genuinely empty or
        // punctuation-only input.
        guard let safeSlug = profileSlug(forName: rawSlug) else {
            send(.profileError(message: "Please use letters or numbers in the name."), on: connection)
            return
        }
        let manager = MemoryManager(profilesDir: Self.profilesDir(), slug: safeSlug)

        // `language` present is the "create a new kid" intent (the picker's
        // new-kid form / settings "+" flow); picking an existing kid sends
        // only `slug`. A duplicate name under that intent must not silently
        // open the existing kid (I2) — reject it and leave this connection's
        // state untouched, rather than advancing past the checks below.
        if language != nil, let existing = manager.load() {
            send(.profileError(message: "There's already a kid called \(existing.profile.name). Tap their name to continue."), on: connection)
            return
        }

        let id = ObjectIdentifier(connection)
        generationGuard(for: connection).advance()
        hasGreeted.removeValue(forKey: id)
        conversationHistories.removeValue(forKey: id)

        let memory: ChildMemory
        if let existing = manager.load() {
            memory = existing
        } else {
            let displayName = rawSlug.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedLanguage = language ?? "en"
            let resolvedLevel = level ?? Levels.defaultLevel(for: resolvedLanguage)
            memory = ChildMemory(profile: ChildProfile(
                name: displayName.isEmpty ? safeSlug : displayName,
                language: resolvedLanguage, level: resolvedLevel
            ))
            manager.save(memory)
        }

        memoryManagers[id] = manager
        memories[id] = memory
        machine = SessionStateMachine()

        send(.profiles(list: manager.listProfiles(), active: manager.slug, kids: kidsInfo(for: manager.listProfiles())), on: connection)
        send(.memoryLoaded(name: memory.profile.name, age: memory.profile.age, language: memory.profile.language, level: memory.profile.level), on: connection)
        send(.initMessage(level: memory.profile.level, language: memory.profile.language), on: connection)
        sendSettings(for: connection)
        loadTranscript(slug: manager.slug, for: connection)
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
                // Whisper emits annotations like "[Music]"/"(音楽)" on silence
                // instead of an empty string (I5) — those must not be treated
                // as something the child said.
                let hasText = trimmed.map { !$0.isEmpty && !isNonSpeechTranscript($0) } ?? false
                machine.transcribed(hasText ? trimmed : nil)
                self.stateMachines[id] = machine
                if hasText, let trimmed {
                    let textHtml = furiganaFormatter().annotateFor(trimmed, language: language)
                    self.send(.transcript(text: trimmed, textHtml: textHtml), on: connection)
                }
                self.send(.state(machine.state), on: connection)

                if hasText, let trimmed, let llama = self.llamaEngine {
                    self.replyAndContinue(userMessage: trimmed, engine: llama, connection: connection)
                } else if !hasText {
                    self.speakDidntCatch(for: connection)
                }
            }
        }
    }

    /// Speaks the "didn't catch that" line and returns the session to idle
    /// once it finishes — port of app/server.py's empty-transcript path
    /// (lines ~1179-1188). Reached both when STT returns nothing and when
    /// `ptt_stop` had too little audio to even attempt STT
    /// (`SessionStateMachine.pttStop`/`transcribed` already moved the state
    /// to `.didntCatch` in both cases before this is called).
    private func speakDidntCatch(for connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        let language = memories[id]?.profile.language ?? "en"
        let sorry = systemText("sorry", language: language, [:])
        let textHtml = furiganaFormatter().annotateFor(sorry, language: language)
        send(.sentence(text: sorry, textHtml: textHtml), on: connection)

        speechInterrupted = false
        speak(sorry, language: language) { [weak self] amplitude in
            self?.send(.amplitude(value: amplitude), on: connection)
        } onFinish: { [weak self] in
            guard let self else { return }
            self.send(.amplitude(value: 0.0), on: connection)
            var machine = self.stateMachines[id] ?? SessionStateMachine()
            machine.didntCatchAcknowledged()
            self.stateMachines[id] = machine
            self.send(.state(machine.state), on: connection)
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
        let basePrompt = PromptBuilder.defaultBasePrompt(childName: profile?.name ?? "friend")
        var builder = PromptBuilder(basePrompt: basePrompt, language: language, level: profile?.level ?? "A")
        builder.memory = memories[ObjectIdentifier(connection)]
        builder.appearance = currentAppearance
        let systemPrompt = builder.build()
        // Port of app/pipeline/llm.py's rolling `_history`: prior exchanges
        // (this session only — cross-session context is `ChildMemory`'s job)
        // sent as their own role-tagged messages ahead of the new turn, so
        // Nova can refer back to what was just said instead of starting
        // fresh every single turn. Real chat-template messages, not a flat
        // string — see `buildChatMessages`/`LlamaBridge`.
        let history = conversationHistories[ObjectIdentifier(connection)] ?? ConversationHistory()
        let messages = buildChatMessages(systemPrompt: systemPrompt, history: history, userMessage: userMessage)
        let generationToken = generationGuard(for: connection).currentToken()

        Task.detached {
            // Genuinely safe despite the warning Swift 6 would raise here:
            // `engine.generate` calls its `onSentence` closure synchronously,
            // one call at a time, entirely within this same detached task
            // before the function returns — there's no real concurrent
            // access to `sentences`, just a mutable local captured by an
            // `@escaping` (not `@Sendable`) closure that the compiler's
            // conservative concurrency checker can't prove is single-threaded.
            nonisolated(unsafe) var sentences: [String] = []
            do {
                try engine.generate(messages: messages) { sentence in sentences.append(sentence) }
            } catch {
                Diagnostics.log("llm_generation_failed", ["caller": "reply"])
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.generationGuard(for: connection).apply(generationToken) {
                    self.speechInterrupted = false
                    self.speakSentences(sentences, index: 0, language: language, connection: connection)
                    let turnId = self.recordTurn(transcript: userMessage, replySentences: sentences, language: language, connection: connection)
                    self.extractMemory(transcript: userMessage, replySentences: sentences, engine: engine, language: language, connection: connection, token: generationToken, turnId: turnId)
                    if !sentences.isEmpty {
                        let id = ObjectIdentifier(connection)
                        var history = self.conversationHistories[id] ?? ConversationHistory()
                        history.append(you: userMessage, nova: sentences.joined(separator: " "))
                        self.conversationHistories[id] = history
                    }
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
    private func extractMemory(transcript: String, replySentences: [String], engine: LlamaEngine, language: String, connection: NWConnection, token: GenerationGuard.Token, turnId: Int?) {
        guard !replySentences.isEmpty else { return }
        let fullReply = replySentences.joined(separator: " ")
        Task.detached { [weak self] in
            let result = MemoryExtractor.extract(transcript: transcript, reply: fullReply, engine: engine, language: language)
            await MainActor.run { [weak self] in
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
        let hasTalkedBefore = !(memories[id]?.topics.isEmpty ?? true) || (convTurnIds[id] ?? 0) > 0
        if !hasTalkedBefore {
            text = systemText("greeting_new", language: language, ["name": profile.name, "avatar": "Nova"])
        } else if let recentTopic = memories[id]?.topics.max(by: { $0.lastMentioned < $1.lastMentioned })?.keyword {
            text = systemText("greeting_returning_topic", language: language, ["name": profile.name, "age_suffix": ageNote, "topic": recentTopic])
        } else {
            text = systemText("greeting_returning", language: language, ["name": profile.name, "age_suffix": ageNote])
        }
        // Nova-only turn (you: "") so the greeting shows in the Conversation
        // panel and survives reconnect via TranscriptStore, same as any other
        // reply (I7). Recorded before speaking, using the pre-increment
        // `hasTalkedBefore` computed above.
        recordTurn(transcript: "", replySentences: [text], language: language, connection: connection)
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
    ///
    /// `analyzer` is passed in explicitly rather than read from
    /// `self.morphemeAnalyzer` — this must be `nonisolated` so `speak`'s
    /// Japanese branch can actually run open_jtalk's blocking native call
    /// off the main actor. A non-`nonisolated` method on this `@MainActor`
    /// class still executes its body on the main actor even when called with
    /// `await` from inside `Task.detached`, which silently defeated that
    /// detached wrapper here — the same failure mode
    /// `loadAvailableEngines`'s doc comment warns about ("engine construction
    /// on the main actor stalled ping/receive handling long enough that a
    /// connected client's socket timed out"), just reintroduced per-reply
    /// instead of at load time. Reading `self.morphemeAnalyzer` directly from
    /// a `nonisolated` method isn't safe (it's main-actor-isolated mutable
    /// state), so the caller captures it synchronously on the main actor
    /// first and passes it through.
    private nonisolated func japaneseReading(for text: String, analyzer: MorphemeAnalyzing) throws -> String {
        let morphemes = try analyzer.analyze(text)
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
            // Captured here (synchronously, still on the main actor) rather
            // than read inside the detached task — see japaneseReading's doc
            // comment on why a nonisolated method can't safely read
            // self.morphemeAnalyzer directly.
            let analyzer = morphemeAnalyzer
            Task.detached { [weak self] in
                guard let self else { return }
                do {
                    let hiragana = try self.japaneseReading(for: text, analyzer: analyzer)
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
