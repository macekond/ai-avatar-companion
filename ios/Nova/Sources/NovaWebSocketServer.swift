import Foundation
import Network
import NovaCore

/// No iOS port of open_jtalk exists yet (ios/spikes/04-tts-kokoro-openjtalk)
/// — this analyzer always fails, so `FuriganaFormatter` takes its documented
/// fallback path (plain escaped text) for Japanese profiles instead of
/// producing `<ruby>` markup. Real morpheme analysis lands with that spike.
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

    /// Always available (no model download needed) — see SystemTTSEngine's
    /// doc comment for why this, not Piper/Kokoro, is what actually produces
    /// audio right now.
    private let ttsEngine = SystemTTSEngine()

    /// Set by `stopSpeak` (barge-in) so `speakSentences`'s recursion stops
    /// dead instead of continuing to the next sentence — `ttsEngine.stop()`
    /// alone only cancels the *current* utterance; its onFinish callback
    /// still fires and would otherwise keep the reply going.
    private var speechInterrupted = false

    /// Base personality prompt — placeholder until Config (config.yaml's
    /// `personality.system_prompt`) is ported; PromptBuilder's own load-bearing
    /// assembly order (teaching frame -> level -> memory -> appearance ->
    /// LANGUAGE_LOCK last) is real and unaffected by this placeholder.
    private static let placeholderBasePrompt = "You are Nova, a warm and encouraging language-practice companion for children."

    public init(port: UInt16) {
        self.port = port
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

    public func start() throws {
        try recorder.start()
        if let modelPath = Self.modelPath("ggml-small.bin") {
            whisperEngine = try? WhisperEngine(modelPath: modelPath)
        }
        if let modelPath = Self.modelPath("llm.gguf") {
            llamaEngine = try? LlamaEngine(modelPath: modelPath)
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
        let id = ObjectIdentifier(connection)
        connections.removeValue(forKey: id)
        stateMachines.removeValue(forKey: id)
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
        case .avatarLoaded:
            // main.js sends this immediately on socket open and waits for
            // `init` to hide its "Connecting…" overlay (see ws.onopen /
            // markServerReady in ui/src/main.js).
            let (memory, isNewProfile) = loadOrCreateDefaultProfile(for: connection)
            if isNewProfile {
                startOnboarding(for: connection)
                return
            }
            let manager = memoryManagers[ObjectIdentifier(connection)]!
            send(.profiles(list: manager.listProfiles(), active: manager.slug), on: connection)
            send(.memoryLoaded(name: memory.profile.name, age: memory.profile.age, language: memory.profile.language, level: memory.profile.level), on: connection)
            send(.initMessage(level: memory.profile.level, language: memory.profile.language), on: connection)
            // app/server.py sends this right after connect too (line 771) —
            // without it the state label never leaves its static HTML
            // placeholder text, since applyState() only fires on a `state`
            // message and nothing else updates that element.
            send(.state(machine.state), on: connection)
            return
        case .start:
            machine.start()
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
            machine.stopSpeak()
        case .switchProfile(let slug, let language, let level):
            switchProfile(slug: slug, language: language, level: level, for: connection)
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
            let manager = isActiveProfile ? memoryManagers[id]! : MemoryManager(profilesDir: Self.profilesDir(), slug: slug)

            if manager.listProfiles().count <= 1 {
                send(.profileError(message: "Can't remove the only child."), on: connection)
            } else {
                _ = manager.deleteProfile(slug: slug)
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
                    let textHtml = FuriganaFormatter(analyzer: UnavailableMorphemeAnalyzer()).annotateFor(trimmed, language: language)
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
        let systemPrompt = builder.build()
        let prompt = "\(systemPrompt)\n\nChild: \(userMessage)\nNova:"

        Task.detached {
            var sentences: [String] = []
            try? engine.generate(prompt: prompt) { sentence in sentences.append(sentence) }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.speechInterrupted = false
                self.speakSentences(sentences, index: 0, language: language, connection: connection)
            }
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
        let textHtml = FuriganaFormatter(analyzer: UnavailableMorphemeAnalyzer()).annotateFor(sentences[index], language: language)
        send(.sentence(text: sentences[index], textHtml: textHtml), on: connection)
        ttsEngine.speak(sentences[index], language: language) { [weak self] amplitude in
            self?.send(.amplitude(value: amplitude), on: connection)
        } onFinish: { [weak self] in
            self?.speakSentences(sentences, index: index + 1, language: language, connection: connection)
        }
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
