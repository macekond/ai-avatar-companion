import Foundation

/// Wraps espeak-ng's plain-C API (`speak_lib.h`, imported directly via the
/// bridging header — no ObjC++ needed, same reasoning as `KokoroEngine`'s
/// onnxruntime usage) to turn English text into IPA phonemes for Piper.
///
/// Direct Swift port of piper-tts's own `espeakbridge.c` — same
/// `espeak_TextToPhonemesWithTerminator` call, same clause-terminator bit
/// masking (`CLAUSE_INTONATION_*`/`CLAUSE_TYPE_*`, defined in espeak-ng's
/// *internal* headers so piper redefines them locally; ported verbatim here
/// for the same reason).
///
/// espeak-ng's global state (current voice, its internal buffers) means only
/// one `EspeakPhonemizer` may be initialized per process, mirroring piper's
/// own module-level `_ESPEAK_PHONEMIZER` singleton + lock.
final class EspeakPhonemizer: @unchecked Sendable {
    enum PhonemizerError: Error {
        case initializeFailed
        case setVoiceFailed(String)
    }

    private static let clauseIntonationFullStop = 0x00000000
    private static let clauseIntonationComma = 0x00001000
    private static let clauseIntonationQuestion = 0x00002000
    private static let clauseIntonationExclamation = 0x00003000
    private static let clauseTypeClause = 0x00040000
    private static let clauseTypeSentence = 0x00080000

    private static let clausePeriod = 40 | clauseIntonationFullStop | clauseTypeSentence
    private static let clauseComma = 20 | clauseIntonationComma | clauseTypeClause
    private static let clauseQuestion = 40 | clauseIntonationQuestion | clauseTypeSentence
    private static let clauseExclamation = 45 | clauseIntonationExclamation | clauseTypeSentence
    private static let clauseColon = 30 | clauseIntonationFullStop | clauseTypeClause
    private static let clauseSemicolon = 30 | clauseIntonationComma | clauseTypeClause

    /// `dataDir` is espeak-ng's compiled dictionary/intonation data directory
    /// (`build-apple/espeak-ng-data` from `build-espeak-ng-ios.sh`, not
    /// bundled in git — Phase 9's on-demand download, same pattern as the
    /// other models/dictionaries).
    init(dataDir: String) throws {
        guard espeak_Initialize(AUDIO_OUTPUT_SYNCHRONOUS, 0, dataDir, 0) >= 0 else {
            throw PhonemizerError.initializeFailed
        }
    }

    func setVoice(_ name: String) throws {
        guard espeak_SetVoiceByName(name) == EE_OK else {
            throw PhonemizerError.setVoiceFailed(name)
        }
    }

    struct Clause {
        let phonemes: String
        let terminator: String
        let endOfSentence: Bool
    }

    /// Text to IPA phonemes, grouped by clause — port of `espeakbridge.c`'s
    /// `py_get_phonemes` loop. `espeak_TextToPhonemesWithTerminator` both
    /// reads and advances `textPtr` to point at the remainder of the string,
    /// becoming `nil` once the whole input has been consumed.
    func phonemize(_ text: String) -> [Clause] {
        var clauses: [Clause] = []
        text.withCString { cText in
            var textPtr: UnsafeRawPointer? = UnsafeRawPointer(cText)
            while textPtr != nil {
                var terminator: Int32 = 0
                let phonemesPtr = espeak_TextToPhonemesWithTerminator(&textPtr, Int32(espeakCHARS_AUTO), Int32(espeakPHONEMES_IPA), &terminator)
                let phonemes = phonemesPtr.map { String(cString: $0) } ?? ""

                let masked = Int(terminator) & 0x000FFFFF
                let terminatorStr: String
                switch masked {
                case Self.clausePeriod: terminatorStr = "."
                case Self.clauseQuestion: terminatorStr = "?"
                case Self.clauseExclamation: terminatorStr = "!"
                case Self.clauseComma: terminatorStr = ","
                case Self.clauseColon: terminatorStr = ":"
                case Self.clauseSemicolon: terminatorStr = ";"
                default: terminatorStr = ""
                }
                let endOfSentence = (masked & Self.clauseTypeSentence) == Self.clauseTypeSentence
                clauses.append(Clause(phonemes: phonemes, terminator: terminatorStr, endOfSentence: endOfSentence))
            }
        }
        return clauses
    }
}
