import XCTest
@testable import NovaCore

/// Port of the recording-length floor in app/pipeline/stt.py:
/// `if audio.ndim == 0 or len(audio) < int(SAMPLE_RATE * MIN_DURATION_S)`.
final class STTConstantsTests: XCTestCase {
    func test_sampleRate_matchesWhisperRequirement() {
        XCTAssertEqual(STTConstants.sampleRate, 16_000)
    }

    func test_minDurationS() {
        XCTAssertEqual(STTConstants.minDurationS, 0.3, accuracy: 0.0001)
    }

    func test_hasEnoughAudio_exactlyAtThreshold_isTrue() {
        // int(16_000 * 0.3) == 4800
        XCTAssertTrue(STTConstants.hasEnoughAudio(sampleCount: 4800))
    }

    func test_hasEnoughAudio_oneBelowThreshold_isFalse() {
        XCTAssertFalse(STTConstants.hasEnoughAudio(sampleCount: 4799))
    }

    func test_hasEnoughAudio_zeroSamples_isFalse() {
        XCTAssertFalse(STTConstants.hasEnoughAudio(sampleCount: 0))
    }

    func test_hasEnoughAudio_wellAboveThreshold_isTrue() {
        XCTAssertTrue(STTConstants.hasEnoughAudio(sampleCount: 16_000))
    }
}
