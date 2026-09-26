import Foundation

// MARK: - Helpers (ports of module-level functions in app/memory.py)

/// Convert a display name to a filesystem-safe slug.
///
/// Examples: "Lily" → "lily", "Mary Kate" → "mary_kate", "Björn" → "bjrn"
/// (non-ASCII stripped). Input that sanitises to nothing (empty, whitespace,
/// or all non-ASCII) returns `fallback`. Callers that must not conflate junk
/// with a real profile (e.g. deletion) pass `fallback: ""` and reject the
/// empty result.
public func nameToSlug(_ name: String, fallback: String = "child") -> String {
    var s = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    s = s.replacingOccurrences(of: "\\s+", with: "_", options: .regularExpression)
    s = s.replacingOccurrences(of: "[^a-z0-9_]", with: "", options: .regularExpression)
    return s.isEmpty ? fallback : s
}

private func isoDay(_ s: String) -> Date {
    let cal = isoCalendar
    let parts = s.split(separator: "-").compactMap { Int($0) }
    var comps = DateComponents()
    comps.year = parts[0]; comps.month = parts[1]; comps.day = parts[2]
    return cal.date(from: comps)!
}

private let isoCalendar: Calendar = {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    return cal
}()

public func todayString(_ today: Date = Date()) -> String {
    let comps = isoCalendar.dateComponents([.year, .month, .day], from: today)
    return String(format: "%04d-%02d-%02d", comps.year!, comps.month!, comps.day!)
}

/// Describe how long ago `isoDate` was, in kid-friendly relative terms —
/// direct port of `humanize_since` in `app/memory.py`. A future date (clock
/// skew) collapses to "today".
public func humanizeSince(_ isoDate: String, today: Date = Date()) -> String {
    let days = isoCalendar.dateComponents([.day], from: isoDay(isoDate), to: today).day ?? 0
    if days <= 0 { return "today" }
    if days == 1 { return "yesterday" }
    if days < 7 { return "\(days) days ago" }
    if days < 14 { return "last week" }
    if days < 28 { return "\(days / 7) weeks ago" }
    if days < 60 { return "last month" }
    return "\(days / 30) months ago"
}

/// Spoken-style anchor for the current day, e.g. "Tuesday, 14 July 2026" —
/// direct port of `today_context` in `app/memory.py`.
public func todayContext(_ today: Date = Date()) -> String {
    let formatter = DateFormatter()
    formatter.calendar = isoCalendar
    formatter.timeZone = isoCalendar.timeZone
    formatter.dateFormat = "EEEE"
    let weekday = formatter.string(from: today)
    formatter.dateFormat = "MMMM"
    let month = formatter.string(from: today)
    let day = isoCalendar.component(.day, from: today)
    let year = isoCalendar.component(.year, from: today)
    return "\(weekday), \(day) \(month) \(year)"
}

// MARK: - Data model (ports of the dataclasses in app/memory.py)

public struct ChildProfile: Codable, Equatable {
    public var name: String
    public var age: Int?
    public var firstSessionDate: String
    /// Practice language ("en" | "ja") and its proficiency level. Per-profile
    /// so each child gets their own; a level ID is only meaningful within its
    /// own language's taxonomy.
    public var language: String
    public var level: String
    /// Chosen TTS voice id. Per-profile since voices are language-specific.
    /// Empty = use the language default.
    public var voice: String

    public init(
        name: String,
        age: Int? = nil,
        firstSessionDate: String = todayString(Date()),
        language: String = "en",
        level: String = "A",
        voice: String = ""
    ) {
        self.name = name
        self.age = age
        self.firstSessionDate = firstSessionDate
        self.language = language
        self.level = level
        self.voice = voice
    }
}

public struct Topic: Codable, Equatable {
    public var keyword: String
    public var mentionCount: Int
    public var lastMentioned: String

    public init(keyword: String, mentionCount: Int = 1, lastMentioned: String = todayString(Date())) {
        self.keyword = keyword
        self.mentionCount = mentionCount
        self.lastMentioned = lastMentioned
    }
}

/// A recurring language difficulty observed during conversations.
public struct Problem: Codable, Equatable {
    public var type: String
    public var example: String
    public var correction: String
    public var timesSeen: Int
    public var lastSeen: String
    public var resolved: Bool

    public init(
        type: String, example: String, correction: String,
        timesSeen: Int = 1, lastSeen: String = todayString(Date()), resolved: Bool = false
    ) {
        self.type = type
        self.example = example
        self.correction = correction
        self.timesSeen = timesSeen
        self.lastSeen = lastSeen
        self.resolved = resolved
    }
}

/// Root memory object — one instance per child profile.
public struct ChildMemory: Codable, Equatable {
    public var profile: ChildProfile
    public var topics: [Topic]
    public var problems: [Problem]
    public var lastUpdated: String

    public init(
        profile: ChildProfile, topics: [Topic] = [], problems: [Problem] = [],
        lastUpdated: String = todayString(Date())
    ) {
        self.profile = profile
        self.topics = topics
        self.problems = problems
        self.lastUpdated = lastUpdated
    }
}

// MARK: - Memory manager

/// Loads, saves, and maintains a single child's memory file — direct port of
/// `MemoryManager` in `app/memory.py`. Files live at
/// `{profilesDir}/{slug}.json`, one per child.
public final class MemoryManager {
    private static let resolvedTTLDays = 7   // resolved problems expire quickly

    private let dir: URL
    public let slug: String
    private let path: URL
    private let maxTopics: Int
    private let maxProblems: Int
    private let topicTTLDays: Int
    private let problemTTLDays: Int
    /// Slugs deleted through this manager. A background extraction task can
    /// outlive a drain timeout and still call save(); without a tombstone
    /// that late write recreates the file the parent just deleted.
    private var deleted: Set<String> = []

    public init(
        profilesDir: URL, slug: String,
        maxTopics: Int = 20, maxProblems: Int = 15,
        topicTTLDays: Int = 14, problemTTLDays: Int = 30
    ) {
        self.dir = profilesDir
        self.slug = slug
        self.path = profilesDir.appendingPathComponent("\(slug).json")
        self.maxTopics = maxTopics
        self.maxProblems = maxProblems
        self.topicTTLDays = topicTTLDays
        self.problemTTLDays = problemTTLDays
    }

    /// Return the stored ChildMemory, or nil if no file exists (or it's corrupt).
    public func load() -> ChildMemory? {
        guard let data = try? Data(contentsOf: path) else { return nil }
        return try? JSONDecoder().decode(ChildMemory.self, from: data)
    }

    /// Persist memory to disk, creating the directory if needed. A no-op once
    /// this slug has been deleted: a late background save must not resurrect
    /// a profile the parent removed on purpose.
    public func save(_ memory: ChildMemory) {
        if deleted.contains(slug) { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var memory = memory
        memory.lastUpdated = todayString(Date())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        guard let data = try? encoder.encode(memory) else { return }
        try? data.write(to: path)
    }

    /// Add or increment a topic mention.
    public func update(_ memory: inout ChildMemory, topic keyword: String) {
        let kw = keyword.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !kw.isEmpty else { return }
        if let idx = memory.topics.firstIndex(where: { $0.keyword == kw }) {
            memory.topics[idx].mentionCount += 1
            memory.topics[idx].lastMentioned = todayString(Date())
            return
        }
        memory.topics.append(Topic(keyword: kw))
    }

    /// Add or increment a language problem. Re-activates resolved problems.
    public func update(_ memory: inout ChildMemory, problemType type: String, example: String, correction: String) {
        if let idx = memory.problems.firstIndex(where: {
            $0.type == type && $0.example.lowercased() == example.lowercased()
        }) {
            memory.problems[idx].timesSeen += 1
            memory.problems[idx].lastSeen = todayString(Date())
            memory.problems[idx].resolved = false
            return
        }
        memory.problems.append(Problem(type: type, example: example, correction: correction))
    }

    /// Mark a problem as resolved (will expire after `resolvedTTLDays`).
    public func markResolved(_ memory: inout ChildMemory, problemType type: String, example: String) {
        if let idx = memory.problems.firstIndex(where: {
            $0.type == type && $0.example.lowercased() == example.lowercased()
        }) {
            memory.problems[idx].resolved = true
        }
    }

    /// Remove expired entries and enforce count caps. Keeps the
    /// most-recently-active entries when capping by count.
    public func prune(_ memory: inout ChildMemory, today: Date = Date()) {
        memory.topics = memory.topics.filter {
            (isoCalendar.dateComponents([.day], from: isoDay($0.lastMentioned), to: today).day ?? 0) <= topicTTLDays
        }
        memory.problems = memory.problems.filter {
            let days = isoCalendar.dateComponents([.day], from: isoDay($0.lastSeen), to: today).day ?? 0
            return days <= ($0.resolved ? Self.resolvedTTLDays : problemTTLDays)
        }
        memory.topics.sort { $0.lastMentioned > $1.lastMentioned }
        memory.topics = Array(memory.topics.prefix(maxTopics))

        memory.problems.sort { $0.lastSeen > $1.lastSeen }
        memory.problems = Array(memory.problems.prefix(maxProblems))
    }

    /// Slugs for all profiles in the profiles directory.
    public func listProfiles() -> [String] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return []
        }
        return files
            .filter { $0.pathExtension == "json" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted()
    }

    /// Delete the profile JSON for `slug`. The slug is re-sanitised through
    /// `nameToSlug` so a crafted value can never escape the profiles
    /// directory (path traversal). `fallback: ""` means junk that sanitises
    /// to nothing returns false rather than silently collapsing to the
    /// "child" default and deleting an unrelated profile.
    @discardableResult
    public func deleteProfile(slug rawSlug: String) -> Bool {
        let safe = nameToSlug(rawSlug, fallback: "")
        guard !safe.isEmpty else { return false }
        // Tombstone before unlinking, so a save() racing this call is
        // refused rather than recreating the file a moment later.
        deleted.insert(safe)
        let target = dir.appendingPathComponent("\(safe).json")
        guard FileManager.default.fileExists(atPath: target.path) else { return false }
        try? FileManager.default.removeItem(at: target)
        return true
    }
}
