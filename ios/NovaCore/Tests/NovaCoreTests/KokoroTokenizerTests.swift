import XCTest
@testable import NovaCore

final class KokoroTokenizerTests: XCTestCase {
    func test_vocabSize() {
        // Matches kokoro_onnx/config.json's "vocab" table exactly (114 entries).
        XCTAssertEqual(KokoroTokenizer.vocab.count, 114)
    }

    func test_tokenize_simpleIPA() {
        // "k" -> 53, "æ" -> 72, "t" -> 62 (cat, roughly)
        XCTAssertEqual(KokoroTokenizer.tokenize("kæt"), [53, 72, 62])
    }

    func test_tokenize_unknownCharacters_areSkipped() {
        // Port of `[i for i in map(self.vocab.get, phonemes) if i is not None]`
        // — characters outside the vocab are silently dropped, not an error.
        XCTAssertEqual(KokoroTokenizer.tokenize("k\u{0041}æt"), [53, 24, 72, 62])
        XCTAssertEqual(KokoroTokenizer.tokenize("k\u{1F600}æt"), [53, 72, 62])
    }

    func test_tokenize_stressMarks() {
        // ˈ (primary stress) = 156, ˌ (secondary stress) = 157
        XCTAssertEqual(KokoroTokenizer.tokenize("ˈˌ"), [156, 157])
    }

    func test_tokenize_empty() {
        XCTAssertEqual(KokoroTokenizer.tokenize(""), [])
    }

    func test_wrapWithPadding_addsZeroAtBothEnds() {
        // Port of `tokens = [[0, *tokens, 0]]` in kokoro_onnx's _create_audio.
        XCTAssertEqual(KokoroTokenizer.wrapWithPadding([53, 72, 62]), [0, 53, 72, 62, 0])
    }

    func test_wrapWithPadding_empty() {
        XCTAssertEqual(KokoroTokenizer.wrapWithPadding([]), [0, 0])
    }
}
