import Foundation

/// User corrections to a book's detected metadata, keyed by `Book.id` in `LibraryState`.
/// Grouping is heuristic and sometimes wrong; this is the escape hatch. A `nil` field means
/// "keep what was detected"; an empty string clears the detected value (e.g. remove a series).
struct BookMetadataOverride: Codable, Hashable, Sendable {
    var title: String?
    var author: String?
    var series: String?
    var seriesIndex: Double?
    var narrator: String?
    var year: Int?

    var isEmpty: Bool {
        title == nil && author == nil && series == nil && seriesIndex == nil && narrator == nil && year == nil
    }

    /// Layers a newer set of corrections on top of these; the newer non-nil field wins.
    func merged(with newer: BookMetadataOverride) -> BookMetadataOverride {
        BookMetadataOverride(
            title: newer.title ?? title,
            author: newer.author ?? author,
            series: newer.series ?? series,
            seriesIndex: newer.seriesIndex ?? seriesIndex,
            narrator: newer.narrator ?? narrator,
            year: newer.year ?? year
        )
    }

    /// Overlays the set fields onto a scanned book. A non-nil, empty string clears that field;
    /// a non-empty string replaces it. Title never clears (a book needs a name).
    func applied(to book: Book) -> Book {
        var b = book
        if let title, !title.isEmpty { b.title = title }
        if let author { b.author = author.isEmpty ? nil : author }
        if let series {
            b.series = series.isEmpty ? nil : series
            if series.isEmpty { b.seriesIndex = nil }
        }
        if let seriesIndex, b.series != nil { b.seriesIndex = seriesIndex }
        if let narrator { b.narrator = narrator.isEmpty ? nil : narrator }
        if let year { b.year = year }
        return b
    }
}
