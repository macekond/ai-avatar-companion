import Foundation

/// Wire protocol — transcribed literally from `app/server.py`'s module
/// docstring (lines 1-67), the authoritative spec. Field names/shapes here
/// must match what `ui/src/main.js` already expects; this is a transcription
/// exercise, not a redesign.

// MARK: - Client → Server

public enum ClientMessage: Equatable {
    case start
    case pttStart
    case pttStop
    case stopSpeak
    case replay(text: String)
    case setLevel(level: String)
    case setLanguage(language: String)
    case setVoice(voice: String)
    case previewVoice(voice: String)
    /// `language`/`level` are present only when creating a brand-new profile
    /// from the modal (skips spoken onboarding); nil means load an existing one.
    case switchProfile(slug: String, language: String?, level: String?)
    case deleteProfile(slug: String)
    case avatarLoaded(key: String)
}

extension ClientMessage: Decodable {
    private enum CodingKeys: String, CodingKey {
        case type, text, level, language, voice, slug, key
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "start": self = .start
        case "ptt_start": self = .pttStart
        case "ptt_stop": self = .pttStop
        case "stop_speak": self = .stopSpeak
        case "replay": self = .replay(text: try container.decode(String.self, forKey: .text))
        case "set_level": self = .setLevel(level: try container.decode(String.self, forKey: .level))
        case "set_language": self = .setLanguage(language: try container.decode(String.self, forKey: .language))
        case "set_voice": self = .setVoice(voice: try container.decode(String.self, forKey: .voice))
        case "preview_voice": self = .previewVoice(voice: try container.decode(String.self, forKey: .voice))
        case "switch_profile":
            self = .switchProfile(
                slug: try container.decode(String.self, forKey: .slug),
                language: try container.decodeIfPresent(String.self, forKey: .language),
                level: try container.decodeIfPresent(String.self, forKey: .level)
            )
        case "delete_profile": self = .deleteProfile(slug: try container.decode(String.self, forKey: .slug))
        case "avatar_loaded": self = .avatarLoaded(key: try container.decode(String.self, forKey: .key))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: container, debugDescription: "Unknown client message type: \(type)"
            )
        }
    }
}

// MARK: - Server → Client

public struct VoiceOption: Codable, Equatable {
    public let id: String
    public let label: String

    public init(id: String, label: String) {
        self.id = id
        self.label = label
    }
}

public enum ServerMessage: Equatable {
    case initMessage(level: String, language: String)
    case settings(language: String, languages: [String], levels: [String], level: String, voices: [VoiceOption], voice: String)
    case voiceStatus(state: String, voice: String)
    case previewStatus(state: String, voice: String)
    case profiles(list: [String], active: String)
    case profileError(message: String)
    case onboardingStart
    case memoryLoaded(name: String, age: Int?, language: String, level: String)
    case state(SessionState)
    case transcript(text: String, textHtml: String?)
    case sentence(text: String, textHtml: String?)
    case amplitude(value: Double)
    case conversationReset
    case conversationTurn(id: Int, you: String, nova: String, youHtml: String?, novaHtml: String?)
    case conversationCorrection(id: Int, kind: String, wrong: String, right: String, wrongHtml: String?, rightHtml: String?)
}

extension ServerMessage: Encodable {
    private enum CodingKeys: String, CodingKey {
        case type, level, language, languages, levels, voices, voice
        case state, text, textHtml = "text_html", value
        case list, active, message
        case name, age
        case id, you, nova, youHtml = "you_html", novaHtml = "nova_html"
        case kind, wrong, right, wrongHtml = "wrong_html", rightHtml = "right_html"
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .initMessage(let level, let language):
            try c.encode("init", forKey: .type)
            try c.encode(level, forKey: .level)
            try c.encode(language, forKey: .language)
        case .settings(let language, let languages, let levels, let level, let voices, let voice):
            try c.encode("settings", forKey: .type)
            try c.encode(language, forKey: .language)
            try c.encode(languages, forKey: .languages)
            try c.encode(levels, forKey: .levels)
            try c.encode(level, forKey: .level)
            try c.encode(voices, forKey: .voices)
            try c.encode(voice, forKey: .voice)
        case .voiceStatus(let state, let voice):
            try c.encode("voice_status", forKey: .type)
            try c.encode(state, forKey: .state)
            try c.encode(voice, forKey: .voice)
        case .previewStatus(let state, let voice):
            try c.encode("preview_status", forKey: .type)
            try c.encode(state, forKey: .state)
            try c.encode(voice, forKey: .voice)
        case .profiles(let list, let active):
            try c.encode("profiles", forKey: .type)
            try c.encode(list, forKey: .list)
            try c.encode(active, forKey: .active)
        case .profileError(let message):
            try c.encode("profile_error", forKey: .type)
            try c.encode(message, forKey: .message)
        case .onboardingStart:
            try c.encode("onboarding_start", forKey: .type)
        case .memoryLoaded(let name, let age, let language, let level):
            try c.encode("memory_loaded", forKey: .type)
            try c.encode(name, forKey: .name)
            try c.encodeIfPresent(age, forKey: .age)
            try c.encode(language, forKey: .language)
            try c.encode(level, forKey: .level)
        case .state(let state):
            try c.encode("state", forKey: .type)
            try c.encode(state.rawValue, forKey: .state)
        case .transcript(let text, let textHtml):
            try c.encode("transcript", forKey: .type)
            try c.encode(text, forKey: .text)
            try c.encodeIfPresent(textHtml, forKey: .textHtml)
        case .sentence(let text, let textHtml):
            try c.encode("sentence", forKey: .type)
            try c.encode(text, forKey: .text)
            try c.encodeIfPresent(textHtml, forKey: .textHtml)
        case .amplitude(let value):
            try c.encode("amplitude", forKey: .type)
            try c.encode(value, forKey: .value)
        case .conversationReset:
            try c.encode("conversation_reset", forKey: .type)
        case .conversationTurn(let id, let you, let nova, let youHtml, let novaHtml):
            try c.encode("conversation_turn", forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(you, forKey: .you)
            try c.encode(nova, forKey: .nova)
            try c.encodeIfPresent(youHtml, forKey: .youHtml)
            try c.encodeIfPresent(novaHtml, forKey: .novaHtml)
        case .conversationCorrection(let id, let kind, let wrong, let right, let wrongHtml, let rightHtml):
            try c.encode("conversation_correction", forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(kind, forKey: .kind)
            try c.encode(wrong, forKey: .wrong)
            try c.encode(right, forKey: .right)
            try c.encodeIfPresent(wrongHtml, forKey: .wrongHtml)
            try c.encodeIfPresent(rightHtml, forKey: .rightHtml)
        }
    }
}
