import Foundation

extension String {
    /// Finder-style ordering: "Chapter 2" sorts before "Chapter 10".
    func naturallyPrecedes(_ other: String) -> Bool {
        localizedStandardCompare(other) == .orderedAscending
    }

    /// Lowercased, punctuation stripped, whitespace collapsed — for fuzzy equality.
    var normalizedForMatching: String {
        lowercased()
            .replacingOccurrences(of: "_", with: " ")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Underscores → spaces, whitespace collapsed, trimmed. For folder/file names shown to people.
    var cleanedDisplayName: String {
        replacingOccurrences(of: "_", with: " ")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
