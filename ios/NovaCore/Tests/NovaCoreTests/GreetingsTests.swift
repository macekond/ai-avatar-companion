import XCTest
@testable import NovaCore

final class GreetingsTests: XCTestCase {
    func test_ageSuffix_nilAge_isEmpty() {
        XCTAssertEqual(ageSuffix(nil, language: "en"), "")
        XCTAssertEqual(ageSuffix(nil, language: "ja"), "")
    }

    func test_ageSuffix_english() {
        XCTAssertEqual(ageSuffix(8, language: "en"), " (age 8)")
    }

    func test_ageSuffix_japanese() {
        XCTAssertEqual(ageSuffix(8, language: "ja"), "（8才）")
    }

    func test_systemText_englishTemplate_formatsPlaceholders() {
        let text = systemText("greeting_new", language: "en", ["name": "Lily", "avatar": "Nova"])
        XCTAssertEqual(text, "Hi Lily! I'm Nova, your language practice friend. What did you do today?")
    }

    func test_systemText_japaneseTemplate_formatsPlaceholders() {
        let text = systemText("onboarding_ask_age", language: "ja", ["name": "Lily"])
        XCTAssertEqual(text, "すてきな名前だね、Lilyさん！なんさい？")
    }

    func test_systemText_unknownLanguage_fallsBackToEnglish() {
        let en = systemText("sorry", language: "en", [:])
        let fr = systemText("sorry", language: "fr", [:])
        XCTAssertEqual(fr, en)
    }

    func test_systemText_greetingReturningWithTopic() {
        let text = systemText(
            "greeting_returning_topic", language: "en",
            ["name": "Lily", "age_suffix": " (age 8)", "topic": "football"]
        )
        XCTAssertEqual(text, "Welcome back, Lily (age 8)! Last time we talked about football. What's new today?")
    }
}
