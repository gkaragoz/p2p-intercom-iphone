import Foundation

extension LinkJournal {
    /// The journal of this install: `Application Support/LinkJournal/journal.jsonl`. Excluded from
    /// backups; it is diagnostic data, shared only when the user exports it.
    static let shared: LinkJournal = {
        let fileManager = FileManager.default
        let base = (try? fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                         appropriateFor: nil, create: true))
            ?? fileManager.temporaryDirectory
        var directory = base.appendingPathComponent("LinkJournal", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? directory.setResourceValues(values)
        return LinkJournal(directory: directory)
    }()
}
