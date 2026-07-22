import Foundation
import NovaCore

/// Real `MorphemeAnalyzing` implementation backed by open_jtalk (see
/// OpenJTalkBridge.h/.mm) — replaces `UnavailableMorphemeAnalyzer` once a
/// dictionary is present. Implements NovaCore's `FuriganaFormatter`
/// dependency for real, mirroring `pyopenjtalk.run_frontend()`.
// @unchecked for the same reason as WhisperEngine/LlamaEngine: the opaque
// handle isn't Sendable-checked, and calls are effectively serialized since
// this app only ever has one active WKWebView client at a time.
final class OpenJTalkMorphemeAnalyzer: MorphemeAnalyzing, @unchecked Sendable {
    enum AnalyzerError: Error {
        case loadFailed
        case analyzeFailed
    }

    private let handle: NovaOpenJTalkHandle

    /// `dictDir` is the compiled naist-jdic binary directory (matrix.bin,
    /// sys.dic, unk.dic, etc. — bundled in pyopenjtalk's wheel, not vendored
    /// in git; Phase 9's on-demand download, same as the other models).
    init(dictDir: String) throws {
        guard let handle = nova_openjtalk_load(dictDir) else {
            throw AnalyzerError.loadFailed
        }
        self.handle = handle
    }

    deinit {
        nova_openjtalk_free(handle)
    }

    func analyze(_ text: String) throws -> [Morpheme] {
        final class Box {
            var morphemes: [Morpheme] = []
        }
        let box = Box()
        let boxPointer = Unmanaged.passUnretained(box).toOpaque()

        let status = text.withCString { cText in
            nova_openjtalk_analyze(handle, cText, { morpheme, context in
                guard let context else { return }
                let box = Unmanaged<Box>.fromOpaque(context).takeUnretainedValue()
                let surface = morpheme.surface.map { String(cString: $0) } ?? ""
                let reading = morpheme.reading.map { String(cString: $0) }
                box.morphemes.append(Morpheme(surface: surface, readingKatakana: reading))
            }, boxPointer)
        }
        guard status == 0 else { throw AnalyzerError.analyzeFailed }
        return box.morphemes
    }
}
