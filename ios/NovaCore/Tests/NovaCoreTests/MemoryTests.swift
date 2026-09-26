import XCTest
@testable import NovaCore

final class NameToSlugTests: XCTestCase {
    func test_simpleName() {
        XCTAssertEqual(nameToSlug("Lily"), "lily")
    }

    func test_nameWithSpace_becomesUnderscore() {
        XCTAssertEqual(nameToSlug("Mary Kate"), "mary_kate")
    }

    func test_nonAsciiStripped() {
        XCTAssertEqual(nameToSlug("Björn"), "bjrn")
    }

    func test_allNonAscii_fallsBackToDefault() {
        XCTAssertEqual(nameToSlug("李明"), "child")
    }

    func test_emptyFallback_rejectsJunk() {
        XCTAssertEqual(nameToSlug("李明", fallback: ""), "")
    }

    func test_whitespaceOnly_fallsBackToDefault() {
        XCTAssertEqual(nameToSlug("   "), "child")
    }
}

final class HumanizeSinceTests: XCTestCase {
    let today = ISO8601Date.date(2026, 7, 22)

    func test_today() {
        XCTAssertEqual(humanizeSince(ISO8601Date.string(2026, 7, 22), today: today), "today")
    }

    func test_futureDate_collapsesToToday() {
        XCTAssertEqual(humanizeSince(ISO8601Date.string(2026, 7, 23), today: today), "today")
    }

    func test_yesterday() {
        XCTAssertEqual(humanizeSince(ISO8601Date.string(2026, 7, 21), today: today), "yesterday")
    }

    func test_daysAgo() {
        XCTAssertEqual(humanizeSince(ISO8601Date.string(2026, 7, 18), today: today), "4 days ago")
    }

    func test_lastWeek() {
        XCTAssertEqual(humanizeSince(ISO8601Date.string(2026, 7, 10), today: today), "last week")
    }

    func test_weeksAgo() {
        XCTAssertEqual(humanizeSince(ISO8601Date.string(2026, 7, 5), today: today), "2 weeks ago")
    }

    func test_lastMonth() {
        // 32 days before 2026-07-22 — lands in the [28,60) "last month" bucket.
        XCTAssertEqual(humanizeSince(ISO8601Date.string(2026, 6, 20), today: today), "last month")
    }

    func test_monthsAgo() {
        XCTAssertEqual(humanizeSince(ISO8601Date.string(2026, 4, 1), today: today), "3 months ago")
    }
}

final class MemoryManagerTests: XCTestCase {
    var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    func test_load_returnsNilWhenNoFileExists() {
        let mgr = MemoryManager(profilesDir: tempDir, slug: "lily")
        XCTAssertNil(mgr.load())
    }

    func test_saveThenLoad_roundTrips() {
        let mgr = MemoryManager(profilesDir: tempDir, slug: "lily")
        var memory = ChildMemory(profile: ChildProfile(name: "Lily", age: 8))
        mgr.update(&memory, topic: "football")
        mgr.save(memory)

        let loaded = mgr.load()
        XCTAssertEqual(loaded?.profile.name, "Lily")
        XCTAssertEqual(loaded?.profile.age, 8)
        XCTAssertEqual(loaded?.topics.first?.keyword, "football")
    }

    func test_updateTopic_incrementsExistingRatherThanDuplicating() {
        let mgr = MemoryManager(profilesDir: tempDir, slug: "lily")
        var memory = ChildMemory(profile: ChildProfile(name: "Lily"))
        mgr.update(&memory, topic: "Football")
        mgr.update(&memory, topic: "football")
        XCTAssertEqual(memory.topics.count, 1)
        XCTAssertEqual(memory.topics.first?.mentionCount, 2)
    }

    func test_updateProblem_reactivatesResolvedOnRepeat() {
        let mgr = MemoryManager(profilesDir: tempDir, slug: "lily")
        var memory = ChildMemory(profile: ChildProfile(name: "Lily"))
        mgr.update(&memory, problemType: "past_tense", example: "goed", correction: "went")
        mgr.markResolved(&memory, problemType: "past_tense", example: "goed")
        XCTAssertTrue(memory.problems.first!.resolved)

        mgr.update(&memory, problemType: "past_tense", example: "GOED", correction: "went")
        XCTAssertFalse(memory.problems.first!.resolved)
        XCTAssertEqual(memory.problems.first!.timesSeen, 2)
        XCTAssertEqual(memory.problems.count, 1)
    }

    func test_deleteProfile_reSanitizesSlugAndRejectsJunk() {
        let mgr = MemoryManager(profilesDir: tempDir, slug: "lily")
        mgr.save(ChildMemory(profile: ChildProfile(name: "Lily")))
        XCTAssertFalse(mgr.deleteProfile(slug: "李明"), "junk that sanitises to empty must not delete anything")
        XCTAssertTrue(mgr.deleteProfile(slug: "lily"))
        XCTAssertNil(mgr.load())
    }

    func test_deleteProfile_tombstonesAgainstLateSave() {
        let mgr = MemoryManager(profilesDir: tempDir, slug: "lily")
        let memory = ChildMemory(profile: ChildProfile(name: "Lily"))
        mgr.save(memory)
        _ = mgr.deleteProfile(slug: "lily")

        // A late fire-and-forget background save must not resurrect the file.
        mgr.save(memory)
        XCTAssertNil(mgr.load())
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent("lily.json").path))
    }

    func test_listProfiles_sortedSlugs() {
        let a = MemoryManager(profilesDir: tempDir, slug: "mia")
        let b = MemoryManager(profilesDir: tempDir, slug: "lily")
        a.save(ChildMemory(profile: ChildProfile(name: "Mia")))
        b.save(ChildMemory(profile: ChildProfile(name: "Lily")))
        XCTAssertEqual(a.listProfiles(), ["lily", "mia"])
    }

    func test_prune_removesExpiredTopicsAndCapsCounts() {
        let mgr = MemoryManager(profilesDir: tempDir, slug: "lily", maxTopics: 1, topicTTLDays: 14)
        var memory = ChildMemory(profile: ChildProfile(name: "Lily"))
        memory.topics = [
            Topic(keyword: "old", mentionCount: 1, lastMentioned: ISO8601Date.string(2026, 1, 1)),
            Topic(keyword: "recent1", mentionCount: 1, lastMentioned: ISO8601Date.string(2026, 7, 20)),
            Topic(keyword: "recent2", mentionCount: 1, lastMentioned: ISO8601Date.string(2026, 7, 21)),
        ]
        mgr.prune(&memory, today: ISO8601Date.date(2026, 7, 22))
        // "old" (>14 days) expires; count cap keeps only the most recent 1.
        XCTAssertEqual(memory.topics.map(\.keyword), ["recent2"])
    }

    func test_prune_resolvedProblemsExpireFasterThanUnresolved() {
        let mgr = MemoryManager(profilesDir: tempDir, slug: "lily", problemTTLDays: 30)
        var memory = ChildMemory(profile: ChildProfile(name: "Lily"))
        memory.problems = [
            Problem(type: "a", example: "x", correction: "y", timesSeen: 1,
                    lastSeen: ISO8601Date.string(2026, 7, 10), resolved: true),   // 12 days ago, resolved: expires (>7)
            Problem(type: "b", example: "x", correction: "y", timesSeen: 1,
                    lastSeen: ISO8601Date.string(2026, 7, 10), resolved: false),  // 12 days ago, unresolved: survives (<30)
        ]
        mgr.prune(&memory, today: ISO8601Date.date(2026, 7, 22))
        XCTAssertEqual(memory.problems.map(\.type), ["b"])
    }
}

/// Test-only helper for building fixed ISO-date strings/Dates without relying
/// on the current wall clock (workflow scripts and CI must stay deterministic).
enum ISO8601Date {
    static func string(_ year: Int, _ month: Int, _ day: Int) -> String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    static func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var comps = DateComponents()
        comps.year = year; comps.month = month; comps.day = day
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: comps)!
    }
}
