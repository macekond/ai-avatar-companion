import XCTest
@testable import NovaCore

/// Ground truth from `piper.phoneme_ids.phonemes_to_ids` (the real piper-tts
/// Python package), run directly against `DEFAULT_PHONEME_ID_MAP`.
final class PiperPhonemeIdsTests: XCTestCase {
    func test_empty_isJustBosPad_eos() {
        XCTAssertEqual(PiperPhonemeIds.phonemesToIds([]), [1, 0, 2])
    }

    func test_simpleWord_interleavesPadBetweenEveryPhoneme() {
        XCTAssertEqual(PiperPhonemeIds.phonemesToIds(Array("hɛloʊ")), [1, 0, 20, 0, 61, 0, 24, 0, 27, 0, 100, 0, 2])
    }

    func test_withStressMark() {
        XCTAssertEqual(PiperPhonemeIds.phonemesToIds(Array("ˈkæt")), [1, 0, 120, 0, 23, 0, 39, 0, 32, 0, 2])
    }

    func test_unknownPhoneme_isSkipped_notFatal() {
        // "🙂" isn't in the map — matches the Python original's behavior of
        // logging a warning and continuing, not raising.
        XCTAssertEqual(PiperPhonemeIds.phonemesToIds(Array("h🙂i")), [1, 0, 20, 0, 21, 0, 2])
    }

    func test_precomposedNasalizedVowel_decomposesIntoBasePlusCombiningMark() {
        // Ground truth: phonemes_to_ids(list(unicodedata.normalize("NFD", "ɛ̃")))
        // -> [1, 0, 61, 0, 141, 0, 2] — the precomposed nasalized ɛ (one
        // Swift `Character`/grapheme cluster) must decompose into base ɛ
        // (id 61) + combining tilde (id 141) as two separate ids, not be
        // dropped as a single unmapped grapheme cluster.
        XCTAssertEqual(PiperPhonemeIds.phonemesToIds("ɛ̃"), [1, 0, 61, 0, 141, 0, 2])
    }
}
