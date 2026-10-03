import Foundation
import XCTest
@testable import IntercomCore

final class LinkJournalTests: XCTestCase {
    private var directory: URL!
    private let utc = TimeZone(identifier: "UTC")!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("link-journal-tests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// A clock that advances by one second per event, starting at 2026-10-02 11:03:05 UTC.
    private final class StepClock: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 1_790_000_000.0 + 3 * 3_600 + 5
        func next() -> Double {
            lock.lock()
            defer { lock.unlock() }
            value += 1
            return value
        }
    }

    private func makeJournal(capacity: Int = 100, clock: StepClock = StepClock()) -> LinkJournal {
        LinkJournal(directory: directory, capacity: capacity, clock: { clock.next() })
    }

    private func linesInFile(_ journal: LinkJournal) -> Int {
        journal.flush()
        guard let data = try? Data(contentsOf: journal.fileURL) else { return 0 }
        return data.split(separator: 0x0A, omittingEmptySubsequences: true).count
    }

    func testRecordsKeepTheirOrderAndFields() {
        let journal = makeJournal()
        journal.record("state", "stalled")
        journal.record("net", "dial")
        let entries = journal.snapshot()
        XCTAssertEqual(entries.map(\.category), ["state", "net"])
        XCTAssertEqual(entries.map(\.message), ["stalled", "dial"])
        XCTAssertLessThan(entries[0].time, entries[1].time)
    }

    func testOnlyTheNewestCapacityEntriesAreKept() {
        let journal = makeJournal(capacity: 10)
        for index in 0..<95 {
            journal.record("net", "event \(index)")
        }
        let entries = journal.snapshot()
        XCTAssertEqual(entries.count, 10)
        XCTAssertEqual(entries.first?.message, "event 85")
        XCTAssertEqual(entries.last?.message, "event 94")
    }

    func testJournalSurvivesARestartAndKeepsAppending() {
        let first = makeJournal()
        first.record("app", "scene phase: background")
        first.record("state", "stalled")
        first.flush()

        let second = makeJournal()
        XCTAssertEqual(second.snapshot().map(\.message), ["scene phase: background", "stalled"])
        second.record("state", "resumed")
        XCTAssertEqual(second.snapshot().map(\.message), ["scene phase: background", "stalled", "resumed"])

        let third = makeJournal()
        XCTAssertEqual(third.snapshot().count, 3, "what the second instance appended is on disk too")
    }

    func testCorruptAndCutOffLinesAreSkippedOnLoad() throws {
        let journal = makeJournal()
        journal.record("net", "good one")
        journal.flush()
        let handle = try FileHandle(forWritingTo: journal.fileURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("not json at all\n{\"category\":\"net\",\"mess".utf8))
        try handle.close()

        let reloaded = makeJournal()
        XCTAssertEqual(reloaded.snapshot().map(\.message), ["good one"])
    }

    func testAnEventAfterATornWriteIsNotLost() throws {
        let journal = makeJournal()
        journal.record("net", "good one")
        journal.flush()
        let handle = try FileHandle(forWritingTo: journal.fileURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"category\":\"net\",\"mess".utf8)) // power lost mid-line
        try handle.close()

        let restarted = makeJournal()
        XCTAssertEqual(restarted.snapshot().map(\.message), ["good one"])
        restarted.record("net", "after the torn write")
        restarted.flush()
        XCTAssertEqual(makeJournal().snapshot().map(\.message), ["good one", "after the torn write"],
                       "the new line must not be glued onto the torn one")
    }

    func testCountDoesNotCopyAndFollowsRecordsAndClear() {
        let journal = makeJournal(capacity: 10)
        XCTAssertEqual(journal.count, 0)
        for index in 0..<4 { journal.record("net", "event \(index)") }
        XCTAssertEqual(journal.count, 4)
        for index in 4..<40 { journal.record("net", "event \(index)") }
        XCTAssertEqual(journal.count, 10, "never more than the capacity")
        journal.clear()
        XCTAssertEqual(journal.count, 0)
    }

    func testLineBreaksInAMessageCannotForgeExportLines() {
        let journal = makeJournal()
        journal.record("net", "discovered \"Evil\n2026-10-02 14:03:05.000 [marker] user marker\"")
        let lines = journal.exportText(timeZone: utc).split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 2, "header plus one line: \(lines)")
        XCTAssertTrue(lines[1].contains("\\n"), "the break is written out: \(lines[1])")
    }

    func testWriteExportRemovesEarlierExports() throws {
        let journal = makeJournal()
        journal.record("net", "dial")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stale = directory.appendingPathComponent("intercom-link-journal-19990101-000000.txt")
        try "old".write(to: stale, atomically: true, encoding: .utf8)
        let unrelated = directory.appendingPathComponent("notes.txt")
        try "keep".write(to: unrelated, atomically: true, encoding: .utf8)

        let url = try journal.writeExport(in: directory, timeZone: utc)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path), "stale exports are copies nobody needs")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path), "other files are left alone")
    }

    func testTheFileIsCompactedInsteadOfGrowingForever() {
        let journal = makeJournal(capacity: 20)
        for index in 0..<500 {
            journal.record("net", "event \(index)")
        }
        XCTAssertLessThanOrEqual(linesInFile(journal), 20 + 10, "never more than capacity plus half of it")
        XCTAssertEqual(journal.snapshot().last?.message, "event 499")

        let reloaded = makeJournal(capacity: 20)
        XCTAssertEqual(reloaded.snapshot().count, 20)
        XCTAssertEqual(reloaded.snapshot().last?.message, "event 499")
        XCTAssertEqual(reloaded.snapshot().first?.message, "event 480")
    }

    func testExportTextHasAHeaderAndOneLinePerEvent() {
        let journal = makeJournal()
        journal.record("state", "link 7: stalled")
        journal.record("marker", "user marker")
        let text = journal.exportText(timeZone: utc)
        let lines = text.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[0].hasPrefix("# Intercom link journal: 2 events, "), lines[0])
        XCTAssertTrue(lines[0].hasSuffix("(UTC)") || lines[0].hasSuffix("(GMT)"), lines[0])
        XCTAssertTrue(lines[1].hasSuffix("[state] link 7: stalled"), lines[1])
        XCTAssertTrue(lines[2].hasSuffix("[marker] user marker"), lines[2])
        // The stamp is a readable local time with milliseconds.
        XCTAssertNotNil(lines[1].range(of: #"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3} \["#, options: .regularExpression), lines[1])
        XCTAssertTrue(text.hasSuffix("\n"))
    }

    func testEmptyJournalExportsAHeaderOnly() {
        let text = makeJournal().exportText(timeZone: utc)
        XCTAssertEqual(text, "# Intercom link journal: no events\n")
    }

    func testWriteExportCreatesANamedTextFile() throws {
        let journal = makeJournal()
        journal.record("net", "dial")
        let url = try journal.writeExport(in: directory, timeZone: utc)
        XCTAssertTrue(url.lastPathComponent.hasPrefix("intercom-link-journal-"), url.lastPathComponent)
        XCTAssertEqual(url.pathExtension, "txt")
        let written = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(written, journal.exportText(timeZone: utc))
    }

    func testClearForgetsEverythingEvenAfterARestart() {
        let journal = makeJournal()
        journal.record("net", "dial")
        journal.flush()
        journal.clear()
        XCTAssertTrue(journal.snapshot().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal.fileURL.path))
        journal.record("net", "after clear")
        journal.flush()
        XCTAssertEqual(makeJournal().snapshot().map(\.message), ["after clear"])
    }

    func testConcurrentRecordsAreAllKept() {
        let journal = makeJournal(capacity: 5_000)
        DispatchQueue.concurrentPerform(iterations: 8) { worker in
            for index in 0..<200 {
                journal.record("net", "worker \(worker) event \(index)")
            }
        }
        let entries = journal.snapshot()
        XCTAssertEqual(entries.count, 1_600)
        XCTAssertEqual(Set(entries.map(\.message)).count, 1_600, "no event lost or duplicated")
        for worker in 0..<8 {
            let mine = entries.filter { $0.message.hasPrefix("worker \(worker) ") }.map(\.message)
            XCTAssertEqual(mine, (0..<200).map { "worker \(worker) event \($0)" }, "per-thread order is kept")
        }
    }
}
