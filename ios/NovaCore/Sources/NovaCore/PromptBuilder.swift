import Foundation

/// Assembles the LLM system prompt — direct port of `LLMPipeline._build_prompt`
/// and `_format_memory_block` in `app/pipeline/llm.py`.
///
/// The assembly order is load-bearing (see CLAUDE.md and the Python
/// docstrings): base personality → teaching frame → level instructions →
/// memory block → appearance → `LANGUAGE_LOCK` **last**, because the small
/// local model weights the final instruction most heavily. Do not reorder.
public struct PromptBuilder {
    public var basePrompt: String
    public var language: String
    public var level: String
    public var memory: ChildMemory?
    public var appearance: String?

    public init(basePrompt: String, language: String, level: String) {
        self.basePrompt = basePrompt
        self.language = language
        self.level = level
    }

    public func build() -> String {
        var parts = [basePrompt]

        let frame = Levels.teachingFrame(for: language)
        if !frame.isEmpty { parts.append(frame) }

        let instruction = Levels.instructions(forLevel: level, language: language)
        if !instruction.isEmpty { parts.append(instruction) }

        if let memory {
            parts.append(Self.formatMemoryBlock(memory))
        }

        if let appearance, !appearance.isEmpty {
            parts.append("About how you look — if asked about your appearance, answer in first person and stay in character: \(appearance)")
        }

        // Always last: the non-negotiable "reply only in <language>" rule.
        parts.append(Levels.languageLock(for: language))

        return parts.joined(separator: "\n\n")
    }

    /// Render a concise memory context block — port of `_format_memory_block`.
    /// Each remembered topic/problem is tagged with how long ago it came up
    /// relative to today, and the block opens with today's date.
    static func formatMemoryBlock(_ memory: ChildMemory, today: Date = Date()) -> String {
        let profile = memory.profile
        let ageStr = profile.age.map { " (age \($0))" } ?? ""
        var lines = [
            "Today is \(todayContext(today)).",
            "Memory about \(profile.name)\(ageStr):",
        ]

        let recentTopics = memory.topics.sorted { $0.lastMentioned > $1.lastMentioned }.prefix(5)
        if !recentTopics.isEmpty {
            let joined = recentTopics
                .map { "\($0.keyword) (\(humanizeSince($0.lastMentioned, today: today)))" }
                .joined(separator: ", ")
            lines.append("- Recent topics of interest: \(joined)")
        }

        let unresolved = memory.problems.filter { !$0.resolved }
        let topProblems = unresolved.sorted { $0.timesSeen > $1.timesSeen }.prefix(3)
        if !topProblems.isEmpty {
            let details = topProblems
                .map { "\($0.type) (e.g. '\($0.example)' → '\($0.correction)', came up \(humanizeSince($0.lastSeen, today: today)))" }
                .joined(separator: "; ")
            lines.append("- Known language challenges: \(details)")
        }

        // Only prompt the model to reference *when* things came up if there
        // is actually remembered history — emitting this for a freshly
        // onboarded child primes it to invent a shared past.
        if !recentTopics.isEmpty || !unresolved.isEmpty {
            let weekday = DateFormatter.weekday(today)
            lines.append(
                "- You know when each of these came up, so refer to it naturally when it fits "
                + "(e.g. \"yesterday you told me about...\", \"happy \(weekday)!\") — kids love "
                + "talking about today, yesterday and what's coming up."
            )
        }

        var hints: [String] = []
        if let newest = recentTopics.first {
            hints.append("ask about \(newest.keyword)")
        }
        if let worst = topProblems.first {
            hints.append("practise \(worst.type) with a fun example")
        }
        if !hints.isEmpty {
            lines.append("- If \(profile.name) is quiet, you can: " + hints.joined(separator: ", or ") + ".")
        }

        return lines.joined(separator: "\n")
    }
}

private extension DateFormatter {
    static func weekday(_ date: Date) -> String {
        let formatter = DateFormatter()
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        formatter.calendar = cal
        formatter.timeZone = cal.timeZone
        formatter.dateFormat = "EEEE"
        return formatter.string(from: date)
    }
}
