import Foundation

/// Matches ui/src/main.js's MODEL_PATH basename.
public let defaultAvatarKey = "VIPEHero_2707"

/// Curated appearance descriptions (bundled). Keyed by avatar key = VRM
/// basename. Second person, ~1-2 sentences, concrete visual facts a child
/// asks about — direct port of `_CURATED` in `app/appearance.py`.
private let curatedAppearances: [String: String] = [
    "VIPEHero_2707": (
        "You look like a playful, cool hero with a cheerful, spunky vibe. You have "
        + "long pink hair with orange streaks, and you wear a blue-and-pink cat-ear "
        + "headband and big purple sunglasses. You've got a white hoodie with mint-green "
        + "sleeves and a little purple skull badge, plus a tiny fang and a small black "
        + "'x' mark on your cheek. You come across as a friendly, energetic girl."
    ),
    "Olivia": (
        "You look like a cheerful, friendly girl with a calm, easy-going vibe. You "
        + "have bright yellow hair styled into a tall pointed hood, with long strands "
        + "that frame your face and end in little gold beads. You wear a cosy black "
        + "high-necked top. You come across as sweet and approachable."
    ),
]

public struct AvatarAppearance: Codable, Equatable {
    public let key: String
    public let description: String
    /// "curated" | "auto"
    public let source: String
    public let derivedAt: String
}

/// Small named palette, hex -> nearest by squared RGB distance — direct port
/// of `_PALETTE`/`nearest_colour_name` in `app/appearance.py`.
private let colourPalette: [(name: String, rgb: (Int, Int, Int))] = [
    ("black", (0, 0, 0)),
    ("white", (255, 255, 255)),
    ("grey", (128, 128, 128)),
    ("red", (200, 40, 40)),
    ("orange", (230, 140, 40)),
    ("yellow", (240, 220, 60)),
    ("blonde", (220, 200, 130)),
    ("green", (60, 170, 90)),
    ("blue", (50, 130, 220)),
    ("purple", (150, 70, 190)),
    ("pink", (235, 130, 180)),
    ("brown", (110, 70, 40)),
]

private func hexToRGB(_ hex: String) -> (Int, Int, Int) {
    let h = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
    func component(_ range: Range<String.Index>) -> Int {
        Int(h[range], radix: 16) ?? 0
    }
    let start = h.startIndex
    return (
        component(start..<h.index(start, offsetBy: 2)),
        component(h.index(start, offsetBy: 2)..<h.index(start, offsetBy: 4)),
        component(h.index(start, offsetBy: 4)..<h.index(start, offsetBy: 6))
    )
}

/// Palette colour name nearest to `hex` (e.g. "#6b4423" -> "brown").
public func nearestColourName(hex: String) -> String {
    let (r, g, b) = hexToRGB(hex)
    return colourPalette.min {
        let da = ($0.rgb.0 - r) * ($0.rgb.0 - r) + ($0.rgb.1 - g) * ($0.rgb.1 - g) + ($0.rgb.2 - b) * ($0.rgb.2 - b)
        let db = ($1.rgb.0 - r) * ($1.rgb.0 - r) + ($1.rgb.1 - g) * ($1.rgb.1 - g) + ($1.rgb.2 - b) * ($1.rgb.2 - b)
        return da < db
    }!.name
}

/// Resolves and caches per-avatar appearance descriptions — direct port of
/// `AppearanceStore` in `app/appearance.py`. Resolution order: curated
/// bundled description, then a cached auto-derived description, then nil
/// (caller injects no appearance line).
public final class AppearanceStore {
    private let dir: URL

    public init(cacheDir: URL) {
        self.dir = cacheDir
    }

    public func get(key: String) -> AvatarAppearance? {
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        if let curated = curatedAppearances[key] {
            return AvatarAppearance(key: key, description: curated, source: "curated", derivedAt: todayString())
        }
        let path = dir.appendingPathComponent("\(nameToSlug(key)).json")
        guard let data = try? Data(contentsOf: path) else { return nil }
        return try? JSONDecoder().decode(AvatarAppearance.self, from: data)
    }

    /// Build + cache a description from sampled portrait region colours
    /// (e.g. `{"hair": "#6b4423", "clothing": "#c0392b"}`).
    @discardableResult
    public func deriveFromRegions(key: String, regions: [String: String]) -> AvatarAppearance {
        var parts: [String] = []
        if let hair = regions["hair"] { parts.append("\(nearestColourName(hex: hair)) hair") }
        if let clothing = regions["clothing"] { parts.append("\(nearestColourName(hex: clothing)) clothes") }
        let summary = parts.isEmpty ? "a friendly look" : parts.joined(separator: " and ")

        let appearance = AvatarAppearance(key: key, description: "You have \(summary).", source: "auto", derivedAt: todayString())
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(appearance) {
            try? data.write(to: dir.appendingPathComponent("\(nameToSlug(key)).json"))
        }
        return appearance
    }
}
