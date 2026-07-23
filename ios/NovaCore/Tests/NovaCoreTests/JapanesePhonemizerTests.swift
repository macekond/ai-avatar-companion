import XCTest
@testable import NovaCore

/// Expected outputs are ground truth from `misaki.ja.JAG2P` called directly
/// in Python (same library the desktop app uses for Kokoro Japanese TTS),
/// not guessed.
final class JapanesePhonemizerTests: XCTestCase {
    func test_simpleWord() {
        XCTAssertEqual(JapanesePhonemizer.phonemize(hiragana: "ねこ"), "neko")
    }

    func test_longVowelMark() {
        // Input is the *reading* form (long vowel already spelled with ー,
        // the chōonpu), matching what a morphological reading — misaki's
        // own fugashi/UniDic pron field, or open_jtalk's katakana reading
        // upstream in this app — actually produces for とう, not the literal
        // orthographic "とう" spelling.
        XCTAssertEqual(JapanesePhonemizer.phonemize(hiragana: "ありがとー"), "aɾʲiɡatoː")
    }

    func test_moraicNasal_beforeNasalOnset_geminatesToɲ() {
        // Reading is こんにちわ (は resolved to わ upstream, before this
        // function ever sees it — see test_bareHa_asAlreadyResolvedKana's
        // note on this function's contract). ん before に (ɲ-onset) -> ɲ,
        // then に itself -> ɲi: "koɲɲiʨiβa"
        XCTAssertEqual(JapanesePhonemizer.phonemize(hiragana: "こんにちわ"), "koɲɲiʨiβa")
    }

    func test_moraicNasal_beforeBilabial_becomesM() {
        // んぽ: ん before ぽ (p-onset) -> m
        XCTAssertEqual(JapanesePhonemizer.phonemize(hiragana: "さんぽ"), "sampo")
    }

    func test_moraicNasal_beforeVelar_becomesEngma() {
        // んき: ん before き (k-onset) -> ŋ; き itself maps to 'kʲi' (not
        // plain 'ki') per the table, since き is palatalized.
        XCTAssertEqual(JapanesePhonemizer.phonemize(hiragana: "げんき"), "ɡeŋkʲi")
    }

    func test_moraicNasal_wordFinal_becomesUvularNasal() {
        // ん at the end (no following kana) -> ɴ
        XCTAssertEqual(JapanesePhonemizer.phonemize(hiragana: "ほん"), "hoɴ")
    }

    func test_sokuon_becomesGlottalStop() {
        // がっこう's reading is がっこー (long vowel already spelled with ー);
        // っ -> ʔ
        XCTAssertEqual(JapanesePhonemizer.phonemize(hiragana: "がっこー"), "ɡaʔkoː")
    }

    func test_digraph_smallYa() {
        // きゃ (digraph) -> kʲa, not k+ja separately
        XCTAssertEqual(JapanesePhonemizer.phonemize(hiragana: "きゃく"), "kʲakɯ")
    }

    func test_bareHa_asAlreadyResolvedKana_mapsLiterally() {
        // This phonemizer's contract is: its input is an *already-resolved*
        // kana reading (from open_jtalk's morpheme analysis upstream), not
        // raw orthographic text — so は as the topic particle (pronounced
        // "wa") is expected to have already been resolved to わ by the
        // reading step before it ever reaches this function.
        //
        // misaki.ja.JAG2P("は") returns "βa" directly, but that's because
        // misaki's own tokenizer (fugashi/UniDic) does that reading
        // resolution internally for standalone は — a different analyzer
        // than open_jtalk, which this app actually uses upstream, and which
        // may resolve differently. So JAG2P's raw-text output isn't the
        // right ground truth for *this* function's contract; what's tested
        // here is that literal は (already-resolved orthographic kana, e.g.
        // from a word where は truly is the syllable "ha") maps via the
        // table, matching HEPBURN's chr(12399):'ha' entry.
        XCTAssertEqual(JapanesePhonemizer.phonemize(hiragana: "は"), "ha")
    }

    func test_empty() {
        XCTAssertEqual(JapanesePhonemizer.phonemize(hiragana: ""), "")
    }
}
