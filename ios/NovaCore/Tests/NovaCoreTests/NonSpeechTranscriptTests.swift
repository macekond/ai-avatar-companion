import XCTest
@testable import NovaCore

final class NonSpeechTranscriptTests: XCTestCase {
    func test_empty_isNonSpeech() {
        XCTAssertTrue(isNonSpeechTranscript(""))
    }

    func test_whitespaceOnly_isNonSpeech() {
        XCTAssertTrue(isNonSpeechTranscript("   "))
    }

    func test_bracketedMusicAnnotation_isNonSpeech() {
        XCTAssertTrue(isNonSpeechTranscript("[Music]"))
    }

    func test_blankAudioAnnotation_isNonSpeech() {
        XCTAssertTrue(isNonSpeechTranscript("[BLANK_AUDIO]"))
    }

    func test_japaneseParentheticalMusic_isNonSpeech() {
        XCTAssertTrue(isNonSpeechTranscript("(音楽)"))
    }

    func test_japaneseParentheticalApplause_isNonSpeech() {
        XCTAssertTrue(isNonSpeechTranscript("(拍手)"))
    }

    func test_fullwidthParenAnnotation_isNonSpeech() {
        XCTAssertTrue(isNonSpeechTranscript("（音楽）"))
    }

    func test_lenticularBracketAnnotation_isNonSpeech() {
        XCTAssertTrue(isNonSpeechTranscript("【音楽】"))
    }

    func test_bareMusicSymbol_isNonSpeech() {
        XCTAssertTrue(isNonSpeechTranscript("♪"))
    }

    func test_musicSymbolSurroundedByAnnotations_isNonSpeech() {
        XCTAssertTrue(isNonSpeechTranscript("♪ (音楽) ♪"))
    }

    func test_punctuationOnly_isNonSpeech() {
        XCTAssertTrue(isNonSpeechTranscript("..."))
    }

    func test_englishSentenceWithParentheticalAside_isSpeech() {
        XCTAssertFalse(isNonSpeechTranscript("I like (red) apples"))
    }

    func test_japaneseGreeting_isSpeech() {
        XCTAssertFalse(isNonSpeechTranscript("こんにちは"))
    }

    func test_plainEnglishSentence_isSpeech() {
        XCTAssertFalse(isNonSpeechTranscript("I played football today"))
    }

    func test_wordAlongsideMusicSymbol_isSpeech() {
        XCTAssertFalse(isNonSpeechTranscript("Hello ♪"))
    }
}
