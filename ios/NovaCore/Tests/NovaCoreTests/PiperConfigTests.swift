import XCTest
@testable import NovaCore

/// Fixture trimmed from a real downloaded voice config
/// (`en_US-amy-medium.onnx.json`, piper-tts's own JSON shape) — same fields,
/// a handful of phoneme_id_map entries instead of the full ~154.
private let fixtureJSON = """
{
  "audio": { "sample_rate": 22050 },
  "espeak": { "voice": "en-us" },
  "inference": { "noise_scale": 0.667, "length_scale": 1.0, "noise_w": 0.8 },
  "phoneme_type": "espeak",
  "num_symbols": 256,
  "num_speakers": 1,
  "phoneme_id_map": { "_": [0], "^": [1], "$": [2], "h": [20], "i": [21] }
}
"""

final class PiperConfigTests: XCTestCase {
    func test_decodesRealVoiceConfigShape() throws {
        let config = try PiperConfig(json: fixtureJSON.data(using: .utf8)!)
        XCTAssertEqual(config.sampleRate, 22050)
        XCTAssertEqual(config.espeakVoice, "en-us")
        XCTAssertEqual(config.noiseScale, 0.667)
        XCTAssertEqual(config.lengthScale, 1.0)
        XCTAssertEqual(config.noiseWScale, 0.8)
        XCTAssertEqual(config.numSpeakers, 1)
        XCTAssertEqual(config.phonemeIdMap["h"], [20])
    }

    func test_missingInferenceBlock_usesDefaults() throws {
        let json = """
        {
          "audio": { "sample_rate": 16000 },
          "espeak": { "voice": "en-us" },
          "num_symbols": 10,
          "num_speakers": 1,
          "phoneme_id_map": {}
        }
        """
        let config = try PiperConfig(json: json.data(using: .utf8)!)
        XCTAssertEqual(config.noiseScale, 0.667)
        XCTAssertEqual(config.lengthScale, 1.0)
        XCTAssertEqual(config.noiseWScale, 0.8)
        XCTAssertEqual(config.hopLength, 256)
    }
}
