import XCTest
@testable import NovaCore

/// Round-trip and wire-shape tests for ProtocolMessages — transcribed
/// literally from app/server.py's module docstring (lines 1-67), the
/// authoritative protocol spec. Field names/types are not to be inferred;
/// they must match what ui/src/main.js already expects on the wire.
final class ClientMessageTests: XCTestCase {
    func decode(_ json: String) throws -> ClientMessage {
        try JSONDecoder().decode(ClientMessage.self, from: Data(json.utf8))
    }

    func test_start() throws {
        XCTAssertEqual(try decode(#"{"type":"start"}"#), .start)
    }

    func test_pttStart() throws {
        XCTAssertEqual(try decode(#"{"type":"ptt_start"}"#), .pttStart)
    }

    func test_pttStop() throws {
        XCTAssertEqual(try decode(#"{"type":"ptt_stop"}"#), .pttStop)
    }

    func test_stopSpeak() throws {
        XCTAssertEqual(try decode(#"{"type":"stop_speak"}"#), .stopSpeak)
    }

    func test_replay() throws {
        XCTAssertEqual(try decode(#"{"type":"replay","text":"hi"}"#), .replay(text: "hi"))
    }

    func test_setLevel() throws {
        XCTAssertEqual(try decode(#"{"type":"set_level","level":"B"}"#), .setLevel(level: "B"))
    }

    func test_setLanguage() throws {
        XCTAssertEqual(try decode(#"{"type":"set_language","language":"ja"}"#), .setLanguage(language: "ja"))
    }

    func test_setVoice() throws {
        XCTAssertEqual(
            try decode(#"{"type":"set_voice","voice":"en_US-kristin-medium"}"#),
            .setVoice(voice: "en_US-kristin-medium")
        )
    }

    func test_previewVoice() throws {
        XCTAssertEqual(
            try decode(#"{"type":"preview_voice","voice":"jf_alpha"}"#),
            .previewVoice(voice: "jf_alpha")
        )
    }

    func test_switchProfile_existingSlugOnly() throws {
        XCTAssertEqual(
            try decode(#"{"type":"switch_profile","slug":"mia"}"#),
            .switchProfile(slug: "mia", language: nil, level: nil)
        )
    }

    func test_switchProfile_newProfileCarriesLanguageAndLevel() throws {
        XCTAssertEqual(
            try decode(#"{"type":"switch_profile","slug":"mia","language":"ja","level":"N5"}"#),
            .switchProfile(slug: "mia", language: "ja", level: "N5")
        )
    }

    func test_deleteProfile() throws {
        XCTAssertEqual(try decode(#"{"type":"delete_profile","slug":"mia"}"#), .deleteProfile(slug: "mia"))
    }

    func test_avatarLoaded() throws {
        XCTAssertEqual(
            try decode(#"{"type":"avatar_loaded","key":"VIPEHero_2707"}"#),
            .avatarLoaded(key: "VIPEHero_2707")
        )
    }

    func test_unknownType_throws() {
        XCTAssertThrowsError(try decode(#"{"type":"not_a_real_type"}"#))
    }
}

final class ServerMessageTests: XCTestCase {
    func roundTrip(_ message: ServerMessage) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let data = try encoder.encode(message)
        return String(data: data, encoding: .utf8)!
    }

    func test_state_encodesDocumentedShape() throws {
        // JSONEncoder does not guarantee key order across runs, so assert on
        // presence rather than an exact string.
        let json = try roundTrip(.state(.listening))
        XCTAssertTrue(json.contains(#""type":"state""#))
        XCTAssertTrue(json.contains(#""state":"listening""#))
    }

    func test_amplitude_encodesDocumentedShape() throws {
        let json = try roundTrip(.amplitude(value: 0.42))
        XCTAssertTrue(json.contains(#""type":"amplitude""#))
        XCTAssertTrue(json.contains(#""value":0.42"#))
    }

    func test_sentence_withoutFurigana_omitsHtmlField() throws {
        let json = try roundTrip(.sentence(text: "Hello!", textHtml: nil))
        XCTAssertFalse(json.contains("text_html"))
        XCTAssertTrue(json.contains(#""text":"Hello!""#))
    }

    func test_sentence_withFurigana_includesHtmlSiblingField() throws {
        let json = try roundTrip(.sentence(text: "私は", textHtml: "<ruby>私<rt>わたし</rt></ruby>は"))
        XCTAssertTrue(json.contains(#""text_html":"<ruby>私<rt>わたし</rt></ruby>は""#))
    }

    func test_memoryLoaded_encodesAllFields() throws {
        let json = try roundTrip(.memoryLoaded(name: "Lily", age: 8, language: "en", level: "A"))
        XCTAssertTrue(json.contains(#""name":"Lily""#))
        XCTAssertTrue(json.contains(#""age":8"#))
        XCTAssertTrue(json.contains(#""language":"en""#))
        XCTAssertTrue(json.contains(#""level":"A""#))
    }

    func test_conversationTurn_encodesIdYouNova() throws {
        let json = try roundTrip(.conversationTurn(id: 1, you: "hi", nova: "hello!", youHtml: nil, novaHtml: nil))
        XCTAssertTrue(json.contains(#""id":1"#))
        XCTAssertTrue(json.contains(#""you":"hi""#))
        XCTAssertTrue(json.contains(#""nova":"hello!""#))
    }

    func test_conversationCorrection_encodesWrongAndRight() throws {
        let json = try roundTrip(.conversationCorrection(
            id: 1, kind: "past_tense", wrong: "goed", right: "went", wrongHtml: nil, rightHtml: nil
        ))
        XCTAssertTrue(json.contains(#""wrong":"goed""#))
        XCTAssertTrue(json.contains(#""right":"went""#))
    }

    func test_setupStatus_encodesPhaseAndDetail() throws {
        let json = try roundTrip(.setupStatus(phase: "downloading_models", detail: "42%"))
        XCTAssertTrue(json.contains(#""phase":"downloading_models""#))
        XCTAssertTrue(json.contains(#""detail":"42%""#))
        XCTAssertFalse(json.contains("progress"))
    }

    func test_setupStatus_withProgress_encodesNumericProgress() throws {
        let json = try roundTrip(.setupStatus(phase: "downloading_models", detail: "File 1 of 2", progress: 0.5))
        XCTAssertTrue(json.contains(#""progress":0.5"#))
    }

    func test_profiles_encodesListAndActive() throws {
        let json = try roundTrip(.profiles(list: ["lily", "mia"], active: "lily", kids: nil))
        XCTAssertTrue(json.contains(#""list":["lily","mia"]"#))
        XCTAssertTrue(json.contains(#""active":"lily""#))
        XCTAssertFalse(json.contains("kids"), "kids must be omitted when nil, not sent as an empty/null field")
    }

    func test_profiles_withKids_encodesSlugNameLanguagePerKid() throws {
        let json = try roundTrip(.profiles(
            list: ["zo", "mia_rose"], active: "zo",
            kids: [KidInfo(slug: "zo", name: "Zoë", language: "en"), KidInfo(slug: "mia_rose", name: "Mia Rose", language: "ja")]
        ))
        XCTAssertTrue(json.contains(#""kids":["#))
        XCTAssertTrue(json.contains(#""slug":"zo""#))
        XCTAssertTrue(json.contains(#""name":"Zoë""#))
        XCTAssertTrue(json.contains(#""language":"en""#))
        XCTAssertTrue(json.contains(#""slug":"mia_rose""#))
        XCTAssertTrue(json.contains(#""name":"Mia Rose""#))
        XCTAssertTrue(json.contains(#""language":"ja""#))
    }

    func test_chooseProfile_encodesTypeAndList() throws {
        let json = try roundTrip(.chooseProfile(list: ["lily", "mia"], kids: nil))
        XCTAssertTrue(json.contains(#""type":"choose_profile""#))
        XCTAssertTrue(json.contains(#""list":["lily","mia"]"#))
        XCTAssertFalse(json.contains("kids"))
    }

    func test_chooseProfile_withKids_encodesPerKidFields() throws {
        let json = try roundTrip(.chooseProfile(
            list: ["zo"], kids: [KidInfo(slug: "zo", name: "Zoë", language: "en")]
        ))
        XCTAssertTrue(json.contains(#""slug":"zo""#))
        XCTAssertTrue(json.contains(#""name":"Zoë""#))
        XCTAssertTrue(json.contains(#""language":"en""#))
    }

    func test_settings_encodesFullShape() throws {
        let json = try roundTrip(.settings(
            language: "en", languages: ["en", "ja"], levels: ["Pre A", "A", "B", "C1", "C2"],
            level: "A", voices: [VoiceOption(id: "en_US-kristin-medium", label: "Kristin — bright, younger (US)")],
            voice: "en_US-kristin-medium"
        ))
        XCTAssertTrue(json.contains(#""languages":["en","ja"]"#))
        XCTAssertTrue(json.contains(#""id":"en_US-kristin-medium""#))
    }
}
