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
}
