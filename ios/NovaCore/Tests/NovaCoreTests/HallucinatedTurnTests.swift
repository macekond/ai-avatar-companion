import XCTest
@testable import NovaCore

/// Nova's LLM prompt is raw text-completion with a "Child: ...\nNova:" cue
/// (see NovaWebSocketServer.replyAndContinue) — there's no chat template or
/// stop token, so a real reply on-device was observed running straight past
/// its own answer into a hallucinated "Child: ...\nNova: ..." continuation,
/// which then got spoken and displayed as if Nova had said it.
final class HallucinatedTurnTests: XCTestCase {
    func test_childCue_isDetected() {
        XCTAssertTrue(looksLikeHallucinatedTurn("Child: Good!"))
    }

    func test_novaCue_isDetected() {
        XCTAssertTrue(looksLikeHallucinatedTurn("Nova: Oh!"))
    }

    func test_caseInsensitive() {
        XCTAssertTrue(looksLikeHallucinatedTurn("child: yes"))
        XCTAssertTrue(looksLikeHallucinatedTurn("NOVA: hi"))
    }

    func test_leadingWhitespaceIgnored() {
        XCTAssertTrue(looksLikeHallucinatedTurn("  \nChild: hi"))
    }

    func test_realReply_isNotFlagged() {
        XCTAssertFalse(looksLikeHallucinatedTurn("I like pizza too! What is your favorite food?"))
    }

    func test_mentioningTheWordChildMidSentence_isNotFlagged() {
        // Only a *cue at the start* of the sentence counts — the word
        // appearing naturally inside a real reply must not trip this.
        XCTAssertFalse(looksLikeHallucinatedTurn("Every child likes stories!"))
    }

    func test_empty_isNotFlagged() {
        XCTAssertFalse(looksLikeHallucinatedTurn(""))
    }
}
