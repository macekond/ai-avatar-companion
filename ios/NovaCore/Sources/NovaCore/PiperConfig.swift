import Foundation

/// Port of piper-tts's `config.py` `PiperConfig.from_dict` — parses the
/// `<voice>.onnx.json` file every Piper voice ships alongside its `.onnx`
/// model. Field defaults (`DEFAULT_NOISE_SCALE` etc.) match the Python
/// original exactly.
public struct PiperConfig {
    public let numSymbols: Int
    public let numSpeakers: Int
    public let sampleRate: Int
    public let espeakVoice: String
    public let phonemeIdMap: [String: [Int]]
    public let lengthScale: Float
    public let noiseScale: Float
    public let noiseWScale: Float
    public let hopLength: Int

    public enum ConfigError: Error {
        case invalidJSON
    }

    public init(json: Data) throws {
        guard let root = try JSONSerialization.jsonObject(with: json) as? [String: Any] else {
            throw ConfigError.invalidJSON
        }
        guard let audio = root["audio"] as? [String: Any], let sampleRate = audio["sample_rate"] as? Int,
              let espeak = root["espeak"] as? [String: Any], let espeakVoice = espeak["voice"] as? String,
              let numSymbols = root["num_symbols"] as? Int,
              let numSpeakers = root["num_speakers"] as? Int,
              let rawPhonemeIdMap = root["phoneme_id_map"] as? [String: [Int]]
        else {
            throw ConfigError.invalidJSON
        }

        let inference = root["inference"] as? [String: Any]
        self.sampleRate = sampleRate
        self.espeakVoice = espeakVoice
        self.numSymbols = numSymbols
        self.numSpeakers = numSpeakers
        self.phonemeIdMap = rawPhonemeIdMap
        self.noiseScale = (inference?["noise_scale"] as? NSNumber)?.floatValue ?? 0.667
        self.lengthScale = (inference?["length_scale"] as? NSNumber)?.floatValue ?? 1.0
        self.noiseWScale = (inference?["noise_w"] as? NSNumber)?.floatValue ?? 0.8
        self.hopLength = (root["hop_length"] as? Int) ?? 256
    }
}
