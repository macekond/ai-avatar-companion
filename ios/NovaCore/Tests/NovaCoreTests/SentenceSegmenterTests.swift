import XCTest
@testable import NovaCore

final class SentenceSegmenterTests: XCTestCase {
    func test_singleCompleteSentence_isExtracted() {
        var seg = SentenceSegmenter()
        let sentences = seg.feed("Hello there. ")
        XCTAssertEqual(sentences, ["Hello there."])
    }

    func test_incompleteFragment_isNotExtractedYet() {
        var seg = SentenceSegmenter()
        let sentences = seg.feed("Hello there")
        XCTAssertEqual(sentences, [])
    }

    func test_multipleSentencesInOneFeed_allExtracted() {
        var seg = SentenceSegmenter()
        let sentences = seg.feed("One. Two! Three? ")
        XCTAssertEqual(sentences, ["One.", "Two!", "Three?"])
    }

    func test_fragmentCarriesOverAcrossFeeds() {
        var seg = SentenceSegmenter()
        XCTAssertEqual(seg.feed("Hello "), [])
        XCTAssertEqual(seg.feed("there. And "), ["Hello there."])
        XCTAssertEqual(seg.feed("more."), [])
        XCTAssertEqual(seg.flush(), "And more.")
    }

    func test_closingQuoteAfterPunctuation_isConsumedAsBoundary() {
        // Matches Python's re.split semantics: the matched separator (an
        // optional closing quote + whitespace) is removed from the output
        // entirely, so the closing quote does not survive in either piece.
        var seg = SentenceSegmenter()
        let sentences = seg.feed("She said \"hi.\" Then left. ")
        XCTAssertEqual(sentences, ["She said \"hi.", "Then left."])
    }

    func test_flush_withNoRemainder_returnsEmptyString() {
        var seg = SentenceSegmenter()
        _ = seg.feed("Complete. ")
        XCTAssertEqual(seg.flush(), "")
    }

    func test_flush_returnsAndClearsRemainder() {
        var seg = SentenceSegmenter()
        _ = seg.feed("trailing fragment")
        XCTAssertEqual(seg.flush(), "trailing fragment")
        XCTAssertEqual(seg.flush(), "")
    }

    // MARK: - Japanese: no whitespace follows 。！？, unlike English's `. `

    func test_japanesePeriod_isExtractedImmediately_withoutTrailingWhitespace() {
        var seg = SentenceSegmenter()
        let sentences = seg.feed("これはテストです。")
        XCTAssertEqual(sentences, ["これはテストです。"])
    }

    func test_multipleJapaneseSentences_noWhitespace_allExtracted() {
        // Each 。/？ is a complete boundary on its own — unlike English,
        // there's no trailing whitespace to wait for, so all three split
        // immediately in one feed rather than the last staying buffered.
        var seg = SentenceSegmenter()
        let sentences = seg.feed("一つ目です。二つ目です。三つ目ですか？")
        XCTAssertEqual(sentences, ["一つ目です。", "二つ目です。", "三つ目ですか？"])
        XCTAssertEqual(seg.flush(), "")
    }

    func test_incompleteJapaneseFragment_isNotExtractedYet() {
        var seg = SentenceSegmenter()
        let sentences = seg.feed("まだ終わっていません")
        XCTAssertEqual(sentences, [])
    }

    func test_japaneseFragmentCarriesOverAcrossFeeds() {
        var seg = SentenceSegmenter()
        XCTAssertEqual(seg.feed("こんにちは。今日は"), ["こんにちは。"])
        XCTAssertEqual(seg.feed("いい天気ですね。"), ["今日はいい天気ですね。"])
    }

    func test_japaneseClosingBracketAfterPunctuation_staysWithItsSentence() {
        var seg = SentenceSegmenter()
        let sentences = seg.feed("「こんにちは！」今日は何をしたの？")
        XCTAssertEqual(sentences, ["「こんにちは！」", "今日は何をしたの？"])
    }

    func test_englishBehavior_isUnchangedByJapaneseSupport() {
        // Byte-for-byte identical to the pre-existing English tests above —
        // whitespace after `.!?` is still required for a split.
        var seg = SentenceSegmenter()
        XCTAssertEqual(seg.feed("One. Two! Three? "), ["One.", "Two!", "Three?"])
        XCTAssertEqual(seg.feed("No split here"), [])
    }
}
