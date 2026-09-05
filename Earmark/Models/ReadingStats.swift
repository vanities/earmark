import Foundation

/// Aggregated reading history for the Stats tab. Built purely from finished items so it's testable.
struct ReadingStats: Equatable, Sendable {
    struct Year: Identifiable, Equatable, Sendable {
        var year: Int
        var count: Int
        var hours: Double
        var id: Int { year }
    }
    struct AuthorCount: Identifiable, Equatable, Sendable {
        var author: String
        var count: Int
        var id: String { author }
    }

    var totalBooks: Int = 0
    var totalHours: Double = 0
    var thisYear: Int = 0
    var bestYear: Year?
    var years: [Year] = []            // descending by year
    var ratedCount: Int = 0
    var averageRating: Double?
    var topAuthors: [AuthorCount] = []

    var isEmpty: Bool { totalBooks == 0 }
}

enum ReadingStatsBuilder {
    struct Item: Sendable {
        var finishedAt: Date
        var hours: Double
        var rating: Int?
        var author: String?
    }

    static func build(_ items: [Item], now: Date = .now, calendar: Calendar = Calendar(identifier: .gregorian)) -> ReadingStats {
        guard !items.isEmpty else { return ReadingStats() }
        var stats = ReadingStats()
        stats.totalBooks = items.count
        stats.totalHours = items.reduce(0) { $0 + max(0, $1.hours) }

        let thisYearValue = calendar.component(.year, from: now)
        var perYear: [Int: (count: Int, hours: Double)] = [:]
        var ratingSum = 0
        var authorCounts: [String: Int] = [:]
        for item in items {
            let year = calendar.component(.year, from: item.finishedAt)
            var bucket = perYear[year] ?? (0, 0)
            bucket.count += 1
            bucket.hours += max(0, item.hours)
            perYear[year] = bucket
            if let rating = item.rating, (1...5).contains(rating) {
                stats.ratedCount += 1
                ratingSum += rating
            }
            if let author = item.author, !author.isEmpty {
                authorCounts[author, default: 0] += 1
            }
        }
        stats.thisYear = perYear[thisYearValue]?.count ?? 0
        stats.years = perYear.map { ReadingStats.Year(year: $0.key, count: $0.value.count, hours: $0.value.hours) }
            .sorted { $0.year > $1.year }
        stats.bestYear = stats.years.max { $0.count < $1.count }
        stats.averageRating = stats.ratedCount > 0 ? Double(ratingSum) / Double(stats.ratedCount) : nil
        stats.topAuthors = authorCounts.map { ReadingStats.AuthorCount(author: $0.key, count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.author < $1.author }
        return stats
    }
}
