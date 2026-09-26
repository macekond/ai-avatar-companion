import Foundation

/// Port of `misaki.ja`'s `HEPBURN` table and `_get_single_mapping`/
/// `_romaji_word` logic — converts a hiragana reading string (e.g. from
/// `OpenJTalkMorphemeAnalyzer`'s `readingKatakana`, hiragana-converted via
/// `katakanaToHiragana`) into the IPA-style phoneme string Kokoro's
/// `KokoroTokenizer` vocab expects.
///
/// Note: this maps *whatever kana string it's given* — it does not itself
/// resolve reading ambiguities (e.g. 日本 as にほん vs にっぽん, は as the
/// topic particle "wa" vs the syllable "ha"). Those are reading-time
/// decisions made by whichever morphological analyzer produced the kana
/// (open_jtalk here; misaki's own Python implementation uses a different
/// analyzer, fugashi/UniDic, which may pick different readings for the same
/// text — a real fidelity caveat, not a bug in this phoneme mapping).
public enum JapanesePhonemizer {
    /// Single-kana → IPA, direct port of misaki's `HEPBURN` dict (the
    /// digraph entries are included as multi-character keys, exactly as
    /// the Python source keys them by kana-pair string concatenation).
    static let table: [String: String] = [
        "ぁ": "a", "あ": "a", "ぃ": "i", "い": "i", "ぅ": "ɯ", "う": "ɯ",
        "ぇ": "e", "え": "e", "ぉ": "o", "お": "o",
        "か": "ka", "が": "ɡa", "き": "kʲi", "ぎ": "ɡʲi", "く": "kɯ", "ぐ": "ɡɯ",
        "け": "ke", "げ": "ɡe", "こ": "ko", "ご": "ɡo",
        "さ": "sa", "ざ": "ʣa", "し": "ɕi", "じ": "ʥi", "す": "sɨ", "ず": "zɨ",
        "せ": "se", "ぜ": "ʣe", "そ": "so", "ぞ": "ʣo",
        "た": "ta", "だ": "da", "ち": "ʨi", "ぢ": "ʥi", "つ": "ʦɨ", "づ": "zɨ",
        "て": "te", "で": "de", "と": "to", "ど": "do",
        "な": "na", "に": "ɲi", "ぬ": "nɯ", "ね": "ne", "の": "no",
        "は": "ha", "ば": "ba", "ぱ": "pa", "ひ": "çi", "び": "bʲi", "ぴ": "pʲi",
        "ふ": "ɸɯ", "ぶ": "bɯ", "ぷ": "pɯ", "へ": "he", "べ": "be", "ぺ": "pe",
        "ほ": "ho", "ぼ": "bo", "ぽ": "po",
        "ま": "ma", "み": "mʲi", "む": "mɯ", "め": "me", "も": "mo",
        "ゃ": "ja", "や": "ja", "ゅ": "jɯ", "ゆ": "jɯ", "ょ": "jo", "よ": "jo",
        "ら": "ɾa", "り": "ɾʲi", "る": "ɾɯ", "れ": "ɾe", "ろ": "ɾo",
        "ゎ": "βa", "わ": "βa", "ゐ": "i", "ゑ": "e", "を": "o", "ゔ": "vɯ",
        "ゕ": "ka", "ゖ": "ke",

        // Digraphs (small-kana combinations), keyed by concatenated string:
        "いぇ": "je", "うぃ": "βi", "うぇ": "βe", "うぉ": "βo",
        "きぇ": "kʲe", "きゃ": "kʲa", "きゅ": "kʲɨ", "きょ": "kʲo",
        "ぎゃ": "ɡʲa", "ぎゅ": "ɡʲɨ", "ぎょ": "ɡʲo",
        "くぁ": "kᵝa", "くぃ": "kᵝi", "くぇ": "kᵝe", "くぉ": "kᵝo",
        "ぐぁ": "ɡᵝa", "ぐぃ": "ɡᵝi", "ぐぇ": "ɡᵝe", "ぐぉ": "ɡᵝo",
        "しぇ": "ɕe", "しゃ": "ɕa", "しゅ": "ɕɨ", "しょ": "ɕo",
        "じぇ": "ʥe", "じゃ": "ʥa", "じゅ": "ʥɨ", "じょ": "ʥo",
        "ちぇ": "ʨe", "ちゃ": "ʨa", "ちゅ": "ʨɨ", "ちょ": "ʨo",
        "ぢゃ": "ʥa", "ぢゅ": "ʥɨ", "ぢょ": "ʥo",
        "つぁ": "ʦa", "つぃ": "ʦʲi", "つぇ": "ʦe", "つぉ": "ʦo",
        "てぃ": "tʲi", "てゅ": "tʲɨ", "でぃ": "dʲi", "でゅ": "dʲɨ",
        "とぅ": "tɯ", "どぅ": "dɯ",
        "にぇ": "ɲe", "にゃ": "ɲa", "にゅ": "ɲɨ", "にょ": "ɲo",
        "ひぇ": "çe", "ひゃ": "ça", "ひゅ": "çɨ", "ひょ": "ço",
        "びゃ": "bʲa", "びゅ": "bʲɨ", "びょ": "bʲo",
        "ぴゃ": "pʲa", "ぴゅ": "pʲɨ", "ぴょ": "pʲo",
        "ふぁ": "ɸa", "ふぃ": "ɸʲi", "ふぇ": "ɸe", "ふぉ": "ɸo", "ふゅ": "ɸʲɨ", "ふょ": "ɸʲo",
        "みゃ": "mʲa", "みゅ": "mʲɨ", "みょ": "mʲo",
        "りゃ": "ɾʲa", "りゅ": "ɾʲɨ", "りょ": "ɾʲo",
        "ゔぁ": "va", "ゔぃ": "vʲi", "ゔぇ": "ve", "ゔぉ": "vo", "ゔゅ": "bʲɨ", "ゔょ": "bʲo",
    ]

    private static let sutegana: Set<Character> = ["ゃ", "ゅ", "ょ", "ぁ", "ぃ", "ぅ", "ぇ", "ぉ"]

    /// Converts a hiragana reading string to Kokoro's IPA-style phoneme
    /// string — port of `_romaji_word` iterating with neighbor lookahead,
    /// plus `_get_single_mapping`'s digraph/sokuon/long-vowel/moraic-nasal
    /// special cases.
    public static func phonemize(hiragana: String) -> String {
        let chars = Array(hiragana)
        var out = ""
        var i = 0
        while i < chars.count {
            let kk = chars[i]
            let pk: Character? = i > 0 ? chars[i - 1] : nil
            let nk: Character? = i < chars.count - 1 ? chars[i + 1] : nil

            // Digraph check: does (previous + current) form a known
            // digraph? If so, the previous iteration already emitted it and
            // this character must be skipped entirely — handled by the
            // "consumed" flag below instead of re-deriving here, matching
            // the Python original's per-character forward lookahead instead.
            if let nk, let digraph = table[String([kk, nk])] {
                out += digraph
                i += 2
                continue
            }
            if let pk, table[String([pk, kk])] != nil {
                // This character was already consumed as the second half of
                // a digraph by the previous iteration's lookahead — but
                // since we advance by 2 there, this branch is unreachable;
                // kept only for parity with the Python source's structure.
                i += 1
                continue
            }
            if let nk, sutegana.contains(nk) {
                if kk == "っ" {
                    i += 1
                    continue
                }
                if let base = table[String(kk)], let smallBase = table[String(nk)] {
                    out += String(base.dropLast()) + smallBase
                    i += 2
                    continue
                }
            }
            if sutegana.contains(kk) {
                i += 1
                continue
            }
            if kk == "ー" {
                out += "ː"
                i += 1
                continue
            }
            if kk == "っ" {
                out += "ʔ"
                i += 1
                continue
            }
            if kk == "ん" {
                let nextMapped = nk.flatMap { table[String($0)] }
                if let nextMapped, let first = nextMapped.first {
                    if "mpb".contains(first) {
                        out += "m"
                    } else if "kɡ".contains(first) {
                        out += "ŋ"
                    } else if nextMapped.hasPrefix("ɲ") || nextMapped.hasPrefix("ʨ") || nextMapped.hasPrefix("ʥ") {
                        out += "ɲ"
                    } else if "ntdɾz".contains(first) {
                        out += "n"
                    } else {
                        out += "ɴ"
                    }
                } else {
                    out += "ɴ"
                }
                i += 1
                continue
            }
            out += table[String(kk)] ?? ""
            i += 1
        }
        return out
    }
}
