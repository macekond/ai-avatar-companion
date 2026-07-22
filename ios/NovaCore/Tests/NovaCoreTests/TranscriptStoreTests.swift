import XCTest
@testable import NovaCore

final class TranscriptStoreTests: XCTestCase {
    var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    func test_load_noFile_returnsEmpty() {
        let store = TranscriptStore(transcriptsDir: tempDir, slug: "lily")
        XCTAssertEqual(store.load(), [])
    }

    func test_appendTurnThenLoad_roundTrips() {
        let store = TranscriptStore(transcriptsDir: tempDir, slug: "lily")
        store.appendTurn(id: 1, you: "hi", nova: "hello!")
        let turns = store.load()
        XCTAssertEqual(turns.count, 1)
        XCTAssertEqual(turns[0].id, 1)
        XCTAssertEqual(turns[0].you, "hi")
        XCTAssertEqual(turns[0].nova, "hello!")
        XCTAssertEqual(turns[0].corrections, [])
    }

    func test_correctionAttachesToItsTurn() {
        let store = TranscriptStore(transcriptsDir: tempDir, slug: "lily")
        store.appendTurn(id: 1, you: "I goed to school", nova: "You went to school!")
        store.appendCorrection(id: 1, kind: "past_tense", wrong: "goed", right: "went")
        let turns = store.load()
        XCTAssertEqual(turns[0].corrections, [
            TranscriptCorrection(kind: "past_tense", wrong: "goed", right: "went")
        ])
    }

    func test_correctionForUnknownTurn_isIgnored() {
        let store = TranscriptStore(transcriptsDir: tempDir, slug: "lily")
        store.appendCorrection(id: 99, kind: "past_tense", wrong: "goed", right: "went")
        XCTAssertEqual(store.load(), [])
    }

    func test_turnsPreserveInsertionOrder() {
        let store = TranscriptStore(transcriptsDir: tempDir, slug: "lily")
        store.appendTurn(id: 2, you: "b", nova: "B")
        store.appendTurn(id: 1, you: "a", nova: "A")
        let turns = store.load()
        XCTAssertEqual(turns.map(\.id), [2, 1])
    }

    func test_malformedLine_isSkippedNotFatal() throws {
        let store = TranscriptStore(transcriptsDir: tempDir, slug: "lily")
        store.appendTurn(id: 1, you: "hi", nova: "hello!")
        try "not json at all\n".appendToFile(at: tempDir.appendingPathComponent("lily.jsonl"))
        let turns = store.load()
        XCTAssertEqual(turns.count, 1)
    }

    func test_lastId_withNoHistory_isZero() {
        let store = TranscriptStore(transcriptsDir: tempDir, slug: "lily")
        XCTAssertEqual(store.lastId(), 0)
    }

    func test_lastId_returnsHighestTurnId() {
        let store = TranscriptStore(transcriptsDir: tempDir, slug: "lily")
        store.appendTurn(id: 1, you: "a", nova: "A")
        store.appendTurn(id: 5, you: "b", nova: "B")
        store.appendTurn(id: 3, you: "c", nova: "C")
        XCTAssertEqual(store.lastId(), 5)
    }

    func test_delete_removesFileAndTombstonesAgainstLateAppend() {
        let store = TranscriptStore(transcriptsDir: tempDir, slug: "lily")
        store.appendTurn(id: 1, you: "hi", nova: "hello!")
        store.delete()
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent("lily.jsonl").path))

        // A late fire-and-forget append (e.g. a correction landing after
        // profile deletion) must not resurrect the file.
        store.appendCorrection(id: 1, kind: "past_tense", wrong: "goed", right: "went")
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent("lily.jsonl").path))
    }
}

private extension String {
    func appendToFile(at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let handle = FileHandle(forWritingAtPath: url.path) {
            handle.seekToEndOfFile()
            handle.write(Data(self.utf8))
            handle.closeFile()
        } else {
            try self.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
