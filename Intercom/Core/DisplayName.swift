import Foundation

/// MultipeerConnectivity requires display names to be non-empty and at most 63 UTF-8 bytes.
enum DisplayName {
    static let maxUTF8Bytes = 63
    static let fallback = "iPhone"

    static func sanitized(_ raw: String) -> String {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { name = fallback }
        while name.utf8.count > maxUTF8Bytes {
            name.removeLast()
        }
        if name.isEmpty { name = fallback }
        return name
    }
}
