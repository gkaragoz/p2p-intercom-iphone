import Foundation

/// One line of the link journal.
struct LinkJournalEntry: Codable, Equatable, Sendable {
    /// Wall clock, seconds since 1970.
    var time: Double
    /// What kind of event: `net` (transport), `state` (link state), `path`, `health`, `app`, `audio`,
    /// `device`, `timing` or `marker`.
    var category: String
    var message: String
}

/// A bounded, file-backed event log for field tests without a Mac.
///
/// The system log keeps `info` lines in memory only and needs a cable and `sudo log collect` to read
/// back. This journal keeps the story of every link on the phone itself: stalls and their reasons,
/// reconnects, the path in use, app and audio state, power and thermal state, timer gaps. It survives
/// restarts and exports as plain text through the share sheet, so the evidence of a bike ride is
/// there when the phone is back home.
///
/// Everything lives on one serial queue: `record` only enqueues (cheap, callable from any queue,
/// never from a real-time audio thread), reads wait for what was recorded before them. File errors
/// are swallowed: a journal must never take the intercom down.
final class LinkJournal: @unchecked Sendable {
    /// The newest `capacity` entries are kept, in memory and in the file.
    let capacity: Int
    let fileURL: URL

    private let fileManager: FileManager
    private let clock: @Sendable () -> Double
    private let queue = DispatchQueue(label: "intercom.link-journal", qos: .utility)
    // Everything below is confined to `queue`.
    private var entries: [LinkJournalEntry] = []
    private var linesInFile = 0
    private var handle: FileHandle?
    /// The file ends in a torn line (a crash mid-write): the next append starts on a new line.
    private var needsNewlineBeforeAppend = false
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    /// Opens (or creates) `directory/journal.jsonl` and loads what is in it.
    init(directory: URL,
         capacity: Int = 8_000,
         fileManager: FileManager = .default,
         clock: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 }) {
        self.capacity = max(10, capacity)
        self.fileManager = fileManager
        self.clock = clock
        fileURL = directory.appendingPathComponent("journal.jsonl")
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        // Loaded on the queue, not here: the first use is on the main thread at launch, and a full
        // journal is several MB of JSON. Every read and write waits behind the load.
        queue.async { [self] in load() }
    }

    deinit {
        try? handle?.close()
    }

    // MARK: - Recording

    func record(_ category: String, _ message: String) {
        let entry = LinkJournalEntry(time: clock(), category: category, message: message)
        queue.async { [self] in append(entry) }
    }

    /// The newest `capacity` entries, oldest first. Waits for everything recorded before the call.
    func snapshot() -> [LinkJournalEntry] {
        queue.sync { Array(entries.suffix(capacity)) }
    }

    /// How many entries are kept, without copying them.
    var count: Int {
        queue.sync { min(entries.count, capacity) }
    }

    /// Waits until everything recorded so far is on disk.
    func flush() {
        queue.sync {}
    }

    /// Forgets everything, in memory and on disk.
    func clear() {
        queue.sync {
            entries.removeAll()
            linesInFile = 0
            needsNewlineBeforeAppend = false
            try? handle?.close()
            handle = nil
            try? fileManager.removeItem(at: fileURL)
        }
    }

    // MARK: - Export

    /// The journal as plain text, one event per line, local time:
    /// `2026-10-02 14:03:05.123 [state] link 1f2e…: stalled`.
    func exportText(timeZone: TimeZone = .current) -> String {
        let entries = snapshot()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        var lines: [String] = []
        lines.reserveCapacity(entries.count + 1)
        let zone = timeZone.abbreviation() ?? timeZone.identifier
        if let first = entries.first, let last = entries.last {
            let from = formatter.string(from: Date(timeIntervalSince1970: first.time))
            let to = formatter.string(from: Date(timeIntervalSince1970: last.time))
            lines.append("# Intercom link journal: \(entries.count) events, \(from) to \(to) (\(zone))")
        } else {
            lines.append("# Intercom link journal: no events")
        }
        for entry in entries {
            let stamp = formatter.string(from: Date(timeIntervalSince1970: entry.time))
            lines.append("\(stamp) [\(Self.singleLine(entry.category))] \(Self.singleLine(entry.message))")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// A message with its line breaks written out, so nothing recorded (a peer's display name comes
    /// off the network) can forge a line of the export.
    private static func singleLine(_ text: String) -> String {
        text.replacingOccurrences(of: "\r", with: "\\r").replacingOccurrences(of: "\n", with: "\\n")
    }

    /// Writes `exportText` to a new `intercom-link-journal-<date>.txt` in `directory` and returns it.
    /// Earlier exports in `directory` are removed first: they are copies that nobody needs again.
    func writeExport(in directory: URL, timeZone: TimeZone = .current) throws -> URL {
        for name in (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
        where name.hasPrefix("intercom-link-journal-") && name.hasSuffix(".txt") {
            try? fileManager.removeItem(at: directory.appendingPathComponent(name))
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let name = "intercom-link-journal-\(formatter.string(from: Date(timeIntervalSince1970: clock()))).txt"
        let url = directory.appendingPathComponent(name)
        try exportText(timeZone: timeZone).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - Persistence (queue)

    private func load() {
        guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else { return }
        let decoder = JSONDecoder()
        var lines = 0
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            lines += 1
            // A line cut short by a crash simply fails to decode.
            if let entry = try? decoder.decode(LinkJournalEntry.self, from: Data(line)) {
                entries.append(entry)
            }
        }
        linesInFile = lines
        needsNewlineBeforeAppend = data.last != 0x0A
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
        if linesInFile > capacity + capacity / 2 {
            compact()
        }
    }

    private func append(_ entry: LinkJournalEntry) {
        entries.append(entry)
        // Trimmed in chunks, so a full journal does not shift its whole array on every event.
        if entries.count > capacity + capacity / 8 {
            entries.removeFirst(entries.count - capacity)
        }
        guard var line = try? encoder.encode(entry) else { return }
        line.append(0x0A)
        if needsNewlineBeforeAppend {
            // Without this the new line would be glued onto the torn one and lost with it.
            line.insert(0x0A, at: 0)
            needsNewlineBeforeAppend = false
        }
        if handle == nil {
            if !fileManager.fileExists(atPath: fileURL.path) {
                fileManager.createFile(atPath: fileURL.path, contents: nil)
            }
            handle = try? FileHandle(forWritingTo: fileURL)
            _ = try? handle?.seekToEnd()
        }
        try? handle?.write(contentsOf: line)
        linesInFile += 1
        if linesInFile > capacity + capacity / 2 {
            compact()
        }
    }

    /// Rewrites the file with only the newest `capacity` entries.
    private func compact() {
        let kept = entries.suffix(capacity)
        var data = Data()
        for entry in kept {
            if let line = try? encoder.encode(entry) {
                data.append(line)
                data.append(0x0A)
            }
        }
        try? handle?.close()
        handle = nil
        try? data.write(to: fileURL, options: .atomic)
        linesInFile = kept.count
        needsNewlineBeforeAppend = false
    }
}
