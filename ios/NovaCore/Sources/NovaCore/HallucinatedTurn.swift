import Foundation

/// Even with a real chat template and its stop tokens (see `LlamaBridge`), a
/// small local model can still run past its own answer and hallucinate a
/// fake continuation turn shaped like "Child: ...\nNova: ...". `SentenceSegmenter`
/// happens to split each hallucinated line out as its own sentence (they
/// start with a newline), so checking each sentence as it completes is
/// enough to catch this before it reaches TTS/display — see
/// `LlamaEngine.generate`.
public func looksLikeHallucinatedTurn(_ sentence: String) -> Bool {
    let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
    let lowered = trimmed.lowercased()
    return lowered.hasPrefix("child:") || lowered.hasPrefix("nova:")
}
