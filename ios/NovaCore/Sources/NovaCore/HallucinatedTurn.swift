import Foundation

/// Nova's LLM prompt is raw text-completion cued with "Child: ...\nNova:"
/// (see `NovaWebSocketServer.replyAndContinue`) — there's no chat template
/// or stop token backing that structure, so the model is free to keep
/// generating past its own answer and hallucinate a fake continuation turn
/// in the same "Child: ...\nNova: ..." shape. `SentenceSegmenter` happens to
/// split each hallucinated line out as its own sentence (they start with a
/// newline), so checking each sentence as it completes is enough to catch
/// this before it reaches TTS/display — see `LlamaEngine.generate`.
public func looksLikeHallucinatedTurn(_ sentence: String) -> Bool {
    let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
    let lowered = trimmed.lowercased()
    return lowered.hasPrefix("child:") || lowered.hasPrefix("nova:")
}
