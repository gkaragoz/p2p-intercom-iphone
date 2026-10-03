import CoreTransferable
import UniformTypeIdentifiers

/// What the share sheet exports: the link journal as a plain-text file, written when it is shared
/// (so it holds everything up to that moment).
struct LinkJournalExport: Transferable {
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .plainText) { _ in
            let url = try LinkJournal.shared.writeExport(in: FileManager.default.temporaryDirectory)
            return SentTransferredFile(url)
        }
    }
}
